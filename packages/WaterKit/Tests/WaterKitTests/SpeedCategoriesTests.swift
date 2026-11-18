import Foundation
import Testing

@testable import WaterKit

/// 1 Hz fixes along a line through (0, 0) heading east, with Doppler speed `speed(t)`.
/// `position(t)` is the signed distance east, m, so out-and-back runs are easy to build.
private func fixes(
    _ range: ClosedRange<Int>, speed: (Double) -> Double, position: ((Double) -> Double)? = nil
) -> [GPSFix] {
    var along = 0.0
    var previous: (t: Double, v: Double)?
    return range.map { second in
        let t = Double(second)
        let v = speed(t)
        if let previous { along += (previous.v + v) / 2 * (t - previous.t) }
        previous = (t, v)
        let x = position?(t) ?? along
        let point = Geo.destination(lat: 0, lon: 0, bearing: x >= 0 ? 90 : 270, distance: abs(x))
        return GPSFix(t: t, latitude: point.lat, longitude: point.lon, horizontalAccuracy: 5, speed: v, course: 90)
    }
}

private func close(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

private func close(_ a: ClosedRange<Double>?, _ b: ClosedRange<Double>, _ tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a.lowerBound - b.lowerBound) <= tolerance && abs(a.upperBound - b.upperBound) <= tolerance
}

@Suite struct SpeedCategoriesTests {
    @Test func steadySpeedFillsEveryCategoryExceptAlpha() {
        // Long enough for the 1 h window and for the tracker to drop old fixes.
        let c = SpeedCategories.analyze(fixes(0...6000, speed: { _ in 5 }))
        #expect(close(c.peak2s?.speed, 5))
        #expect(close(c.best10s?.speed, 5))
        #expect(close(c.best5x10s, 5))
        #expect(c.best5x10sRanges == [0...10, 10...20, 20...30, 30...40, 40...50])
        #expect(close(c.best100m?.speed, 5))
        #expect(close(c.best100m?.range, 0...20))
        #expect(close(c.best500m?.speed, 5))
        #expect(close(c.nauticalMile?.speed, 5))
        #expect(close(c.nauticalMile?.range, 0.6...371))
        #expect(close(c.hour?.speed, 5))
        #expect(close(c.hour?.range, 0...3600))
        // A straight line never comes back within 50 m.
        #expect(c.alpha500 == nil)
    }

    @Test func distanceStartIsInterpolatedWhileAccelerating() {
        // v = t, so distance is t²/2: 200 m by t = 20. The fastest 100 m ends at 20 s and
        // starts where t²/2 = 100, at √200 s, between fixes.
        let c = SpeedCategories.analyze(fixes(0...20, speed: { $0 }))
        let start = 200.0.squareRoot()
        #expect(close(c.best100m?.range, start...20))
        #expect(close(c.best100m?.speed, 100 / (20 - start)))
        #expect(c.best500m == nil)
        #expect(c.nauticalMile == nil)
        // Mean of v = t over [10, 20].
        #expect(close(c.best10s?.speed, 15))
        #expect(close(c.peak2s?.speed, 19))
        #expect(c.hour == nil)
        #expect(c.best5x10s == nil)
    }

    @Test func nauticalMileSpansASpeedChange() {
        // 4 m/s to t = 1000, 8 m/s from t = 1001 to 1101. Back from 1101: 800 m to 1001,
        // 6 m over the change, then 1046 m at 4 m/s, which starts at 738.5 s. The first
        // 500 m wholly at 8 m/s (62.5 s) ending at a fix is 1001.5–1064.
        let c = SpeedCategories.analyze(fixes(0...1101, speed: { $0 <= 1000 ? 4 : 8 }))
        #expect(close(c.nauticalMile?.range, 738.5...1101))
        #expect(close(c.nauticalMile?.speed, 1852 / 362.5))
        #expect(close(c.best500m?.speed, 8))
        #expect(close(c.best500m?.range, 1001.5...1064))
    }

    @Test func fiveByTenPicksNonOverlappingWindowsBestFirst() {
        // 10 m/s for t in 100...145, 2 m/s otherwise. Four windows at 10 m/s fit back to
        // back (100–140); every other fast window overlaps them. The best remaining one is
        // 140–150: 5 s at 10, the 145–146 change (6 m), 4 s at 2 = 64 m.
        let c = SpeedCategories.analyze(fixes(0...200, speed: { (100...145).contains($0) ? 10 : 2 }))
        #expect(c.best5x10sRanges == [100...110, 110...120, 120...130, 130...140, 140...150])
        #expect(close(c.best5x10s, (4 * 10 + 6.4) / 5))
        #expect(close(c.best10s?.speed, 10))
    }

    @Test func alphaNeedsTheEndNearTheStart() {
        // 10 m/s out east for 30 s, then straight back. A 500 m run takes 50 s; starting at
        // a it ends |20a − 100| m from its start, within 50 m for a in 2.5...7.5. Spans end
        // at fixes, so the earliest is 3–53.
        let route = fixes(0...60, speed: { _ in 10 }, position: { $0 <= 30 ? 10 * $0 : 600 - 10 * $0 })
        let c = SpeedCategories.analyze(route)
        #expect(close(c.alpha500?.speed, 10))
        #expect(close(c.alpha500?.range, 3...53))
        #expect(close(c.best500m?.speed, 10))
    }

