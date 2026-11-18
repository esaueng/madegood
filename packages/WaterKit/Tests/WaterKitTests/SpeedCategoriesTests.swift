import Foundation
import Testing

@testable import WaterKit

/// 1 Hz fixes along a line through (0, 0) heading east, with Doppler speed `speed(t)`.
/// `position(t)` is the signed distance east, m, so out-and-back runs are easy to build.
private func fixes(
    _ range: ClosedRange<Int>, speed: (Double) -> Double, position: ((Double) -> Double)? = nil,
    originLongitude: Double = 0
) -> [GPSFix] {
    var along = 0.0
    var previous: (t: Double, v: Double)?
    return range.map { second in
        let t = Double(second)
        let v = speed(t)
        if let previous { along += (previous.v + v) / 2 * (t - previous.t) }
        previous = (t, v)
        let x = position?(t) ?? along
        let point = Geo.destination(lat: 0, lon: originLongitude, bearing: x >= 0 ? 90 : 270, distance: abs(x))
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

    @Test func fiveByTenFindsFiveWindowsWhenTheFastestBlocksGreedy() {
        // Review regression: a bump centred at 10 s makes 5–15 s the fastest window, and a
        // greedy pick then leaves room for only three more in 0–50 s. Exactly five
        // windows fit, back to back, so they are the answer.
        let c = SpeedCategories.analyze(fixes(0...50, speed: { 3 + 4 * max(0, 1 - abs($0 - 10) / 5) }))
        #expect(c.best5x10sRanges == [0...10, 10...20, 20...30, 30...40, 40...50])
        // Mean over 0–50 s: 3 m/s plus the bump's 20 m (a triangle 10 s wide, 4 m/s high).
        #expect(close(c.best5x10s, (150 + 20) / 50.0))
    }

    @Test func fiveByTenMaximisesTheTotalOverAPlateau() {
        // 10 m/s for t in 100...145, 2 m/s otherwise, with one-second ramps. The best five
        // windows tile 50 s covering the plateau: 450 m on it plus 18 m at the edges.
        let c = SpeedCategories.analyze(fixes(0...200, speed: { (100...145).contains($0) ? 10 : 2 }))
        #expect(close(c.best5x10s, 468.0 / 50))
        let ranges = c.best5x10sRanges
        #expect(ranges.count == 5)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect((ranges.first?.lowerBound ?? 0) <= 100 && (ranges.last?.upperBound ?? 0) >= 145)
    }

    @Test func alphaInterpolatesAcrossTheAntimeridian() {
        // Review regression: out and back at 12 m/s, so 500 m takes 41.67 s and alpha starts
        // fall between fixes. The earliest qualifying start is 7.33 s, 88 m out, between
        // fixes at 84 m and 96 m. The antimeridian is put at 90 m, between those two.
        let origin = 180 - 90 / (Geo.earthRadius * .pi / 180)
        let route = fixes(
            0...60, speed: { _ in 12 }, position: { $0 <= 30 ? 12 * $0 : 720 - 12 * $0 }, originLongitude: origin)
        let c = SpeedCategories.analyze(route)
        #expect(close(c.alpha500?.range, (49 - 500 / 12.0)...49, 1e-6))
        #expect(close(c.alpha500?.speed, 12))
    }

    @Test func alphaDoesNotSpanAnAnchorWithoutSpeed() {
        // Review regression: 10 m/s out and back, five rejected fixes at 20–24 s, then a
        // re-anchor at 25 s that has no Doppler speed. Alpha may not start before it.
        var route = fixes(0...60, speed: { _ in 10 }, position: { $0 <= 30 ? 10 * $0 : 600 - 10 * $0 })
        for i in 20...24 { route[i].horizontalAccuracy = 80 }
        route[25].speed = nil
        let replay = SessionReplay(
            track: Track(sessionId: UUID(), sport: .windsurfing, startedAt: Date(timeIntervalSince1970: 0), gps: route))
        #expect(replay.metrics.rejectedFixes == 5)
        #expect(replay.metrics.speedCategories?.alpha500 == nil)
        #expect(close(replay.metrics.speedCategories?.best500m?.speed, 10))
    }

    @Test func alphaMayStartAtASpeedlessAnchor() {
        // Re-check regression: 10 m/s out and back, fixes rejected at 5–9 s, a re-anchor at
        // 10 s without Doppler. Bracketing Doppler gives 500 m from 10 s to 60 s, and the
        // route is back at the anchor's position at 60 s, so 10–60 s is an alpha.
        var route = fixes(0...60, speed: { _ in 10 }, position: { $0 <= 35 ? 10 * $0 : 700 - 10 * $0 })
        for i in 5...9 { route[i].horizontalAccuracy = 80 }
        route[10].speed = nil
        let replay = SessionReplay(
            track: Track(sessionId: UUID(), sport: .windsurfing, startedAt: Date(timeIntervalSince1970: 0), gps: route))
        #expect(replay.metrics.rejectedFixes == 5)
        #expect(close(replay.metrics.speedCategories?.alpha500?.range, 10...60))
        #expect(close(replay.metrics.speedCategories?.alpha500?.speed, 10))
    }

    @Test func fiveByTenToleratesRoundingAtTouchingWindows() {
        // Re-check regression: fixes at 0, 1.001, 2.001, … 50.001 s. The window ending at
        // 40.001 starts at 30.001 less a rounding error; it still only touches the one
        // ending at 30.001.
        let route = fixes(0...50, speed: { _ in 5 }).map { fix in
            var fix = fix
            if fix.t > 0 { fix.t += 0.001 }
            return fix
        }
        let c = SpeedCategories.analyze(route)
        #expect(close(c.best5x10s, 5))
        #expect(c.best5x10sRanges.count == 5)
    }

    @Test func alphaDoesNotSpanAPositionAnchor() {
        let route = fixes(0...60, speed: { _ in 10 }, position: { $0 <= 30 ? 10 * $0 : 600 - 10 * $0 })
        var tracker = SpeedCategoryTracker()
        for fix in route {
            tracker.ingest(
                t: fix.t, speed: fix.speed ?? 0, latitude: fix.latitude, longitude: fix.longitude, isAnchor: fix.t == 20
            )
        }
        #expect(tracker.categories.alpha500 == nil)
        #expect(close(tracker.categories.best500m?.speed, 10))
    }

    @Test func spansDoNotCrossLongGapsOrBreaks() {
        // Two 300 m runs at 5 m/s. An 11 s gap splits them; a 10 s gap does not.
        let first = fixes(0...60, speed: { _ in 5 })
        let split =
            first
            + fixes(0...60, speed: { _ in 5 }).map { fix in
                var fix = fix
                fix.t += 71
                return fix
            }
        #expect(SpeedCategories.analyze(split).best500m == nil)
        #expect(close(SpeedCategories.analyze(split).best100m?.speed, 5))
        let joined =
            first
            + fixes(0...60, speed: { _ in 5 }).map { fix in
                var fix = fix
                fix.t += 70
                return fix
            }
        #expect(close(SpeedCategories.analyze(joined).best500m?.speed, 5))

        var tracker = SpeedCategoryTracker()
        for (index, fix)
            in (first
            + first.map {
                var f = $0; f.t += 61; return f
            }).enumerated()
        {
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
        #expect(close(stats.speedCategories?["best5x10s"], 9.36))
        #expect(stats.speedCategories?["best1h"] == nil)
        #expect(stats.textReport().contains("5 × 10 s"))
        track.sport = .kayak
        #expect(SessionStats(track: track).speedCategories == nil)
    }

    @Test func statsUseTheEnginesFilteredFixes() {
        // Review regression: Doppler above the filter's 50 m/s limit is rejected live and
        // in session detail, so the CLI must not report it as a best either.
        let route = fixes(0...200, speed: { _ in 60 })
        let track = Track(sessionId: UUID(), sport: .windsurfing, startedAt: Date(timeIntervalSince1970: 0), gps: route)
        let stats = SessionStats(track: track)
        let replay = SessionReplay(track: track)
        #expect(stats.speedCategories == replay.metrics.speedCategories?.summaryFields)
        #expect((stats.speedCategories?.values.max() ?? 0) <= GPSFilter.Config().maxSpeed)
    }

    @Test func statsMaxSpeedsUseTheEnginesFilteredFixes() {
        // Re-check regression: accurate fixes reporting 60 m/s are all rejected by the GPS
        // filter, so the CLI shows no max or average speed, like live and session detail.
        let track = Track(
            sessionId: UUID(), sport: .kayak, startedAt: Date(timeIntervalSince1970: 0),
            gps: fixes(0...200, speed: { _ in 60 }))
        let stats = SessionStats(track: track)
        let replay = SessionReplay(track: track)
        #expect(stats.maxSpeed2s == replay.metrics.maxSpeed2s)
        #expect(stats.maxSpeed10s == replay.metrics.maxSpeed10s)
        #expect((stats.maxSpeed2s ?? 0) <= GPSFilter.Config().maxSpeed)
        #expect((stats.maxSpeed10s ?? 0) <= GPSFilter.Config().maxSpeed)
        #expect((stats.averageSpeed ?? 0) <= GPSFilter.Config().maxSpeed)
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
