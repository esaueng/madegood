import Foundation
import Synchronization
import WaterKit

/// The live paddle-stroke detector for kayak, canoe and SUP. Motion arrives on the motion
/// queue at the sensor rate, so the detector lives behind a lock there; the recorder reads
/// a snapshot about once a second on the main actor.
///
/// Everything runs on the session's monotonic clock (the motion lines' clock), never the
/// wall clock, so a system clock change cannot make the rate look stale.
final class LiveStrokes: Sendable {
    private let detector: Mutex<StrokeDetector>
    /// The monotonic clock at the session start: a motion time minus this is session time.
    private let startMono: Double
    private let now: @Sendable () -> Double

    /// `now` returns the monotonic clock's current time (absolute, Unix s).
    init(sport: Sport, startMono: Double, now: @escaping @Sendable () -> Double) {
        detector = Mutex(StrokeDetector(sport: sport))
        self.startMono = startMono
        self.now = now
    }

    convenience init(sport: Sport, clock: RawFormat.MonotonicClock) {
        self.init(sport: sport, startMono: clock.startUnix) {
            clock.absolute(uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    func ingest(_ line: RawFormat.MotionLine) {
        let sample = MotionSample(
            t: line.ts - startMono,
            userAcceleration: Vector3(x: line.ax, y: line.ay, z: line.az),
            gravity: Vector3(x: line.gx, y: line.gy, z: line.gz),
            rotationRate: Vector3(x: line.rx, y: line.ry, z: line.rz),
            attitude: Quaternion(x: line.qx, y: line.qy, z: line.qz, w: line.qw))
        detector.withLock { $0.ingest(sample) }
    }

    /// The user's manual pause or resume, now: strokes stop counting while paused, as all
    /// other accounting does. Auto-pause is not passed here; strokes count through it.
    func userEvent(_ type: EventType) {
        let event = SessionEvent(t: now() - startMono, type: type)
        detector.withLock { $0.ingest(event) }
    }

    /// The metrics now, so the rate blanks when paddling stops.
    func snapshot() -> StrokeDetector.Metrics {
        let current = now() - startMono
        return detector.withLock { detector in
            detector.advance(to: current)
            return detector.snapshot
        }
    }
}
