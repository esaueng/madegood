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

    @Test func inconclusiveFixesNeitherCountNorReset() {
        // Radius 30 m, hacc 10 m: 35 m is inconclusive (35 − 10 < 30 but 35 > 30).
        var alarm = armed(radius: 30)
        var random = SeededRandom(state: 5)
        alarm.ingest(fix(t: 1, distance: 50, bearing: 0, hacc: 10, random: &random))
        alarm.ingest(fix(t: 2, distance: 50, bearing: 0, hacc: 10, random: &random))
        for second in 3...20 {
            alarm.ingest(fix(t: Double(second), distance: 35, bearing: 0, hacc: 10, random: &random))
        }
        #expect(alarm.state == .armed)
        // The earlier evidence still stands: one more clear fix confirms.
        alarm.ingest(fix(t: 21, distance: 50, bearing: 0, hacc: 10, random: &random))
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
        let point = try #require(AnchorAlarm.anchorPoint(from: fixes))
        let error = Geo.distance(lat1: point.latitude, lon1: point.longitude, lat2: origin.lat, lon2: origin.lon)
        #expect(error < 4)
        #expect(AnchorAlarm.anchorPoint(from: []) == nil)
        let single = try #require(AnchorAlarm.anchorPoint(from: [fixes[5]]))
        #expect(single.latitude == fixes[5].latitude && single.longitude == fixes[5].longitude)
    }
}
