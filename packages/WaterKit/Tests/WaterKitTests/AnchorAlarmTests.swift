import Foundation
import Testing

@testable import WaterKit

/// A small deterministic random source, so noisy tracks are the same every run.
private struct SeededRandom {
    var state: UInt64

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    /// Approximately normal (sum of uniforms), mean 0, standard deviation `sigma`.
    mutating func gaussian(_ sigma: Double) -> Double {
        var sum = 0.0
        for _ in 0..<12 { sum += next() }
        return (sum - 6) * sigma
    }
}

private let origin = (lat: 10.0, lon: -30.0)

/// A fix `distance` m from the anchor on `bearing`, with GPS noise of `noise` m.
private func fix(
    t: Double, distance: Double, bearing: Double, hacc: Double? = 6, noise: Double = 0,
    random: inout SeededRandom
) -> GPSFix {
    var point = Geo.destination(lat: origin.lat, lon: origin.lon, bearing: bearing, distance: distance)
    if noise > 0 {
        let north = random.gaussian(noise)
        let east = random.gaussian(noise)
        let offset = (north * north + east * east).squareRoot()
        let direction = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        point = Geo.destination(lat: point.lat, lon: point.lon, bearing: direction, distance: offset)
    }
    return GPSFix(t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: hacc)
}

private func armed(radius: Double = 40, at t: Double = 0) -> AnchorAlarm {
    var alarm = AnchorAlarm()
    let result1 = alarm.set(latitude: origin.lat, longitude: origin.lon, radius: radius, at: t)
    #expect(result1)
    return alarm
}

/// A boat lying to its anchor: swinging on a 25 m rode as the wind veers back and forth.
private func swing(_ t: Double) -> (distance: Double, bearing: Double) {
    (25 - 3 * cos(t / 47), 200 + 60 * sin(t / 300))
}

@Suite struct AnchorAlarmTests {
    @Test func startsClearAndArmsOnlyWithValidInput() {
        var alarm = AnchorAlarm()
        #expect(alarm.state == .clear && !alarm.isArmed)
        let result2 = alarm.set(latitude: 91, longitude: 0, radius: 40, at: 0)
        #expect(!result2)
        let result3 = alarm.set(latitude: 0, longitude: 0, radius: 2, at: 0)
        #expect(!result3)
        let result4 = alarm.set(latitude: 0, longitude: 0, radius: .infinity, at: 0)
        #expect(!result4)
        #expect(alarm.state == .clear)
        let result5 = alarm.set(latitude: 0, longitude: 0, radius: 40, at: 0)
        #expect(result5)
        #expect(alarm.state == .armed)
        alarm.clear()
        #expect(alarm.state == .clear && alarm.anchor == nil)
        // Fixes without an anchor do nothing.
        var random = SeededRandom(state: 1)
        let result6 = alarm.ingest(fix(t: 1, distance: 500, bearing: 0, random: &random))
        #expect(!result6)
    }

    @Test func twelveHoursOfNoisySwingingNeverAlarms() {
        var alarm = armed(radius: 40)
        var random = SeededRandom(state: 42)
        // 1 Hz for 12 h: swing radius ≤ 28 m, GPS noise σ = 5 m with hacc 4–12 m.
        for second in 1...(12 * 3600) {
            let t = Double(second)
            let (distance, bearing) = swing(t)
            let hacc = 4 + 8 * random.next()
            alarm.ingest(fix(t: t, distance: distance, bearing: bearing, hacc: hacc, noise: 5, random: &random))
            #expect(alarm.state == .armed, "false alarm at t = \(t)")
            if alarm.state != .armed { break }
        }
        #expect((alarm.maxDistance ?? 0) > 28)
    }

