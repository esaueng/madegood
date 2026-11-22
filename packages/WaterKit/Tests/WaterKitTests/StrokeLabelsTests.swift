import Foundation
import Testing

@testable import WaterKit

/// Stroke-by-stroke labels (fixtures/README.md): the truth they give, their checks, and the
/// labelling tool's draft, score and review page.
@Suite struct StrokeLabelsTests {
    static func strokes(from start: Double, every interval: Double, count: Int) -> [StrokeLabels.Stroke] {
        (0..<count).map { StrokeLabels.Stroke(t: start + Double($0) * interval) }
    }

    @Test func rateCountsOnlyIntervalsWithinBouts() throws {
        // Kayak at 60 spm (a stroke a second), a 10 s rest, then 40 spm.
        let fast = Self.strokes(from: 10, every: 1, count: 31)
        let slow = Self.strokes(from: 50, every: 1.5, count: 21)
        let labels = StrokeLabels(strokes: slow + fast)
        #expect(labels.count == 52)
        let rate = try #require(labels.strokeRate(sport: .kayak))
        // (30 + 20) intervals over (30 + 30) s.
        #expect(abs(rate - 50) < 1e-9)
        #expect(labels.strokes.map(\.t) == (fast + slow).map(\.t))
    }

    @Test func pausesSplitBoutsPerSport() throws {
        // 3 s between strokes is a pause for kayak (2 s per stroke) but paddling for canoe.
        let labels = StrokeLabels(strokes: Self.strokes(from: 0, every: 3, count: 10))
        #expect(labels.strokeRate(sport: .kayak) == nil)
        #expect(try #require(labels.strokeRate(sport: .canoe)) == 20)
        // Two strokes are not a bout.
        #expect(StrokeLabels(strokes: Self.strokes(from: 0, every: 1, count: 2)).strokeRate(sport: .kayak) == nil)
    }

    /// Review of #177: kayak blades 0.9 s and 2.1 s apart (a 3 s cycle, 40 spm) were split
    /// at every 2.1 s gap, every bout had two strokes, and the rate came out nil, which
    /// dropped the rate check. Bouts now split per wrist cycle.
    @Test func unevenKayakBladesStayOneBout() throws {
        var times: [Double] = [0]
        for index in 1..<41 { times.append(times[index - 1] + (index.isMultiple(of: 2) ? 2.1 : 0.9)) }
        let labels = StrokeLabels(strokes: times.map { StrokeLabels.Stroke(t: $0) })
        #expect(abs(try #require(labels.strokeRate(sport: .kayak)) - 40) < 1e-9)
        // A real stop still splits: 5 s after a stroke is more than a 4 s cycle.
        let stopped = StrokeLabels(strokes: (times + times.map { $0 + times.last! + 5 }).map { .init(t: $0) })
        #expect(abs(try #require(stopped.strokeRate(sport: .kayak)) - 40) < 1e-9)
    }

    /// Review of #177: excluded segments with no stroke times passed the check and scored
    /// nothing.
    @Test func excludedSegmentsNeedStrokeTimes() {
        let data = Data(
            #"{"v":1,"sport":"kayak","source":"motion-review","license":"CC-BY-4.0","truth":{"excluded":[{"start":0,"end":10}]}}"#
                .utf8)
        #expect(FixtureCheck.labelsProblems(data).contains { $0.contains("truth.excluded needs truth.strokeTimes") })
    }

    @Test func anExcludedSegmentEndsABout() throws {
        let strokes = Self.strokes(from: 0, every: 1, count: 6) + Self.strokes(from: 6.5, every: 1, count: 6)
        let joined = StrokeLabels(strokes: strokes)
        let split = StrokeLabels(strokes: strokes, excluded: [.init(start: 5.2, end: 6.3)])
        // The 1.5 s interval across the segment only counts without it.
        #expect(abs(try #require(joined.strokeRate(sport: .kayak)) - 60 * 11 / 11.5) < 1e-9)
        #expect(try #require(split.strokeRate(sport: .kayak)) == 60)
    }

    @Test func problemsCatchUnusableLabels() {
        let good = StrokeLabels(strokes: Self.strokes(from: 1, every: 1, count: 5), excluded: [.init(start: 7, end: 9)])
        #expect(good.problems(duration: 10) == [])
        let bad = StrokeLabels(
            strokes: [.init(t: -1), .init(t: 2), .init(t: 2.01), .init(t: 3, side: 2), .init(t: 8), .init(t: 50)],
            excluded: [.init(start: 7, end: 9), .init(start: 5, end: 4)])
        let problems = bad.problems(duration: 10)
        #expect(problems.contains { $0.contains("within the recording") })
        #expect(problems.contains { $0.contains("side") })
        #expect(problems.contains { $0.contains("within 0.05 s") })
        #expect(problems.contains { $0.contains("5.0–4.0") })
        #expect(problems.contains("1 strokes lie in excluded segments"))
    }

