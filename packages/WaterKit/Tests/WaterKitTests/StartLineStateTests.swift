import Foundation
import Testing

@testable import WaterKit

/// The start line's countdown state: the start check at the gun, reusing a saved line,
/// pings pending at the gun, expiry, the warning's timeout and the countdown clock
/// (docs/metrics.md, "Start line"). Synthetic coordinates only.
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

    /// Two good fixes at an end around `time`: enough for a ping.
    static func endFixes(_ end: StartLineEnd, at time: Double) -> [GPSFix] {
        let point = end == .pin ? pin : boat
        return [time - 0.5, time].map {
            GPSFix(t: $0, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 4)
        }
    }

    /// A state with a line pinged during this countdown at `time`.
    static func pinged(at time: Double = 1_000) -> StartLineState {
        var state = StartLineState()
        state.countdownBegan(now: time - 60)
        for end in StartLineEnd.allCases {
            state.startPing(end, at: time, recentFixes: endFixes(end, at: time))
            let ping = state.finishPing()
            #expect(ping != nil)
        }
        return state
    }

    static func isOver(_ check: StartCheck?) -> Bool {
        if case .over = check { true } else { false }
    }

    static func isPossiblyOver(_ check: StartCheck?) -> Bool {
        if case .possiblyOver = check { true } else { false }
    }

    static func isClear(_ check: StartCheck?) -> Bool {
        if case .clear = check { true } else { false }
    }

    // MARK: The start check at the gun

    @Test func projectsTheLastFixToTheGun() throws {
        // 8 m behind, 2 s before the gun, at 5 m/s towards the line: 2 m over at the gun.
        let check = StartLineState.check(line: Self.line, at: 102, fixes: [Self.fix(t: 100, north: -8, speed: 5)])
        guard case .over(let distance) = check else {
            Issue.record("expected over, got \(check)")
            return
        }
        #expect(abs(distance - 2) < 0.05)
    }

    @Test func noRecentFixIsUnknownNotClear() {
        let line = Self.line
        #expect(StartLineState.check(line: line, at: 103, fixes: [Self.fix(t: 100, north: -50, speed: 2)]) == .unknown)
        #expect(StartLineState.check(line: line, at: 103, fixes: []) == .unknown)
    }

    @Test func fixesAfterTheGunAreNotUsed() {
        // A late callback: the boat crossed legally 2 s after the gun. Only fixes at or
        // before the gun count; the one before says clear.
        let fixes = [Self.fix(t: 99, north: -6, speed: 2), Self.fix(t: 102, north: 0.5, speed: 2)]
        #expect(Self.isClear(StartLineState.check(line: Self.line, at: 100, fixes: fixes)))
        // With only the after-gun fix there is nothing to judge by.
        #expect(StartLineState.check(line: Self.line, at: 100, fixes: [fixes[1]]) == .unknown)
        // A fix a hair after the gun still counts.
        #expect(
            Self.isOver(StartLineState.check(line: Self.line, at: 100, fixes: [Self.fix(t: 100.2, north: 4, speed: 2)]))
        )
    }

    @Test func withinAccuracyAndClosingIsPossiblyOver() {
        let line = Self.line
        // 3 m behind at the gun with 5 m accuracy, heading for the line.
        #expect(
            Self.isPossiblyOver(
                StartLineState.check(line: line, at: 100, fixes: [Self.fix(t: 100, north: -3, speed: 1, hacc: 5)])))
        // Well behind: clear.
        #expect(
            Self.isClear(StartLineState.check(line: line, at: 100, fixes: [Self.fix(t: 100, north: -30, speed: 2)])))
    }

    @Test func slowBoatIsNotProjectedNorCalledWithinAccuracy() {
        let line = Self.line
        // 0.2 m/s "towards" the line, 2 s before the gun: course is noise, no projection.
        let slow = Self.fix(t: 98, north: -1, speed: 0.2, hacc: 5)
        let moved = StartLinePingAverager.project(slow, to: 100)
        #expect(moved?.latitude == slow.latitude)
        // Over or behind within accuracy, slow or stopped: possibly, never definite.
        #expect(Self.isPossiblyOver(StartLineState.check(line: line, at: 100, fixes: [slow])))
        #expect(
            Self.isPossiblyOver(StartLineState.check(line: line, at: 100, fixes: [Self.fix(t: 100, north: 2, hacc: 5)]))
        )
        // Clearly over while drifting: still over.
        #expect(
            Self.isOver(
                StartLineState.check(line: line, at: 100, fixes: [Self.fix(t: 100, north: 20, speed: 0.1, hacc: 5)])))
    }

    @Test func gunSetsAWarningOnlyWhenNotClear() {
        var state = Self.pinged()
        state.gun(at: 1_100, fixes: [Self.fix(t: 1_099.5, north: -40, speed: 2)], shownAt: 0)
        #expect(state.warning == nil)
        state = Self.pinged()
        state.gun(at: 1_100, fixes: [], shownAt: 0)
        #expect(state.warning?.check == .unknown)
    }

    // MARK: A saved line from elsewhere

    @Test func savedLineFarAwayIsIgnoredNotDeleted() {
        var state = StartLineState(pin: Self.ping(.pin, at: 1_000), boat: Self.ping(.boat, at: 1_000))
        state.countdownBegan(now: 2_000)
        #expect(state.isAwaitingVenue)
        // Until a fresh position matches it, it is neither used nor recorded.
        #expect(state.usableLine(now: 2_000) == nil)
        #expect(state.pingsToRecord(now: 2_000).isEmpty)
        // 5 km away: a different venue. Ignored this countdown, still stored.
        let far = Geo.destination(lat: Self.centre.lat, lon: Self.centre.lon, bearing: 30, distance: 5_000)
        state.add(GPSFix(t: 2_001, latitude: far.lat, longitude: far.lon, horizontalAccuracy: 4), now: 2_001)
        #expect(!state.isAwaitingVenue)
        #expect(state.line == nil)
        #expect(state.stored(.pin) != nil && state.stored(.boat) != nil)
        #expect(state.pingsToRecord(now: 2_001).isEmpty)
        #expect(state.gun(at: 2_100, fixes: [Self.fix(t: 2_100, north: 10)], shownAt: 0) == nil)
        #expect(state.warning == nil)
        // Back at the venue in a later countdown: used again.
        state.countdownBegan(now: 3_000)
        state.add(Self.fix(t: 3_001, north: -300), now: 3_001)
        #expect(state.usableLine(now: 3_001) != nil)
    }

    @Test func staleOrRoughFixesDoNotDecide() {
        var state = StartLineState(pin: Self.ping(.pin, at: 1_000), boat: Self.ping(.boat, at: 1_000))
        state.countdownBegan(now: 2_000)
        let far = Geo.destination(lat: Self.centre.lat, lon: Self.centre.lon, bearing: 30, distance: 5_000)
        // A cached fix from 30 s ago, a 60 m one, and one with no accuracy: no decision.
        state.add(GPSFix(t: 1_970, latitude: far.lat, longitude: far.lon, horizontalAccuracy: 4), now: 2_000)
        state.add(GPSFix(t: 2_000, latitude: far.lat, longitude: far.lon, horizontalAccuracy: 60), now: 2_000)
        state.add(GPSFix(t: 2_000, latitude: far.lat, longitude: far.lon), now: 2_000)
        #expect(state.isAwaitingVenue)
        #expect(state.line == nil)
        // A fresh, accurate fix near the line decides.
        state.add(Self.fix(t: 2_002, north: -400), now: 2_003)
        #expect(!state.isAwaitingVenue)
        #expect(state.usableLine(now: 2_003) != nil)
        #expect(state.pingsToRecord(now: 2_003).count == 2)
    }

    @Test func savedEndFarAwayDoesNotBlockAnEndPingedNow() {
        // The boat end is saved from elsewhere; the pin is pinged here.
        var state = StartLineState(pin: nil, boat: Self.ping(.boat, at: 1_000))
        state.countdownBegan(now: 2_000)
        let here = (lat: 40.0, lon: 20.0)
        let fixes = [2_009.5, 2_010].map {
            GPSFix(t: $0, latitude: here.lat, longitude: here.lon, horizontalAccuracy: 4)
        }
        state.startPing(.pin, at: 2_010, recentFixes: fixes)
        state.finishPing()
        #expect(state.pingsToRecord(now: 2_010).map(\.end) == [.pin])
        state.add(fixes[1], now: 2_010)
        #expect(state.boat == nil)
        #expect(state.pin != nil)
    }

    // MARK: A ping pending at the gun

    @Test func pendingPingIsFinishedAtTheGunAndCounts() {
        var state = StartLineState()
        state.countdownBegan(now: 900)
        state.startPing(.pin, at: 999, recentFixes: Self.endFixes(.pin, at: 999))
        let pin = state.finishPing()
        #expect(pin != nil)
        // The boat ping is pressed 1 s before the gun; two fixes have arrived.
        state.startPing(.boat, at: 1_099, recentFixes: Self.endFixes(.boat, at: 1_099))
        #expect(state.pending != nil)
        let check = state.gun(at: 1_100, fixes: [Self.fix(t: 1_100, north: 6, speed: 2)], shownAt: 0)
        #expect(state.pending == nil)
        #expect(state.boat != nil)
        #expect(state.failedAtStart == nil)
        #expect(state.pingsToRecord(now: 1_100).map(\.end) == [.pin, .boat])
        #expect(Self.isOver(check))
        // The ping's own timer firing later changes nothing.
        let late = state.finishPing()
        #expect(late == nil)
    }

    @Test func pendingPingWithTooFewFixesFailsVisiblyAtTheGun() {
        var state = Self.pinged()
        state.startPing(.boat, at: 1_099, recentFixes: [Self.endFixes(.boat, at: 1_099)[1]])
        state.gun(at: 1_100, fixes: [], shownAt: 0)
        #expect(state.pending == nil)
        #expect(state.lastPingFailed == .boat)
        // Reported for the session screens.
        #expect(state.failedAtStart == .boat)
        // The earlier boat ping stays.
        #expect(state.boat != nil)
        state.dismissFailedAtStart()
        #expect(state.failedAtStart == nil)
    }

    @Test func pingFailureShortlyBeforeTheGunIsReportedAfterIt() {
        var state = Self.pinged()
        state.startPing(.pin, at: 1_090)
        state.finishPing()
        state.gun(at: 1_100, fixes: [], shownAt: 0)
        #expect(state.failedAtStart == .pin)
        // An old failure is not.
        state = Self.pinged()
        state.startPing(.pin, at: 1_010)
        state.finishPing()
        state.gun(at: 1_100, fixes: [], shownAt: 0)
        #expect(state.failedAtStart == nil)
    }

    @Test func singleFixIsNotAPing() {
        var averager = StartLinePingAverager(end: .pin, pressedAt: 10)
        averager.add(GPSFix(t: 10, latitude: 1, longitude: 1, horizontalAccuracy: 4))
        #expect(averager.ping == nil)
        averager.add(GPSFix(t: 10.5, latitude: 1, longitude: 1, horizontalAccuracy: 4))
        #expect(averager.ping != nil)
    }

    // MARK: Expiry

    @Test func wholeLineExpiresFromItsLastPing() {
        // The pin is 5 h older than the boat: the line lives 6 h from the boat's ping.
        var state = StartLineState(pin: Self.ping(.pin, at: 0), boat: Self.ping(.boat, at: 5 * 3600))
        state.countdownBegan(now: 7 * 3600)
        state.add(Self.fix(t: 7 * 3600, north: -50), now: 7 * 3600)
        let edge = 5 * 3600 + StartLineState.keepsLineFor
        #expect(state.usableLine(now: edge) != nil)
        // Read later in the same countdown: gone, and not recorded.
        #expect(state.usableLine(now: edge + 1) == nil)
        #expect(state.pingsToRecord(now: edge + 1).isEmpty)
        #expect(state.gun(at: edge + 1, fixes: [Self.fix(t: edge + 1, north: 10)], shownAt: 0) == nil)
        #expect(state.stored(.pin) == nil && state.stored(.boat) == nil)
    }

    @Test func countdownStartExpiresAnOldLine() {
        var state = StartLineState(pin: Self.ping(.pin, at: 0), boat: Self.ping(.boat, at: 10))
        state.countdownBegan(now: 10 + StartLineState.keepsLineFor + 1)
        #expect(state.stored(.pin) == nil && state.stored(.boat) == nil)
        #expect(!state.isAwaitingVenue)
    }

    @Test func repingingOneEndDoesNotReviveAnExpiredOne() {
        var state = Self.pinged(at: 1_000)
        let later = 1_000 + StartLineState.keepsLineFor + 60
        // Same countdown carried on past expiry: re-ping the pin.
        state.startPing(.pin, at: later, recentFixes: Self.endFixes(.pin, at: later))
        state.finishPing()
        #expect(state.pin != nil)
        #expect(state.boat == nil)
        #expect(state.stored(.boat) == nil)
        #expect(state.line == nil)
    }

    @Test func gunChecksExpiryBeforeFinishingAPendingPing() {
        var state = Self.pinged(at: 1_000)
        let gun = 1_000 + StartLineState.keepsLineFor + 30
        // A pending ping pressed after the boat end expired: the old boat end is dropped
        // before the new pin is stored, so no line and no check.
        state.startPing(.pin, at: gun - 1, recentFixes: Self.endFixes(.pin, at: gun - 1))
        #expect(state.gun(at: gun, fixes: [Self.fix(t: gun, north: 5, speed: 2)], shownAt: 0) == nil)
        #expect(state.pin != nil)
        #expect(state.boat == nil)
        #expect(state.warning == nil)
    }

    // MARK: The warning's timeout

    @Test func warningExpiresOnTimeWithoutFixes() {
        var state = Self.pinged()
        state.gun(at: 1_100, fixes: [Self.fix(t: 1_100, north: 12, speed: 2)], shownAt: 50)
        #expect(state.warning != nil)
        let early = state.expireWarning(now: 50 + StartLineState.warningShownFor - 1)
        #expect(!early)
        #expect(state.warning != nil)
        let onTime = state.expireWarning(now: 50 + StartLineState.warningShownFor)
        #expect(onTime)
        #expect(state.warning == nil)
    }

    @Test func overWarningClearsWhenBackBehind() {
        var state = Self.pinged()
        state.gun(at: 1_100, fixes: [Self.fix(t: 1_100, north: 12, speed: 2)], shownAt: 0)
        state.recorded(Self.fix(t: 1_110, north: 2))
        #expect(state.warning != nil)
        // Behind, but within the fix's accuracy: not yet.
        state.recorded(Self.fix(t: 1_120, north: -2, hacc: 5))
        #expect(state.warning != nil)
        state.recorded(Self.fix(t: 1_130, north: -8, hacc: 5))
        #expect(state.warning == nil)
    }

    // MARK: The countdown clock

    @Test func countdownClockIgnoresWallClockJumps() {
        // Anchored at unix 1000 = uptime 50. The gun deadline is uptime 350.
        let clock = CountdownClock(unix: 1_000, uptime: 50)
        #expect(clock.unix(atUptime: 350) == 1_300)
        // A fix 0.5 s old on arrival at uptime 349, with the wall clock still right.
        #expect(clock.fixTime(1_298.5, receivedUptime: 349, receivedWall: 1_299) == 1_298.5)
        // The wall clock jumped 1 h back: the fix's own stamp and the arrival time moved
        // together, so its time on the countdown clock is unchanged.
        #expect(clock.fixTime(1_298.5 - 3_600, receivedUptime: 349, receivedWall: 1_299 - 3_600) == 1_298.5)
        // An old cached fix delivered now keeps its age rather than looking fresh.
        #expect(clock.fixTime(1_200, receivedUptime: 349, receivedWall: 1_299) == 1_200)
    }
}
