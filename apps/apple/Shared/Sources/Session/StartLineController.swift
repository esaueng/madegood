import CoreLocation
import Foundation
import Observation
import WaterKit

/// The race start line (docs/PLAN.md §5, "Race tools"; docs/metrics.md, "Start line"):
/// pings of the pin and boat ends during a sailing countdown, the boat's place relative to
/// the line, and the OCS check at the gun. The geometry lives in WaterKit's `StartLine`.
///
/// During the countdown nothing is recording, so this object runs its own location updates;
/// once recording starts, the recorder feeds it fixes instead. The line is kept (across
/// relaunches) for `keepsLineFor`, so later races off the same line reuse it.
@MainActor
@Observable
final class StartLineController {
    static let shared = StartLineController()

    /// A position is current for this long, s.
    static let freshFor: TimeInterval = 10
    /// A line is reused for this long after its last ping, s.
    static let keepsLineFor: TimeInterval = 6 * 3600
    /// The OCS warning clears itself after this long, s, if the boat never returns.
    static let ocsShownFor: TimeInterval = 300

    struct Position: Equatable {
        var fix: GPSFix
        /// `ProcessInfo.systemUptime` when it arrived: freshness ignores wall-clock changes.
        var receivedUptime: TimeInterval
    }

    /// What the countdown screens show.
    struct Reading: Equatable {
        var line: StartLine?
        /// Nil without a line or a current position.
        var position: StartLinePosition?
        var timeToBurn: Double?
        var bias: LineBias?
    }

    struct OCSWarning: Equatable {
        /// How far over the line at the gun, m (positive).
        var distance: Double
        var shownAtUptime: TimeInterval
    }

    private(set) var pin: StartLinePing?
    private(set) var boat: StartLinePing?
    /// The end being averaged, if any.
    private(set) var pending: StartLineEnd?
    /// The last ping found no usable fix.
    private(set) var lastPingFailed: StartLineEnd?
    private(set) var position: Position?
    /// Set at the gun when the boat was over; cleared when it is back on the pre-start side.
    private(set) var ocs: OCSWarning?
    private(set) var wind: WindEstimate?

    private var recentFixes: [GPSFix] = []
    private var averager: StartLinePingAverager?
    private var prestartWind = PrestartWind()
    private var updates: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    /// Countdown time left, s, for the demo feed.
    private var remaining: (() -> Double)?

    private static let storageKey = "startLine.pings"