    @Test func statedTruthMustAgreeWithTheStrokeTimes() throws {
        let strokes = Self.strokes(from: 0, every: 1, count: 61)
        var file = FixtureLabelsFile(
            sport: .kayak, source: "motion-review", truth: .init(strokeTimes: strokes))
        #expect(try file.strokeTruth().strokes == 61)
        #expect(try file.strokeTruth().strokeRateSPM == 60)
        file.truth.strokes = 61
        file.truth.strokeRateSPM = 60.01
        #expect(try file.strokeTruth().strokes == 61)
        file.truth.strokes = 70
        #expect(throws: FixtureLabelsError.self) { try file.strokeTruth() }
        // Without stroke times the stated values stand.
        let counted = FixtureLabelsFile(sport: .kayak, source: "video", truth: .init(strokes: 812, strokeRateSPM: 54.5))
        #expect(try counted.strokeTruth().strokes == 812)
        #expect(try counted.strokeTruth().strokeRateSPM == 54.5)
    }

    @Test func schemaAcceptsStrokeTimesAndRejectsDraftsAndRealDates() {
        func problems(_ text: String) -> [String] { FixtureCheck.labelsProblems(Data(text.utf8)) }
        let good =
            #"{"v":1,"sport":"kayak","source":"motion-review","description":"Flat water.","license":"CC-BY-4.0","truth":{"strokeTimes":[{"t":1.25},{"t":2.5,"side":0}],"excluded":[{"start":10,"end":20.5}]}}"#
        #expect(problems(good) == [])
        #expect(
            problems(good.replacingOccurrences(of: "motion-review", with: "draft")).contains {
                $0.contains("source must be one of")
            })
        // A Unix time would date the session.
        #expect(
            problems(good.replacingOccurrences(of: #""t":1.25"#, with: #""t":1809165600.5"#)).contains {
                $0.contains("truth.strokeTimes")
            })
        #expect(
            problems(good.replacingOccurrences(of: #""end":20.5"#, with: #""end":1809165600"#)).contains {
                $0.contains("truth.excluded")
            })
        #expect(
            problems(good.replacingOccurrences(of: #""side":0"#, with: #""side":0,"lat":47.6"#)).contains {
                $0.contains("truth.strokeTimes")
            })
        #expect(
            problems(good.replacingOccurrences(of: #""start":10"#, with: #""start":30"#)).contains {
                $0.contains("start < end")
            })
        let maneuver = #"{"v":1,"truth":{"maneuvers":[{"t":1809165600,"type":"tack"}]}}"#
        #expect(problems(maneuver).contains { $0.contains("truth.maneuvers") })
    }

    // MARK: Draft, score and review page

    /// 120 s of kayak paddling at 60 spm with steady GPS, and the strokes it was made with.
    static func paddle() -> (RawSession, [StrokeLabels.Stroke]) {
        let (session, _) = FixtureAccuracyPathTests.session { _ in 2 }
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [.init(duration: 120, strokeRate: 60)])
        simulator.seed = 59
        let cycles = simulator.generate().cycleTimes
        var strokes: [StrokeLabels.Stroke] = []
        for (index, t) in cycles.enumerated() {
            strokes.append(.init(t: t))
            let next = index + 1 < cycles.count ? cycles[index + 1] : t + 2
            strokes.append(.init(t: (t + next) / 2))
        }
        return (session, strokes)
    }

    @Test func scoreComparesSessionDetailWithTheLabels() throws {
        let (session, strokes) = Self.paddle()
        let score = try StrokeScore(labels: StrokeLabels(strokes: strokes), session: session)
        #expect(score.truthCount == strokes.count)
        #expect(score.countPasses, "\(score)")
        #expect(score.ratePasses, "\(score)")
        #expect(score.matched + score.missed == score.truthCount)
        #expect(score.matched + score.extra == score.appCount)

        // Five per cent more labelled strokes than the app found fails the count.
        let extra = (0..<(strokes.count / 20)).map { StrokeLabels.Stroke(t: 0.05 + Double($0) * 0.001) }
        let more = try StrokeScore(labels: StrokeLabels(strokes: strokes + extra), session: session)
        #expect(!more.countPasses)
    }

    @Test func draftIsTheDetectorsCandidatesAndNeverPassesAsTruth() throws {
        let (session, strokes) = Self.paddle()
        let review = try StrokeReview(session: session)
        let detected = StrokeAnalysis.detect(session: session).strokes
        #expect(review.candidates.map(\.t) == detected.map(\.t))
        #expect(review.candidates.allSatisfy { $0.counted })
        #expect(abs(review.candidates.count - strokes.count) <= 4)
        let draft = FixtureLabelsFile.draft(sport: .kayak, labels: review.draft)
        #expect(draft.source == FixtureLabelsFile.draftSource)
        let encoded = try draft.encoded()
        #expect(FixtureCheck.labelsProblems(encoded).contains { $0.contains("source must be one of") })
        #expect(throws: FixtureLabelsError.self) { try FixtureLabels.export(encoded, for: session) }
    }

    @Test func reviewSignalPeaksOnTheDetectorsCycles() throws {
        let (session, _) = Self.paddle()
        let detection = StrokeAnalysis.detect(session: session)
        let signal = StrokeReviewSignal(motion: session.motion, cycleTimes: detection.cycles.map(\.t))
        let span = (session.motion.last?.t ?? 0) - (session.motion.first?.t ?? 0)
        #expect(
            abs(Double(signal.count) - span / StrokeReviewSignal.interval) <= 2, "\(signal.count) bins over \(span) s")
        #expect(signal.main.allSatisfy { $0.isFinite })
        // At each cycle after the first seconds, the signal is near its local maximum.
        var nearPeak = 0
        let cycles = detection.cycles.filter { $0.t > 5 }
        for cycle in cycles {
            let index = Int(((cycle.t - signal.start) / StrokeReviewSignal.interval).rounded())
            let around = signal.main[max(0, index - 12)...min(signal.count - 1, index + 12)]
            if signal.main[index] >= 0.8 * (around.max() ?? 0) { nearPeak += 1 }
        }
        #expect(Double(nearPeak) >= 0.9 * Double(cycles.count), "\(nearPeak) of \(cycles.count)")
    }

    @Test func reviewSignalBreaksAtLongGaps() {
        var simulator = PaddleMotionSimulator(sport: .kayak, segments: [.init(duration: 30, strokeRate: 60)])
        simulator.seed = 3
        let samples = simulator.generate().samples
        let motion = samples.filter { $0.t < 10 || $0.t > 12 }
        let signal = StrokeReviewSignal(motion: motion)
        let gap = Int(((11 - signal.start) / StrokeReviewSignal.interval).rounded())
        #expect(signal.main[gap].isNaN)
        #expect(signal.rotation[0][gap].isNaN)
        #expect(signal.main[gap + 50].isFinite)
    }

    @Test func reviewPageIsSelfContainedAndCarriesNoDatesOrPlaces() throws {
        let (session, _) = Self.paddle()
        let review = try StrokeReview(session: session)
        let draft = FixtureLabelsFile.draft(sport: .kayak, labels: review.draft)
        let html = try StrokeReviewPage.html(review: review, labels: draft, reviewKey: "test")
        // Nothing loads from elsewhere.
        for pattern in ["http://", "https://", "src=", "@import", "url("] {
            #expect(!html.contains(pattern), "\(pattern)")
        }
        #expect(html.contains("default-src 'none'"))
        let marker = #"<script type="application/json" id="review-data">"#
        let start = try #require(html.range(of: marker)).upperBound
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        let json = String(html[start..<end]).replacingOccurrences(of: "<\\/", with: "</")
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            Issue.record("the page data is not a JSON object")
            return
        }
        #expect(
            Set(object.keys) == [
                "sport", "strokesPerCycle", "duration", "signalStart", "signalInterval", "channels", "speedT", "speedV",
                "candidates", "notCounted", "labels", "reviewKey",
            ])
        guard case .array(let candidates)? = object["candidates"] else {
            Issue.record("no candidates")
            return
        }
        #expect(candidates.count == review.candidates.count)
        // The recording's start (Unix time), position and ID are not in the page.
        let startDigits = String(Int(session.meta.startedAt))
        #expect(!html.contains(startDigits))
        #expect(!html.contains(session.meta.sessionId.uuidString.lowercased()))
        #expect(!html.contains(session.meta.sessionId.uuidString))
        #expect(!html.contains("\"lat\"") && !html.contains("\"lon\""))
        // Int16 channels decode back to the signal within their quantization step.
        let channel = StrokeReviewPage.encode([0.5, -1, .nan, 2])
        let bytes = try #require(Data(base64Encoded: channel.data))
        let values = stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
        #expect(values[2] == .min)
        #expect(abs(Double(values[0]) * channel.scale - 0.5) <= channel.scale)
        #expect(abs(Double(values[3]) * channel.scale - 2) <= channel.scale)
    }
}