    @Test func alphaDoesNotSpanAPositionAnchor() {
        let route = fixes(0...60, speed: { _ in 10 }, position: { $0 <= 30 ? 10 * $0 : 600 - 10 * $0 })
        var tracker = SpeedCategoryTracker()
        for fix in route {
            tracker.ingest(
                t: fix.t, speed: fix.speed ?? 0, latitude: fix.latitude, longitude: fix.longitude, isAnchor: fix.t == 20)
        }
        #expect(tracker.categories.alpha500 == nil)
        #expect(close(tracker.categories.best500m?.speed, 10))
    }

    @Test func spansDoNotCrossLongGapsOrBreaks() {
        // Two 300 m runs at 5 m/s. An 11 s gap splits them; a 10 s gap does not.
        let first = fixes(0...60, speed: { _ in 5 })
        let split = first + fixes(0...60, speed: { _ in 5 }).map { fix in
            var fix = fix
            fix.t += 71
            return fix
        }
        #expect(SpeedCategories.analyze(split).best500m == nil)
        #expect(close(SpeedCategories.analyze(split).best100m?.speed, 5))
        let joined = first + fixes(0...60, speed: { _ in 5 }).map { fix in
            var fix = fix
            fix.t += 70
            return fix
        }
        #expect(close(SpeedCategories.analyze(joined).best500m?.speed, 5))

        var tracker = SpeedCategoryTracker()
        for (index, fix) in (first + first.map { var f = $0; f.t += 61; return f }).enumerated() {
            if index == first.count { tracker.breakRun() }
            tracker.ingest(t: fix.t, speed: fix.speed ?? 0, latitude: fix.latitude, longitude: fix.longitude)
        }
        #expect(tracker.categories.best500m == nil)
    }

    @Test func ignoresUnusableFixes() {
        var route = fixes(0...30, speed: { _ in 5 })
        route[10].speed = nil
        route[11].speed = -1
        route[12].speed = .nan
        let c = SpeedCategories.analyze(route.reversed())
        // Fixes 9 and 13 are 4 s apart, inside the gap limit; speed stays 5 throughout.
        #expect(close(c.best100m?.speed, 5))
        #expect(close(c.best10s?.speed, 5))
    }

    @Test func liveEngineMatchesPostAnalysisAndMaxSpeeds() {
        let speed: (Double) -> Double = { t in 3 + 6 * max(0, sin(t / 40)) + 0.5 * sin(t / 3) }
        let route = fixes(0...1500, speed: speed, position: { 150 * sin($0 / 60) })
        let track = Track(
            sessionId: UUID(), sport: .windsurfing, startedAt: Date(timeIntervalSince1970: 0), gps: route)
        let replay = SessionReplay(track: track)
        guard let live = replay.metrics.speedCategories else {
            Issue.record("windsurfing replay has no speed categories")
            return
        }
        #expect(live == SpeedCategories.analyze(route))
        #expect(live.peak2s?.speed == replay.metrics.maxSpeed2s)
        #expect(live.best10s?.speed == replay.metrics.maxSpeed10s)
        #expect(live.best10s?.range == replay.metrics.maxSpeed10sRange)
        #expect(live.alpha500 != nil)
        #expect(live.best5x10s != nil)
        #expect((live.best5x10s ?? .infinity) <= (live.best10s?.speed ?? 0))
        #expect((live.best500m?.speed ?? 0) >= (live.alpha500?.speed ?? .infinity))

        guard case .object(let summary) = replay.summary else {
            Issue.record("summary is not an object")
            return
        }
        #expect(summary["best5x10s"] == live.best5x10s.map(JSONValue.number))
        #expect(summary["best500m"] == live.best500m.map { .number($0.speed) })
        #expect(summary["alpha500"] == live.alpha500.map { .number($0.speed) })
        #expect(summary["best1h"] == nil)
    }

    @Test func statsReportCategoriesForWindsurfingOnly() {
        let route = fixes(0...200, speed: { (100...145).contains($0) ? 10 : 2 })
        var track = Track(sessionId: UUID(), sport: .windsurfing, startedAt: Date(timeIntervalSince1970: 0), gps: route)
        let stats = SessionStats(track: track)
        #expect(stats.speedCategories == SpeedCategories.analyze(route).summaryFields)
        #expect(close(stats.speedCategories?["best5x10s"], 9.28))
        #expect(stats.speedCategories?["best1h"] == nil)
        #expect(stats.textReport().contains("5 × 10 s"))
        track.sport = .kayak
        #expect(SessionStats(track: track).speedCategories == nil)
    }

    @Test func otherSportsDoNotTrackCategories() {
        let track = Track(
            sessionId: UUID(), sport: .sailing, startedAt: Date(timeIntervalSince1970: 0),
            gps: fixes(0...100, speed: { _ in 5 }))
        let replay = SessionReplay(track: track)
        #expect(replay.metrics.speedCategories == nil)
        guard case .object(let summary) = replay.summary else { return }
        #expect(summary["best500m"] == nil)
    }
}
