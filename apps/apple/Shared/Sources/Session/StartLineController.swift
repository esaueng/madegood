import CoreLocation
import Foundation
import Observation
import WaterKit

/// The race start line (docs/PLAN.md §5, "Race tools"; docs/metrics.md, "Start line"):
/// pings of the pin and boat ends during a sailing countdown, the boat's place relative to
/// the line, and the start check at the gun. The geometry and state live in WaterKit
/// (`StartLine`, `StartLineState`); this object adds location, persistence, haptics and
/// timers.
///
/// During the countdown nothing is recording, so this object runs its own location updates;
/// once recording starts, the recorder feeds it fixes instead. The line is kept (across
/// relaunches) for `StartLineState.keepsLineFor` after its last ping, and reused only once
/// a position shows the boat is near it.
@MainActor
@Observable
final class StartLineController {
    static let shared = StartLineController()

    /// A position is current for this long after its own timestamp, s.
    static let freshFor: TimeInterval = 10

    /// What the countdown screens show.
    struct Reading: Equatable {
        var line: StartLine?
        /// Nil without a line or a current position.
        var position: StartLinePosition?
        var timeToBurn: Double?
        var bias: LineBias?
    }

    private(set) var state = StartLineState()
    /// The newest fix, from this object's updates or the recorder.
    private(set) var latest: GPSFix?
    private(set) var wind: WindEstimate?

    private var recentFixes: [GPSFix] = []
    private var prestartWind = PrestartWind()
    private var updates: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var warningTimer: Task<Void, Never>?
    /// Tells a ping's timer from a later ping's.
    private var pingID = UUID()
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
            state = StartLineState(pin: stored.pin, boat: stored.boat)
            if state.expire(now: Self.wallClock) { save() }
        }
        #if DEBUG
            // UI tests start without a line from an earlier launch.
            if DemoFeed.isEnabled { state = StartLineState() }
        #endif
    }

    /// Unix time: the clock of the fixes and pings.
    static var wallClock: Double { Date().timeIntervalSince1970 }

    var pending: StartLineEnd? { state.pending?.end }
    var lastPingFailed: StartLineEnd? { state.lastPingFailed }
    var warning: OCSWarning? { state.warning }

    /// Both ends are pinged but make no line (the same spot twice, or kilometres apart).
    var hasUnusableEnds: Bool { state.pin != nil && state.boat != nil && state.line == nil }

    /// The pings to record with a session starting now.
    var pingsToRecord: [StartLinePing] { state.pingsToRecord(now: Self.wallClock) }

    func ping(_ end: StartLineEnd) -> StartLinePing? { state.ping(end) }

    // MARK: Countdown

    /// A sailing countdown began: expire an old line, and start location updates (or the
    /// demo feed); the first position decides whether a saved line is reused.
    func countdownBegan(remaining: @escaping () -> Double) {
        self.remaining = remaining
        let before = (state.pin, state.boat)
        state.countdownBegan(now: Self.wallClock)
        if (state.pin, state.boat) != before { save() }
        warningTimer?.cancel()
        prestartWind = PrestartWind()
        wind = nil
        recentFixes = []
        latest = nil
        startUpdates()
    }

    /// The countdown ended. At the gun (`atGun`), a pending ping is finished with the fixes
    /// it has and the start is checked; otherwise a pending ping is finished the same way.
    func countdownEnded(atGun: Bool) {
        if atGun {
            let hadPending = state.pending != nil
            let check = state.gun(
                at: Self.wallClock, latest: latest, shownAt: ProcessInfo.processInfo.systemUptime)
            if hadPending { pingFinished() }
            switch check {
            case .over, .possiblyOver: Haptics.play(.overTheLine)
            case .unknown: Haptics.play(.failure)
            case .clear, nil: break
            }
            scheduleWarningTimeout()
        } else if state.pending != nil {
            state.finishPing()
            pingFinished()
        }
        stopUpdates()
        remaining = nil
    }

    func dismissWarning() {
        state.dismissWarning()
        warningTimer?.cancel()
    }

    /// Fed with every accepted fix while recording, to clear the start warning.
    func recorded(_ fix: GPSFix) {
        latest = fix
        state.recorded(fix)
    }

    /// Clears the warning after `StartLineState.warningShownFor`, with or without GPS.
    private func scheduleWarningTimeout() {
        warningTimer?.cancel()
        guard let shownAt = state.warning?.shownAt else { return }
        warningTimer = Task { [weak self] in
            let wait = shownAt + StartLineState.warningShownFor - ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard !Task.isCancelled else { return }
            self?.state.expireWarning(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: Pings

    /// Pings `end` at the current position, averaged over the fixes around the press.
    func startPing(_ end: StartLineEnd) {
        guard state.pending == nil else { return }
        let pressedAt = Self.wallClock
        var fixes = DemoFeed.isEnabled ? [] : recentFixes
        #if DEBUG
            if DemoFeed.isEnabled {
                // The demo pings fixed ends, through the same averaging.
                let point = DemoFeed.startLineEnd(end)
                fixes = [-1.0, 0, 1].map {
                    GPSFix(t: pressedAt + $0, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 4)
                }
            }
        #endif
        state.startPing(end, at: pressedAt, recentFixes: fixes)
        Haptics.play(.mark)
        let id = UUID()
        pingID = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(StartLinePingAverager.lookAhead + 0.5))
            // Finished early (at the gun) or replaced: nothing to do.
            guard let self, self.pingID == id, self.state.pending != nil else { return }
            self.state.finishPing()
            self.pingFinished()
        }
    }

    func clearLine() {
        state.clear()
        save()
    }

    private func pingFinished() {
        pingID = UUID()
        if state.lastPingFailed != nil {
            Haptics.play(.failure)
        } else {
            save()
            Haptics.play(.sync)
        }
    }

    private func save() {
        let stored = Stored(pin: state.pin, boat: state.boat)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Reading

    func reading(remaining: Double) -> Reading {
        let now = Self.wallClock
        guard let line = state.usableLine(now: now) else { return Reading() }
        var reading = Reading(line: line)
        if let fix = latest, now - fix.t <= Self.freshFor,
            let moved = StartLinePingAverager.project(fix, to: now)
        {
            let place = line.position(
                latitude: moved.latitude, longitude: moved.longitude, speed: fix.speed, course: fix.course)
            reading.position = place
            reading.timeToBurn = place.timeToBurn(remaining: remaining)
        }
        if let wind { reading.bias = line.bias(windFrom: wind.fromDegrees, axisOnly: !wind.resolvedByPrior) }
        return reading
    }

    // MARK: Positions

    private func update(_ fix: GPSFix) {
        latest = fix
        recentFixes.append(fix)
        recentFixes.removeAll { fix.t - $0.t > StartLinePingAverager.lookBack + 1 }
        if state.add(fix, toPing: !DemoFeed.isEnabled) { save() }
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
