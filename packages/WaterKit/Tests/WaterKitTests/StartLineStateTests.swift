import Foundation
import Testing

@testable import WaterKit

/// The start line's countdown state: the start check at the gun, reusing a saved line,
/// pings pending at the gun, expiry, and the warning's timeout (docs/metrics.md, "Start
/// line"). Synthetic coordinates only.
@Suite struct StartLineStateTests {
    /// A 200 m line running east through the fake origin; north is the course side.
    static let centre = (lat: 10.0, lon: -30.0)
    static let pin = Geo.destination(lat: centre.lat, lon: centre.lon, bearing: 270, distance: 100)
    static let boat = Geo.destination(lat: centre.lat, lon: centre.lon, bearing: 90, distance: 100)

    static func ping(_ end: StartLineEnd, at time: Double) -> StartLinePing {
        let point = end == .pin ? pin : boat
        return StartLinePing(end: end, latitude: point.lat, longitude: point.lon, time: time, fixes: 3, accuracy: 4)
    }

    static var line: StartLine { StartLine(pin: ping(.pin, at: 0), boat: ping(.boat, at: 0))! }

    /// A fix `north` m from the centre (positive: over), heading north at `speed`.
    static func fix(t: Double, north: Double, speed: Double? = nil, hacc: Double = 3) -> GPSFix {
        let p = Geo.destination(lat: centre.lat, lon: centre.lon, bearing: north >= 0 ? 0 : 180, distance: abs(north))
        return GPSFix(
            t: t, latitude: p.lat, longitude: p.lon, horizontalAccuracy: hacc, speed: speed,
            course: speed == nil ? nil : 0)
    }

    /// A state with a line pinged during this countdown at `time`.
    static func pinged(at time: Double = 1_000) -> StartLineState {
        var state = StartLineState()
        state.countdownBegan(now: time - 60)
        for end in StartLineEnd.allCases {
            let point = end == .pin ? pin : boat
            state.startPing(
                end, at: time,
                recentFixes: [GPSFix(t: time, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 4)])
            do {
                let result = state.finishPing()
                #expect(result != nil)
            }
        }
        return state
    }

    // MARK: 1. The start check at the gun

    @Test func projectsTheLastFixToTheGun() throws {
        // 8 m behind, 2 s before the gun, at 5 m/s towards the line: 2 m over at the gun.
        let check = StartLineState.check(line: Self.line, at: 102, latest: Self.fix(t: 100, north: -8, speed: 5))
        guard case .over(let distance) = check else {
            Issue.record("expected over, got \(check)")
            return
        }
        #expect(abs(distance - 2) < 0.05)
    }

    @Test func noRecentFixIsUnknownNotClear() {
        let line = Self.line
        #expect(StartLineState.check(line: line, at: 103, latest: Self.fix(t: 100, north: -50, speed: 0)) == .unknown)
        #expect(StartLineState.check(line: line, at: 103, latest: nil) == .unknown)
        // A fix stamped after the gun by more than the limit is not used either.
        #expect(StartLineState.check(line: line, at: 100, latest: Self.fix(t: 103, north: -50)) == .unknown)
    }

