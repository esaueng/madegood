import Testing

@testable import WaterKit

@Suite struct PaddlingStrokeIntervalTests {
    @Test(arguments: [200, 201])
    func fullIntervalsClipStepsAndOnlyReportNonemptyRemainders(strokeCount: Int) throws {
        let session = session(sport: .kayak, seconds: Array(0...210))
        let selection = try SessionSelection(session: session)
        let times = (0..<strokeCount).map { Double($0) + 0.25 }
        // The session clock can jump backwards when motion is mapped from sensor time.
        let analysis = StrokeAnalysis(
            detection: detection(times.reversed()), sport: .kayak, selection: selection)
        let intervals = analysis.strokeIntervals

        #expect(intervals.map(\.index) == (strokeCount == 200 ? [1, 2] : [1, 2, 3]))
        #expect(intervals.map(\.strokeCount) == (strokeCount == 200 ? [100, 100] : [100, 100, 1]))
        #expect(intervals.map(\.isComplete) == (strokeCount == 200 ? [true, true] : [true, true, false]))
        let expectedBounds =
            strokeCount == 200 ? [0...99.25, 99.25...199.25] : [0...99.25, 99.25...199.25, 199.25...200.25]
        #expect(intervals.map(\.elapsedRange) == expectedBounds)
        for interval in intervals {
            #expect(interval.movingRanges == [interval.elapsedRange])
            #expect(interval.movingTime == interval.elapsedRange.upperBound - interval.elapsedRange.lowerBound)
            #expect(abs(interval.distance - 2 * interval.movingTime) < 1e-6)
            let speed = try #require(interval.averageSpeed)
            #expect(abs(speed - 2) < 1e-6)
        }
    }

    @Test func trimRebasesBoundsAndCutsPausesAndGPSOutagesBreakMovingRanges() throws {
        let session = session(
            sport: .canoe, seconds: Array(0...12) + Array(19...50),
            events: [SessionEvent(t: 28.5, type: .pause), SessionEvent(t: 32.5, type: .resume)])
        let trim = try SessionTrim(start: 10, end: 45, removing: [20...22])
        let selection = try SessionSelection(session: session, trim: trim)
        let analysis = StrokeAnalysis(
            detection: detection([9, 10, 18, 20, 21, 22, 28, 40, 46]), sport: .canoe, selection: selection)

        #expect(analysis.strokes.map(\.t) == [0, 8, 10, 12, 18, 30])
        #expect(analysis.strokeIntervals.count == 1)
        let interval = try #require(analysis.strokeIntervals.first)
        #expect(interval.index == 1)
        #expect(interval.strokeCount == 6)
        #expect(!interval.isComplete)
        #expect(interval.elapsedRange == 0...30)
        #expect(interval.movingRanges == [0...2, 9...10, 12...18, 23...30])
        #expect(interval.movingTime == 16)
        #expect(abs(interval.distance - 32) < 1e-6)
    }

    @Test func rawMotionSuppliesIntervalsWithoutGPSAndUsesStrokePauseRules() throws {
        let motion = PaddleMotionSimulator(sport: .sup, segments: [.init(duration: 150, strokeRate: 60)]).generate()
        let session = session(
            sport: .sup, seconds: [], motion: motion.samples,
            events: [
                SessionEvent(t: 20, type: .pause), SessionEvent(t: 30, type: .resume),
                SessionEvent(t: 40, type: .pause, data: ["auto": true]),
                SessionEvent(t: 50, type: .resume, data: ["auto": true]), SessionEvent(t: 150, type: .stop),
            ])
        let selection = try SessionSelection(session: session)
        let analysis = StrokeAnalysis(session: session, selection: selection)

        #expect(analysis.strokes.allSatisfy { !(20..<30).contains($0.t) })
        #expect(analysis.strokes.contains { (40..<50).contains($0.t) })
        #expect(analysis.strokeIntervals.map(\.isComplete) == [true, false])
        #expect(analysis.strokeIntervals.reduce(0) { $0 + $1.strokeCount } == analysis.strokeCount)
        let boundaryStroke = try #require(analysis.strokes.dropFirst(99).first)
        #expect(analysis.strokeIntervals.first?.elapsedRange.upperBound == boundaryStroke.t)
        #expect(analysis.strokeIntervals.last?.elapsedRange.upperBound == analysis.strokes.last?.t)
        for interval in analysis.strokeIntervals {
            #expect(interval.movingRanges.isEmpty)
            #expect(interval.movingTime == 0)
            #expect(interval.distance == 0)
            #expect(interval.averageSpeed == nil)
        }
        let empty = StrokeAnalysis(detection: detection([]), sport: .sup, selection: selection)
        #expect(empty.strokeIntervals.isEmpty)
    }

    private func detection(_ times: [Double]) -> StrokeAnalysis.Detection {
        .init(cycles: [], strokes: times.map { .init(t: $0, side: nil) })
    }

    private func session(
        sport: Sport, seconds: [Int], motion: [MotionSample] = [], events: [SessionEvent] = []
    ) -> RawSession {
        var meta = RawSessionReaderTests.meta(endedAt: nil)
        meta.sport = sport
        let fixes = seconds.map { second in
            let position = Geo.destination(lat: 0, lon: 0, bearing: 90, distance: Double(second) * 2)
            return GPSFix(
                t: Double(second), latitude: position.lat, longitude: position.lon, horizontalAccuracy: 5, speed: 2)
        }
        return RawSession(meta: meta, gps: fixes, motion: motion, events: events)
    }
}