    private struct Stored: Codable {
        var pin: StartLinePing?
        var boat: StartLinePing?
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            let now = Date().timeIntervalSince1970
            let isCurrent = { (ping: StartLinePing?) in ping.map { now - $0.time <= Self.keepsLineFor } ?? false }
            if isCurrent(stored.pin) { pin = stored.pin }
            if isCurrent(stored.boat) { boat = stored.boat }
        }
        #if DEBUG
            // UI tests start without a line from an earlier launch.
            if DemoFeed.isEnabled { pin = nil; boat = nil }
        #endif
    }

    var line: StartLine? {
        guard let pin, let boat else { return nil }
        return StartLine(pin: pin, boat: boat)
    }

    /// Both ends are pinged but make no line (the same spot twice, or kilometres apart).
    var hasUnusableEnds: Bool { pin != nil && boat != nil && line == nil }

    /// The pings to record with a session, in time order.
    var pings: [StartLinePing] { [pin, boat].compactMap { $0 }.sorted { $0.time < $1.time } }

    func ping(_ end: StartLineEnd) -> StartLinePing? { end == .pin ? pin : boat }

    // MARK: Countdown

    /// A sailing countdown began: start location updates (or the demo feed).
    func countdownBegan(remaining: @escaping () -> Double) {
        self.remaining = remaining
        ocs = nil
        prestartWind = PrestartWind()
        wind = nil
        recentFixes = []
        position = nil
        startUpdates()
    }

    /// The countdown ended or was cancelled. At the gun (`atGun`), checks for OCS.
    func countdownEnded(atGun: Bool) {
        if atGun, let line, let position, isFresh(position) {
            let place = line.position(latitude: position.fix.latitude, longitude: position.fix.longitude)
            if place.isOver {
                ocs = OCSWarning(distance: -place.distance, shownAtUptime: ProcessInfo.processInfo.systemUptime)
                Haptics.play(.overTheLine)
            }
        }
        stopUpdates()
        remaining = nil
    }

    func dismissOCS() { ocs = nil }

    /// Fed with every accepted fix while recording, to clear the OCS warning.
    func recorded(_ fix: GPSFix) {
        update(fix)
    }

    // MARK: Pings

    /// Pings `end` at the current position, averaged over the fixes around the press.
    func startPing(_ end: StartLineEnd) {
        guard pending == nil else { return }
        let pressedAt = Date().timeIntervalSince1970
        var averager = StartLinePingAverager(end: end, pressedAt: pressedAt)
        #if DEBUG
            if DemoFeed.isEnabled {
                // The demo pings fixed ends, through the same averaging.
                let point = DemoFeed.startLineEnd(end)
                for dt in [-1.0, 0, 1] {
                    averager.add(
                        GPSFix(t: pressedAt + dt, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 4))
                }
            }
        #endif
        if !DemoFeed.isEnabled { for fix in recentFixes { averager.add(fix) } }
        self.averager = averager
        pending = end
        lastPingFailed = nil
        Haptics.play(.mark)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(StartLinePingAverager.lookAhead + 0.5))
            self?.finishPing()
        }
    }

    func clearLine() {
        pin = nil
        boat = nil
        save()
    }

    private func finishPing() {
        guard let averager, let end = pending else { return }
        self.averager = nil
        pending = nil
        guard let ping = averager.ping else {
            lastPingFailed = end
            Haptics.play(.failure)
            return
        }
        if end == .pin { pin = ping } else { boat = ping }
        save()
        Haptics.play(.sync)
    }

    private func save() {
        let stored = Stored(pin: pin, boat: boat)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Reading

    func reading(remaining: Double) -> Reading {
        guard let line else { return Reading() }
        var reading = Reading(line: line)
        if let position, isFresh(position) {
            let place = line.position(
                latitude: position.fix.latitude, longitude: position.fix.longitude, speed: position.fix.speed,
                course: position.fix.course)
            reading.position = place
            reading.timeToBurn = place.timeToBurn(remaining: remaining)
        }
        if let wind { reading.bias = line.bias(windFrom: wind.fromDegrees, axisOnly: !wind.resolvedByPrior) }
        return reading
    }

    private func isFresh(_ position: Position) -> Bool {
        ProcessInfo.processInfo.systemUptime - position.receivedUptime <= Self.freshFor
    }

    // MARK: Positions

    private func update(_ fix: GPSFix) {
        position = Position(fix: fix, receivedUptime: ProcessInfo.processInfo.systemUptime)
        recentFixes.append(fix)
        recentFixes.removeAll { fix.t - $0.t > StartLinePingAverager.lookBack + 1 }
        if !DemoFeed.isEnabled { averager?.add(fix) }
        if updates != nil {
            prestartWind.add(fix)
            #if DEBUG
                if DemoFeed.isEnabled {
                    wind = WindEstimate(
                        fromDegrees: DemoFeed.prestartWind, axisConfidence: 1, axisUncertainty: 5, legCourses: [],
                        legAngle: 90, side: .unresolved)
                    return
                }
            #endif
            wind = prestartWind.estimate
        }
        if let ocs {
            let backBehind =
                line.map { $0.position(latitude: fix.latitude, longitude: fix.longitude).distance > 0 } ?? true
            let expired = ProcessInfo.processInfo.systemUptime - ocs.shownAtUptime > Self.ocsShownFor
            if backBehind || expired { self.ocs = nil }
        }
    }

    private func startUpdates() {
        stopUpdates()
        if DemoFeed.isEnabled {
            updates = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let remaining = self.remaining?() else { return }
                    self.update(DemoFeed.prestartFix(at: Date().timeIntervalSince1970, remaining: remaining))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return
        }
        serviceSession = CLServiceSession(authorization: .whenInUse)
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if Task.isCancelled { break }
                    guard let location = update.location, location.horizontalAccuracy >= 0,
                        location.horizontalAccuracy <= 25
                    else { continue }
                    self?.update(
                        GPSFix(
                            t: location.timestamp.timeIntervalSince1970, latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude, horizontalAccuracy: location.horizontalAccuracy,
                            speed: location.speed >= 0 ? location.speed : nil,
                            course: location.course >= 0 ? location.course : nil))
                }
            } catch {
                print("StartLine: location updates ended: \(error)")
            }
        }
    }

    private func stopUpdates() {
        updates?.cancel()
        updates = nil
        serviceSession?.invalidate()
        serviceSession = nil
    }
}

extension LiveDisplay {
    /// Distance to the start line in whole metres (feet with statute miles), unsigned.
    func lineDistance(_ metres: Double) -> String {
        let value = abs(metres)
        return distance == .statuteMiles ? "\(Int((value / 0.3048).rounded())) ft" : "\(Int(value.rounded())) m"
    }

    /// A signed time such as time to burn: "0:12", "−0:05".
    static func signedTime(_ seconds: Double) -> String {
        let text = Formatting.elapsed(abs(seconds).rounded())
        return seconds < -0.5 ? "−\(text)" : text
    }

    /// "Boat +6°", "Pin +4°", "Square".
    static func bias(_ bias: LineBias) -> String {
        guard let end = bias.favoured else { return "Square" }
        return "\(end == .pin ? "Pin" : "Boat") +\(Int(abs(bias.degrees).rounded()))°"
    }
}