    @Test func oneOffJumpsAreIgnored() {
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 7)
        var t = 0.0
        for burst in [1, 2, 1, 2, 2] {
            for _ in 0..<20 {
                t += 1
                alarm.ingest(fix(t: t, distance: 15, bearing: 90, random: &random))
            }
            // A multipath burst far outside, then back.
            for _ in 0..<burst {
                t += 1
                alarm.ingest(fix(t: t, distance: 150, bearing: 10, hacc: 8, random: &random))
            }
        }
        #expect(alarm.state == .armed)
        // Even three far fixes are not enough if they span less than the confirm time.
        var quick = armed(radius: 30)
        for step in 0..<3 {
            quick.ingest(fix(t: 1 + Double(step) * 0.5, distance: 150, bearing: 10, random: &random))
        }
        #expect(quick.state == .armed)
    }

    @Test func realDragAlarmsSoonAfterLeavingTheCircle() throws {
        var alarm = armed(radius: 40)
        var random = SeededRandom(state: 99)
        var alarmAt: Double?
        var crossedAt: Double?
        // An hour holding, then the anchor lets go: the boat drags downwind at 0.4 m/s.
        for second in 1...(2 * 3600) {
            let t = Double(second)
            let holding = swing(t)
            let drag = max(0, t - 3600) * 0.4
            let distance = holding.distance + drag
            if crossedAt == nil, distance > 40 { crossedAt = t }
            alarm.ingest(fix(t: t, distance: distance, bearing: 200, hacc: 8, noise: 4, random: &random))
            if alarm.state.isAlarming {
                alarmAt = t
                break
            }
        }
        let alarmed = try #require(alarmAt)
        let crossed = try #require(crossedAt)
        #expect(alarm.state == .alarming(.dragging))
        #expect(alarmed > 3600)
        // Accuracy margin (8 m + noise at 0.4 m/s ≈ 30 s) plus the 10 s confirmation.
        #expect(alarmed - crossed < 60)
        #expect((alarm.distance ?? 0) > 40)
        #expect(alarm.bearing.map { abs($0 - 20) < 15 } == true)  // back toward the anchor
    }

    @Test func dragAlarmLatchesUntilSilencedAndReturnsIfStillOutside() {
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 3)
        for second in 1...15 {
            alarm.ingest(fix(t: Double(second), distance: 60, bearing: 0, random: &random))
        }
        #expect(alarm.state == .alarming(.dragging))
        // Swinging back inside does not silence a dragging alarm.
        alarm.ingest(fix(t: 16, distance: 5, bearing: 0, random: &random))
        #expect(alarm.state == .alarming(.dragging))

        alarm.silence(at: 17)
        #expect(alarm.state == .armed)
        // Still outside, but silenced for 60 s.
        for second in 18...76 {
            alarm.ingest(fix(t: Double(second), distance: 60, bearing: 0, random: &random))
            #expect(alarm.state == .armed)
        }
        alarm.ingest(fix(t: 78, distance: 60, bearing: 0, random: &random))
        #expect(alarm.state == .alarming(.dragging))
    }

    @Test func separateExcursionsAreNotBridged() {
        // Radius 30 m, hacc 10 m: 35 m is inconclusive (35 − 10 < 30 but 35 > 30).
        // Review regression: 50 m (s 1–2), 35 m (s 3–20), 50 m (s 21) used to alarm by
        // bridging two separate outside readings across the inconclusive ones. More
        // than two inconclusive fixes in a row separate them.
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 5)
        alarm.ingest(fix(t: 1, distance: 50, bearing: 0, hacc: 10, random: &random))
        alarm.ingest(fix(t: 2, distance: 50, bearing: 0, hacc: 10, random: &random))
        for second in 3...20 {
            alarm.ingest(fix(t: Double(second), distance: 35, bearing: 0, hacc: 10, random: &random))
        }
        alarm.ingest(fix(t: 21, distance: 50, bearing: 0, hacc: 10, random: &random))
        #expect(alarm.state == .armed)
        // Only an unbroken run of clearly-outside fixes over 10 s confirms.
        for second in 22...30 {
            alarm.ingest(fix(t: Double(second), distance: 50, bearing: 0, hacc: 10, random: &random))
            #expect(alarm.state == .armed)
        }
        alarm.ingest(fix(t: 31, distance: 50, bearing: 0, hacc: 10, random: &random))
        #expect(alarm.state == .alarming(.dragging))

        // An inside fix resets the evidence.
        var reset = armed(radius: 30)
        reset.ingest(fix(t: 1, distance: 50, bearing: 0, hacc: 10, random: &random))
        reset.ingest(fix(t: 2, distance: 50, bearing: 0, hacc: 10, random: &random))
        reset.ingest(fix(t: 3, distance: 20, bearing: 0, hacc: 10, random: &random))
        reset.ingest(fix(t: 15, distance: 50, bearing: 0, hacc: 10, random: &random))
        #expect(reset.state == .armed)
    }

    @Test func poorAccuracyIsIgnoredAndSilentGPSAlarms() {
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 11)
        // Far away but with accuracy worse than 25 m, or none: not evidence of a drag.
        for second in 1...119 {
            let hacc: Double? = second.isMultiple(of: 2) ? 65 : nil
            alarm.ingest(fix(t: Double(second), distance: 120, bearing: 0, hacc: hacc, random: &random))
            #expect(alarm.state == .armed)
        }
        #expect(alarm.distance == nil)
        alarm.advance(to: 120)
        #expect(alarm.state == .alarming(.gpsLost))
        // A usable fix inside clears a GPS alarm.
        alarm.ingest(fix(t: 121, distance: 10, bearing: 0, random: &random))
        #expect(alarm.state == .armed)
        #expect(alarm.distance.map { abs($0 - 10) < 0.01 } == true)
        // Out-of-order fixes are ignored.
        let result7 = alarm.ingest(fix(t: 100, distance: 500, bearing: 0, random: &random))
        #expect(!result7)
        #expect(alarm.lastFixTime == 121)
    }

    @Test func changingTheRadiusRestartsTheEvidence() {
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 13)
        for second in 1...8 {
            alarm.ingest(fix(t: Double(second), distance: 45, bearing: 0, random: &random))
        }
        let result8 = alarm.setRadius(50)
        #expect(result8)
        for second in 9...30 {
            alarm.ingest(fix(t: Double(second), distance: 45, bearing: 0, random: &random))
        }
        #expect(alarm.state == .armed)
        let result9 = alarm.setRadius(1)
        #expect(!result9)
        #expect(alarm.anchor?.radius == 50)
    }

    @Test func savedAlarmRoundTrips() throws {
        var alarm = armed(radius: 50, at: 1000)
        var random = SeededRandom(state: 17)
        for second in 1001...1020 {
            alarm.ingest(fix(t: Double(second), distance: 90, bearing: 0, random: &random))
        }
        let data = try JSONEncoder().encode(alarm)
        let decoded = try JSONDecoder().decode(AnchorAlarm.self, from: data)
        #expect(decoded == alarm)
        #expect(decoded.state == .alarming(.dragging))
    }

    @Test func anchorPointAveragesRecentGoodFixes() throws {
        var random = SeededRandom(state: 23)
        var fixes: [GPSFix] = []
        for second in 0..<30 {
            fixes.append(fix(t: Double(second), distance: 0, bearing: 0, hacc: 5, noise: 4, random: &random))
        }
        // A wild fix with poor accuracy, and an old one far away, are left out.
        fixes.append(fix(t: 29.5, distance: 300, bearing: 90, hacc: 80, random: &random))
        fixes.insert(fix(t: -100, distance: 300, bearing: 90, hacc: 5, random: &random), at: 0)
        let point = try #require(AnchorAlarm.anchorPoint(from: fixes, at: 30))
        let error = Geo.distance(lat1: point.latitude, lon1: point.longitude, lat2: origin.lat, lon2: origin.lon)
        #expect(error < 4)
        #expect(AnchorAlarm.anchorPoint(from: [], at: 30) == nil)
        let single = try #require(AnchorAlarm.anchorPoint(from: [fixes[5]], at: 5))
        #expect(single.latitude == fixes[5].latitude && single.longitude == fixes[5].longitude)
    }

    @Test func oneInconclusiveFixPerWindowCannotHideADrag() {
        // Re-check regression: 9 s at 45 m then one 39 m reading (inconclusive with
        // 10 m accuracy), repeating, used to reset the evidence forever.
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 43)
        var alarmAt: Double?
        for second in 1...120 {
            let distance = second.isMultiple(of: 10) ? 39.0 : 45.0
            alarm.ingest(fix(t: Double(second), distance: distance, bearing: 0, hacc: 10, random: &random))
            if alarm.state.isAlarming {
                alarmAt = Double(second)
                break
            }
        }
        #expect(alarm.state == .alarming(.dragging))
        #expect(alarmAt == 11)
        // An inside fix still clears the evidence.
        var cleared = armed(radius: 30)
        for second in 1...9 {
            cleared.ingest(fix(t: Double(second), distance: 45, bearing: 0, hacc: 10, random: &random))
        }
        cleared.ingest(fix(t: 10, distance: 25, bearing: 0, hacc: 10, random: &random))
        cleared.ingest(fix(t: 11, distance: 45, bearing: 0, hacc: 10, random: &random))
        #expect(cleared.state == .armed)
    }

    @Test func aRestoredAlarmGetsAGracePeriodOnTheNewClock() {
        // Re-check regressions: a relaunch must not raise "no GPS" from a stale saved
        // fix time, and saved times from another clock must not hide new fixes.
        var alarm = armed(radius: 30, at: 50_000)
        var random = SeededRandom(state: 47)
        for second in 50_001...50_009 {
            alarm.ingest(fix(t: Double(second), distance: 45, bearing: 0, random: &random))
        }
        alarm.silence(at: 50_009)
        var restored = alarm
        // The new process's uptime clock starts near zero.
        restored.resume(at: 12)
        #expect(restored.state == .armed)
        #expect(restored.gpsLostDeadline == 132)
        let early = restored.advance(to: 131)
        #expect(!early)
        // Fixes on the new clock are accepted although the old times were larger.
        let changed = restored.ingest(fix(t: 13, distance: 5, bearing: 0, random: &random))
        #expect(!changed)
        #expect(restored.lastFixTime == 13)
        // The old outside evidence and silence are gone: a fresh 10 s drag is needed.
        for second in 14...23 {
            restored.ingest(fix(t: Double(second), distance: 45, bearing: 0, random: &random))
        }
        #expect(restored.state == .armed)
        restored.ingest(fix(t: 24, distance: 45, bearing: 0, random: &random))
        #expect(restored.state == .alarming(.dragging))
        // A restored alarm stays alarming, with its cadence from the new clock.
        var sounding = restored
        sounding.resume(at: 5)
        #expect(sounding.state == .alarming(.dragging))
        #expect(sounding.alarmingSince == 5)
        // GPS lost after the grace period.
        var quiet = alarm
        quiet.resume(at: 0)
        let lost = quiet.advance(to: 120)
        #expect(lost)
        #expect(quiet.state == .alarming(.gpsLost))
    }

    /// Extra-round regression: at sparse cadences (8 s) a fixed 15 s window never held
    /// three fixes, so a sustained drag never alarmed. Holding for 30 min, then dragging
    /// at 0.4 m/s, with fixes every `cadence` seconds.
    @Test(arguments: [1.0, 6.0, 8.0, 15.0, 30.0])
    func dragAlarmsAtAnyFixCadence(cadence: Double) throws {
        var alarm = armed(radius: 40)
        var random = SeededRandom(state: 53)
        var crossedAt: Double?
        var alarmAt: Double?
        var t = 0.0
        while t < 2 * 3600 {
            t += cadence
            let holding = swing(t)
            let distance = holding.distance + max(0, t - 1800) * 0.4
            if crossedAt == nil, distance - 8 > 40 { crossedAt = t }
            alarm.ingest(fix(t: t, distance: distance, bearing: 200, hacc: 8, noise: 3, random: &random))
            #expect(alarm.state != .alarming(.gpsLost))
            if alarm.state.isAlarming {
                alarmAt = t
                break
            }
        }
        let alarmed = try #require(alarmAt, "no alarm at a \(cadence) s cadence")
        let crossed = try #require(crossedAt)
        #expect(alarmed > 1800)
        // Three outside fixes spanning ≥ 10 s, plus noise: about three fixes after leaving.
        #expect(alarmed - crossed <= max(3 * cadence, 10) + 20)
    }

    @Test(arguments: [1.0, 6.0, 8.0, 15.0, 30.0])
    func noisySwingingNeverAlarmsAtAnyFixCadence(cadence: Double) {
        var alarm = armed(radius: 40)
        var random = SeededRandom(state: 59)
        var t = 0.0
        while t < 4 * 3600 {
            t += cadence
            let (distance, bearing) = swing(t)
            alarm.ingest(
                fix(t: t, distance: distance, bearing: bearing, hacc: 4 + 8 * random.next(), noise: 5, random: &random))
            if alarm.state != .armed { break }
        }
        #expect(alarm.state == .armed)
    }

    @Test func outsideReadingsFarApartInTimeAreSeparate() {
        // Outside fixes more than the GPS-lost limit apart never join (that gap raises the
        // GPS alarm instead).
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 61)
        alarm.ingest(fix(t: 1, distance: 50, bearing: 0, random: &random))
        alarm.ingest(fix(t: 100, distance: 50, bearing: 0, random: &random))
        #expect(alarm.state == .armed)
        alarm.ingest(fix(t: 230, distance: 50, bearing: 0, random: &random))
        #expect(alarm.state == .alarming(.gpsLost))
        alarm.ingest(fix(t: 231, distance: 50, bearing: 0, random: &random))
        #expect(alarm.state == .armed)
    }

    @Test func relaunchNeverPostponesAPendingNoGPSDeadline() {
        // Extra-round regression: no fix for 119 s, then a relaunch, used to move the
        // first no-GPS alert to about 239 s; repeated relaunches postponed it forever.
        var alarm = armed(radius: 30, at: 1000)
        var random = SeededRandom(state: 67)
        alarm.ingest(fix(t: 1001, distance: 5, bearing: 0, random: &random))
        let saved = alarm
        // Relaunched 119 s later; the previous deadline is 2 s away on the new clock.
        var restored = saved
        restored.resume(at: 50, gpsLostDeadline: 52)
        #expect(restored.gpsLostDeadline == 52)
        let early = restored.advance(to: 51)
        #expect(!early)
        let lost = restored.advance(to: 52)
        #expect(lost)
        // A deadline already passed alarms at once.
        var late = saved
        late.resume(at: 50, gpsLostDeadline: 10)
        let now = late.advance(to: 50)
        #expect(now)
        // A later deadline is never adopted; a usable fix moves it later as usual.
        var later = saved
        later.resume(at: 50, gpsLostDeadline: 500)
        #expect(later.gpsLostDeadline == 170)
        var fixed = saved
        fixed.resume(at: 50, gpsLostDeadline: 52)
        fixed.ingest(fix(t: 51, distance: 5, bearing: 0, random: &random))
        #expect(fixed.gpsLostDeadline == 171)
    }

    @Test func anchorPointNeverUsesAnOldPosition() {
        // Review regression: a fresh but inaccurate fix must not let arming fall back to
        // a usable fix from 25 s ago, 100 m away.
        var random = SeededRandom(state: 29)
        let old = fix(t: 0, distance: 100, bearing: 90, hacc: 5, random: &random)
        let freshButPoor = fix(t: 25, distance: 0, bearing: 0, hacc: 40, random: &random)
        #expect(AnchorAlarm.anchorPoint(from: [old, freshButPoor], at: 25) == nil)
        // A usable fix measured 9 s ago is still accepted, one from 11 s ago is not.
        let nine = fix(t: 16, distance: 0, bearing: 0, hacc: 5, random: &random)
        #expect(AnchorAlarm.anchorPoint(from: [old, nine, freshButPoor], at: 25) != nil)
        let eleven = fix(t: 14, distance: 0, bearing: 0, hacc: 5, random: &random)
        #expect(AnchorAlarm.anchorPoint(from: [old, eleven, freshButPoor], at: 25) == nil)
    }

    @Test func aFixAfterASuspendedGapRaisesTheGPSAlarmFirst() {
        // Review regression: when the app was suspended without fixes, the fix that
        // wakes it must not silently overwrite the last-fix time.
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 31)
        alarm.ingest(fix(t: 10, distance: 5, bearing: 0, random: &random))
        #expect(alarm.gpsLostDeadline == 130)
        let changed = alarm.ingest(fix(t: 400, distance: 5, bearing: 0, random: &random))
        #expect(changed)
        #expect(alarm.state == .alarming(.gpsLost))
        #expect(alarm.alarmingSince == 400)
        #expect(alarm.distance.map { abs($0 - 5) < 0.01 } == true)
        // The next fix shows GPS is back.
        alarm.ingest(fix(t: 401, distance: 5, bearing: 0, random: &random))
        #expect(alarm.state == .armed)
        // A gap shorter than the limit is fine.
        alarm.ingest(fix(t: 500, distance: 5, bearing: 0, random: &random))
        #expect(alarm.state == .armed)
    }

    @Test func alertScheduleKeepsADeadMansSwitchAndRepeats() throws {
        var alarm = armed(radius: 30, at: 0)
        var random = SeededRandom(state: 37)
        #expect(AnchorAlertSchedule.pending(for: AnchorAlarm(), now: 0).isEmpty)
        alarm.ingest(fix(t: 50, distance: 5, bearing: 0, random: &random))
        // Armed: one notification for lost GPS, 120 s after the last usable fix, moved
        // by every new fix.
        #expect(
            AnchorAlertSchedule.pending(for: alarm, now: 55)
                == [.init(id: AnchorAlertSchedule.gpsLostID, fireAt: 170, reason: .gpsLost)])
        // Alarming: repeats from the alarm start, never in the past, no dead-man's switch.
        for second in 51...65 {
            alarm.ingest(fix(t: Double(second), distance: 80, bearing: 0, random: &random))
        }
        let since = try #require(alarm.alarmingSince)
        let pending = AnchorAlertSchedule.pending(for: alarm, now: since + 45)
        let repeats = pending.filter { $0.repeatsEvery == nil }
        #expect(repeats.first?.fireAt == since + 60)
        #expect(pending.allSatisfy { $0.reason == .dragging && $0.id != AnchorAlertSchedule.gpsLostID })
        #expect(repeats.count == AnchorAlertSchedule.repeatCount)
        #expect(Set(repeats.map(\.id)).count == AnchorAlertSchedule.repeatCount)
        // Re-check regression: alerts must not run out while the app is suspended. A
        // repeating notification stays pending for as long as the alarm sounds.
        let forever = pending.filter { $0.repeatsEvery != nil }
        #expect(forever.map(\.id) == [AnchorAlertSchedule.repeatingID])
        #expect(forever.first?.repeatsEvery == 60)
        // Hours later (a restored alarm), repeats still lie ahead on the same cadence.
        let later = AnchorAlertSchedule.pending(for: alarm, now: since + 3600 + 5)
        #expect(later.first?.fireAt == since + 3630)
        #expect(later.filter { $0.repeatsEvery == nil }.count == AnchorAlertSchedule.repeatCount)
        // Re-check regression: every identifier is from the fixed set, so a new process
        // can cancel what an earlier one scheduled.
        let all = Set(AnchorAlertSchedule.allIDs)
        #expect((pending + later).allSatisfy { all.contains($0.id) })
        #expect(all.contains(AnchorAlertSchedule.nowID))
        // Silenced: the dead-man's switch waits for the silence to end.
        alarm.silence(at: 70)
        #expect(alarm.gpsLostDeadline == 185)
        alarm.clear()
        #expect(AnchorAlertSchedule.pending(for: alarm, now: 80).isEmpty)
    }

    @Test func aRestoredAlarmAlertsAtOnceThenRepeats() throws {
        // Review regression: an alarm restored after a relaunch has no previous alert in
        // this process, and must sound immediately.
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 41)
        for second in 1...15 {
            alarm.ingest(fix(t: Double(second), distance: 80, bearing: 0, random: &random))
        }
        let restored = try JSONDecoder().decode(AnchorAlarm.self, from: JSONEncoder().encode(alarm))
        #expect(AnchorAlertSchedule.isAlertDue(alarm: restored, lastAlert: nil, now: 1000))
        #expect(!AnchorAlertSchedule.isAlertDue(alarm: restored, lastAlert: 1000, now: 1020))
        #expect(AnchorAlertSchedule.isAlertDue(alarm: restored, lastAlert: 1000, now: 1030))
        #expect(!AnchorAlertSchedule.isAlertDue(alarm: armed(), lastAlert: nil, now: 1000))
    }
}
