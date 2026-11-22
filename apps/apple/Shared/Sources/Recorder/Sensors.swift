import CoreLocation
import CoreMotion
import Foundation
import Synchronization
import WaterKit

// Sensor sources for the raw recorder. Each writes sensor-native timestamps straight to
// its RawStreamWriter (docs/formats.md) and never touches the main actor from a callback.

// MARK: Location

/// 1 Hz location via `CLLocationUpdate.liveUpdates(.fitness)`.
final class LocationSource: Sendable {
    private let writer: RawStreamWriter
    private let onFix: @Sendable (RawFormat.GPSLine) -> Void
    private let onIssue: @Sendable (ManOverboard.LocationIssue?) -> Void
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// `onFix` receives every line written, on a background task, for live analysis.
    /// `onIssue` receives Core Location's diagnostics (denied, restricted, approximate,
    /// unavailable, or nil when fine) whenever they change.
    init(
        writer: RawStreamWriter, onFix: @escaping @Sendable (RawFormat.GPSLine) -> Void = { _ in },
        onIssue: @escaping @Sendable (ManOverboard.LocationIssue?) -> Void = { _ in }
    ) {
        self.writer = writer
        self.onFix = onFix
        self.onIssue = onIssue
    }

    func start() {
        let writer = writer
        let onFix = onFix
        let onIssue = onIssue
        let newTask = Task.detached(priority: .userInitiated) {
            var lastIssue: ManOverboard.LocationIssue?
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    if Task.isCancelled { break }
                    let issue = ManOverboard.issue(from: update)
                    if issue != lastIssue {
                        lastIssue = issue
                        onIssue(issue)
                    }
                    guard let location = update.location, let line = Self.line(for: location) else { continue }
                    writer.append(line)
                    onFix(line)
                }
            } catch {
                print("LocationSource: updates ended: \(error)")
                onIssue(.unavailable)
            }
        }
        task.withLock { $0 = newTask }
    }

    func stop() {
        task.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    /// CoreLocation reports invalid values as negative numbers; they are left out.
    static func line(for location: CLLocation) -> RawFormat.GPSLine? {
        guard location.horizontalAccuracy >= 0 else { return nil }
        func valid(_ value: Double) -> Double? { value >= 0 && value.isFinite ? value : nil }
        let hasAltitude = location.verticalAccuracy > 0
        return RawFormat.GPSLine(
            ts: location.timestamp.timeIntervalSince1970,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            alt: hasAltitude ? location.altitude : nil,
            hacc: location.horizontalAccuracy,
            vacc: hasAltitude ? location.verticalAccuracy : nil,
            spd: valid(location.speed),
            spdacc: valid(location.speedAccuracy),
            crs: valid(location.course),
            crsacc: valid(location.courseAccuracy))
    }
}

// MARK: Motion

/// Device motion at the requested rate (100 Hz). Accelerations are converted from g to m/s².
@MainActor
final class MotionSource {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.madegood.recorder.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let writer: RawStreamWriter
    private let clock: RawFormat.MonotonicClock
    private let onSample: @Sendable (RawFormat.MotionLine) -> Void

    /// `onSample` receives every line written, on the motion queue, for live analysis. Lines
    /// carry the sample time on the session's monotonic `clock`, never the uptime reading.
    init(
        writer: RawStreamWriter, clock: RawFormat.MonotonicClock,
        onSample: @escaping @Sendable (RawFormat.MotionLine) -> Void = { _ in }
    ) {
        self.writer = writer
        self.clock = clock
        self.onSample = onSample
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(rate: Double) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / rate
        manager.startDeviceMotionUpdates(to: queue, withHandler: Self.handler(writer: writer, clock: clock, onSample: onSample))
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Returns once every update queued before it has been handled, so a sample already in
    /// flight at `stop()` has reached `onSample`.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.addBarrierBlock { continuation.resume() }
        }
    }

    /// Built outside the main actor so the closure is not main-actor isolated: CoreMotion
    /// calls it on `queue`.
    nonisolated private static func handler(
        writer: RawStreamWriter, clock: RawFormat.MonotonicClock,
        onSample: @escaping @Sendable (RawFormat.MotionLine) -> Void
    ) -> CMDeviceMotionHandler {
        { motion, _ in
            guard let motion else { return }
            let g = RawFormat.standardGravity
            let a = motion.userAcceleration
            let gravity = motion.gravity
            let r = motion.rotationRate
            let q = motion.attitude.quaternion
            let line = RawFormat.MotionLine(
                ts: clock.absolute(uptime: motion.timestamp),
                userAcceleration: Vector3(x: a.x * g, y: a.y * g, z: a.z * g),
                gravity: Vector3(x: gravity.x * g, y: gravity.y * g, z: gravity.z * g),
                rotationRate: Vector3(x: r.x, y: r.y, z: r.z),
                attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w))
            writer.append(line)
            onSample(line)
        }
    }
}

// MARK: Heading

/// Compass heading where the hardware has a magnetometer, written at about 1 Hz
/// (PLAN §4.2). With no heading filter CoreLocation delivers about 50 Hz; nothing reads
/// heading live, and the recording keeps one line per second (`RawFormat.HeadingThrottle`).
@MainActor
final class HeadingSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let writer: RawStreamWriter
    private let throttle = Mutex(RawFormat.HeadingThrottle())

    init(writer: RawStreamWriter) {
        self.writer = writer
        super.init()
        manager.delegate = self
        manager.headingFilter = kCLHeadingFilterNone
    }

    var isAvailable: Bool { CLLocationManager.headingAvailable() }

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return }
        let ts = heading.timestamp.timeIntervalSince1970
        guard throttle.withLock({ $0.admit(ts) }) else { return }
        writer.append(
            RawFormat.HeadingLine(
                ts: ts,
                mag: heading.magneticHeading,
                trueHeading: heading.trueHeading >= 0 ? heading.trueHeading : nil,
                acc: heading.headingAccuracy))
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }
}