    @Test func withinAccuracyAndClosingIsPossiblyOver() {
        let line = Self.line
        // 3 m behind at the gun with 5 m accuracy, heading for the line.
        let close = StartLineState.check(line: line, at: 100, latest: Self.fix(t: 100, north: -3, speed: 1, hacc: 5))
        #expect(
            close == .possiblyOver(distance: 3)
                || {
                    if case .possiblyOver(let d) = close { return abs(d - 3) < 0.01 }
                    return false
                }())
        // The same place stopped, or well behind: clear.
        if case .clear = StartLineState.check(line: line, at: 100, latest: Self.fix(t: 100, north: -3, hacc: 5)) {
        } else {
            Issue.record("stopped boat should be clear")
        }
        if case .clear = StartLineState.check(line: line, at: 100, latest: Self.fix(t: 100, north: -30, speed: 2)) {
        } else {
            Issue.record("30 m behind should be clear")
        }
    }

    @Test func gunSetsAWarningOnlyWhenNotClear() {
        var state = Self.pinged()
        do {
            let result = state.gun(at: 1_100, latest: Self.fix(t: 1_099.5, north: -40, speed: 2), shownAt: 0)
            #expect(result != nil)
        }
        #expect(state.warning == nil)
        state = Self.pinged()
        state.gun(at: 1_100, latest: nil, shownAt: 0)
        #expect(state.warning?.check == .unknown)
    }

    // MARK: 2. A saved line from elsewhere

    @Test func savedLineFarAwayIsDroppedAndNotRecorded() {
        var state = StartLineState(pin: Self.ping(.pin, at: 1_000), boat: Self.ping(.boat, at: 1_000))
        state.countdownBegan(now: 2_000)
        #expect(!state.isVerified)
        // Until a position matches it, it is neither used nor recorded.
        #expect(state.usableLine(now: 2_000) == nil)
        #expect(state.pingsToRecord(now: 2_000).isEmpty)
        // 5 km away: a different venue.
        let far = Geo.destination(lat: Self.centre.lat, lon: Self.centre.lon, bearing: 30, distance: 5_000)
        do {
            let result = state.add(GPSFix(t: 2_001, latitude: far.lat, longitude: far.lon, horizontalAccuracy: 4))
            #expect(result)
        }
        #expect(state.line == nil)
        #expect(state.pingsToRecord(now: 2_001).isEmpty)
        do {
            let result = state.gun(at: 2_100, latest: Self.fix(t: 2_100, north: 10), shownAt: 0)
            #expect(result == nil)
        }
        #expect(state.warning == nil)
    }

    @Test func savedLineNearbyIsReused() {
        var state = StartLineState(pin: Self.ping(.pin, at: 1_000), boat: Self.ping(.boat, at: 1_000))
        state.countdownBegan(now: 2_000)
        do {
            let result = state.add(Self.fix(t: 2_001, north: -400))
            #expect(!result)
        }
        #expect(state.isVerified)
        #expect(state.usableLine(now: 2_001) != nil)
        #expect(state.pingsToRecord(now: 2_001).count == 2)
    }

    @Test func savedEndFarAwayDoesNotDropAnEndPingedNow() {
        // The boat end is saved from elsewhere; the pin is pinged here before any fix
        // was fed (the ping brought its own).
        var state = StartLineState(pin: nil, boat: Self.ping(.boat, at: 1_000))
        state.countdownBegan(now: 2_000)
        let here = Geo.destination(lat: 40, lon: 20, bearing: 0, distance: 0)
        state.startPing(
            .pin, at: 2_010,
            recentFixes: [GPSFix(t: 2_010, latitude: here.lat, longitude: here.lon, horizontalAccuracy: 4)])
        state.finishPing()
        #expect(state.pingsToRecord(now: 2_010).map(\.end) == [.pin])
        state.add(GPSFix(t: 2_011, latitude: here.lat, longitude: here.lon, horizontalAccuracy: 4))
        #expect(state.ping(.boat) == nil)
        #expect(state.ping(.pin) != nil)
    }

    // MARK: 3. A ping pending at the gun

    @Test func pendingPingIsFinishedAtTheGunAndCounts() {
        var state = StartLineState()
        state.countdownBegan(now: 900)
        state.add(Self.fix(t: 950, north: -500))
        state.startPing(
            .pin, at: 999,
            recentFixes: [GPSFix(t: 999, latitude: Self.pin.lat, longitude: Self.pin.lon, horizontalAccuracy: 4)])
        do {
            let result = state.finishPing()
            #expect(result != nil)
        }
        // The boat ping is pressed 1 s before the gun; one fix has arrived.
        state.startPing(.boat, at: 1_099)
        state.add(GPSFix(t: 1_099.5, latitude: Self.boat.lat, longitude: Self.boat.lon, horizontalAccuracy: 4))
        #expect(state.pending != nil)
        let check = state.gun(at: 1_100, latest: Self.fix(t: 1_100, north: 6), shownAt: 0)
        #expect(state.pending == nil)
        #expect(state.ping(.boat) != nil)
        #expect(state.pingsToRecord(now: 1_100).map(\.end) == [.pin, .boat])
        if case .over = check {} else { Issue.record("expected over, got \(String(describing: check))") }
        // The ping's own timer firing later changes nothing.
        do {
            let result = state.finishPing()
            #expect(result == nil)
        }
    }

    @Test func pendingPingWithoutFixesFailsVisiblyAtTheGun() {
        var state = Self.pinged()
        state.startPing(.boat, at: 1_099)
        state.gun(at: 1_100, latest: nil, shownAt: 0)
        #expect(state.pending == nil)
        #expect(state.lastPingFailed == .boat)
        // The earlier boat ping stays.
        #expect(state.ping(.boat) != nil)
    }

    // MARK: 4. Expiry

    @Test func wholeLineExpiresFromItsLastPing() {
        // The pin is 5 h older than the boat: the line lives 6 h from the boat's ping.
        var state = StartLineState(pin: Self.ping(.pin, at: 0), boat: Self.ping(.boat, at: 5 * 3600))
        state.countdownBegan(now: 7 * 3600)
        #expect(state.ping(.pin) != nil)
        do {
            let result = state.add(Self.fix(t: 7 * 3600, north: -50))
            #expect(result == false)
        }
        let edge = 5 * 3600 + StartLineState.keepsLineFor
        #expect(state.usableLine(now: edge) != nil)
        // Read later in the same countdown: gone, and not recorded.
        #expect(state.usableLine(now: edge + 1) == nil)
        #expect(state.pingsToRecord(now: edge + 1).isEmpty)
        do {
            let result = state.gun(at: edge + 1, latest: Self.fix(t: edge + 1, north: 10), shownAt: 0)
            #expect(result == nil)
        }
        #expect(state.pin == nil && state.boat == nil)
    }

    @Test func countdownStartExpiresAnOldLine() {
        var state = StartLineState(pin: Self.ping(.pin, at: 0), boat: Self.ping(.boat, at: 10))
        state.countdownBegan(now: 10 + StartLineState.keepsLineFor + 1)
        #expect(state.pin == nil && state.boat == nil)
        #expect(state.isVerified)
    }

    // MARK: 5. The warning's timeout

    @Test func warningExpiresOnTimeWithoutFixes() {
        var state = Self.pinged()
        state.gun(at: 1_100, latest: Self.fix(t: 1_100, north: 12), shownAt: 50)
        #expect(state.warning != nil)
        do {
            let result = state.expireWarning(now: 50 + StartLineState.warningShownFor - 1)
            #expect(!result)
        }
        #expect(state.warning != nil)
        do {
            let result = state.expireWarning(now: 50 + StartLineState.warningShownFor)
            #expect(result)
        }
        #expect(state.warning == nil)
    }

    @Test func overWarningClearsWhenBackBehind() {
        var state = Self.pinged()
        state.gun(at: 1_100, latest: Self.fix(t: 1_100, north: 12), shownAt: 0)
        state.recorded(Self.fix(t: 1_110, north: 2))
        #expect(state.warning != nil)
        // Behind, but within the fix's accuracy: not yet.
        state.recorded(Self.fix(t: 1_120, north: -2, hacc: 5))
        #expect(state.warning != nil)
        state.recorded(Self.fix(t: 1_130, north: -8, hacc: 5))
        #expect(state.warning == nil)
    }
}
