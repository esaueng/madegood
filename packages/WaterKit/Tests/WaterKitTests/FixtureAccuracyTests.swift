import Foundation
import Testing

@testable import WaterKit

@Suite struct FixtureAccuracyTests {
    typealias Labels = FixtureLabelsFile

    /// A labelled fixture folder in `fixtures/` or the fetched corpus (`fixtures/.corpus/`).
    struct Fixture: Sendable, CustomTestStringConvertible {
        var folder: URL
        var sport: Sport
        /// The folder relative to the repository.
        var context: String
        var testDescription: String { context }
    }

    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Folders with a labels.json whose truth has stroke labels (`strokes`, `strokeRateSPM`
    /// or `strokeTimes`), or the others. Unreadable labels count as others, whose test
    /// reports them.
    static func fixtures(strokes: Bool) -> [Fixture] {
        let fixtures = repository.appendingPathComponent("fixtures")
        let fm = FileManager.default
        var found: [Fixture] = []
        for root in [fixtures, fixtures.appendingPathComponent(".corpus")] {
            for sport in Sport.allCases {
                let sportFolder = root.appendingPathComponent(sport.rawValue)
                let folders = (try? fm.contentsOfDirectory(at: sportFolder, includingPropertiesForKeys: nil)) ?? []
                for folder in folders.sorted(by: { $0.path < $1.path }) {
                    let file = folder.appendingPathComponent("labels.json")
                    guard fm.fileExists(atPath: file.path) else { continue }
                    var hasStrokes = false
                    if let data = try? Data(contentsOf: file),
                        case .object(let labels)? = try? JSONDecoder().decode(JSONValue.self, from: data),
                        case .object(let truth)? = labels["truth"]
                    {
                        hasStrokes = !Set(truth.keys).isDisjoint(with: ["strokes", "strokeRateSPM", "strokeTimes"])
                    }
                    guard hasStrokes == strokes else { continue }
                    let context = folder.path.replacingOccurrences(of: repository.path + "/", with: "")
                    found.append(Fixture(folder: folder, sport: sport, context: context))
                }
            }
        }
        return found
    }

    /// Every recording with stroke labels. None exists yet; see fixtures/README.md, "How to
    /// label a session".
    static let paddlingFixtures = fixtures(strokes: true)

    @Test func labeledRecordingsMeetPlanThresholds() throws {
        for fixture in Self.fixtures(strokes: false) {
            do {
                try Self.score(fixture)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Issue.record("\(fixture.context): \(error)")
            }
        }
    }

    /// PLAN §5 stroke count (±3 %) and rate (±2 SPM) on each labelled paddling recording,
    /// scored on session detail's path. Skipped until the first one is added.
    @Test(
        .enabled(
            if: !FixtureAccuracyTests.paddlingFixtures.isEmpty,
            "No labelled paddling fixture yet (fixtures/README.md, \"How to label a session\")"),
        arguments: FixtureAccuracyTests.paddlingFixtures)
    func labeledPaddlingRecordingsMeetStrokeThresholds(_ fixture: Fixture) throws {
        try Self.score(fixture)
    }

    static func score(_ fixture: Fixture) throws {
        let context = fixture.context
        let file = fixture.folder.appendingPathComponent("labels.json")
        let problems = FixtureCheck.labelsProblems(file)
        try #require(problems.isEmpty, "\(context): \(problems)")
        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: file))
        try #require(labels.v == 1, "\(context): unsupported labels version")
        // Stroke-by-stroke labels give the count and rate (fixtures/README.md).
        var truth = labels.truth
        let strokes = try labels.strokeTruth()
        truth.strokes = strokes.strokes
        truth.strokeRateSPM = strokes.strokeRateSPM
        let session = try loadRecording(fixture.folder, truth: truth)
        try #require(labels.sport == fixture.sport && labels.sport == session.meta.sport, "\(context): sport mismatch")
        try #require(session.issues.isEmpty, "\(context): \(session.issues)")
        if let strokeLabels = labels.strokeLabels {
            let problems = strokeLabels.problems(duration: max(session.duration, session.motion.last?.t ?? 0))
            try #require(problems.isEmpty, "\(context): \(problems)")
        }
        try check(truth, session: session, context: context)
        // The thresholds must also hold after writing the recording with the
        // current writer (rounded values) and reading it back.
        if let rewritten = try rewritten(fixture.folder, session, truth: truth) {
            try check(truth, session: rewritten, context: context + " (rewritten)")
        }
    }

    /// A raw recording written by `RawSessionWriter` and read back; nil for a track fixture.
    private static func rewritten(_ folder: URL, _ session: RawSession, truth: Labels.Truth) throws -> RawSession? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path) else {
            return nil
        }
        let needsMotion = truth.strokes != nil || truth.strokeRateSPM != nil
        let temp = try TempFolder()
        try RawSessionWriter.write(session, to: temp.url)
        return try RawSessionReader.read(folder: temp.url, includeMotion: needsMotion)
    }

    private static func loadRecording(_ folder: URL, truth: Labels.Truth) throws -> RawSession {
        let needsMotion = truth.strokes != nil || truth.strokeRateSPM != nil
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path) {
            return try RawSessionReader.read(folder: folder, includeMotion: needsMotion)
        }
        let track = try TrackCodec.decode(Data(contentsOf: folder.appendingPathComponent("track.json.gz")))
        // Adapt the recorded streams to the post-session analyzer. The stored track
        // summary and maneuver events are not used to score the detector.
        let meta = RawFormat.Meta(
            sessionId: track.sessionId, sport: track.sport, startedAt: track.startedAt.timeIntervalSince1970,
            device: .init(kind: "", model: "", os: ""), app: .init(version: "", build: ""))
        return RawSession(meta: meta, gps: track.gps, hr: track.hr, events: track.events)
    }

    static func check(_ truth: Labels.Truth, session: RawSession, context: String) throws {
        if truth.strokes != nil || truth.strokeRateSPM != nil {
            try #require(
                session.meta.sport.isPaddling && !session.motion.isEmpty,
                "\(context): stroke labels need raw paddling motion")
            // The same path as session detail: strokes in moving time (no manual or auto
            // pause, no vehicle leg) over the recording's own selection.
            let selection = try SessionSelection(session: session)
            let strokes = StrokeAnalysis(session: session, selection: selection)
            if let count = truth.strokes {
                #expect(
                    count >= 0 && abs(Double(strokes.strokeCount) - Double(count)) <= 0.03 * Double(count),
                    "\(context): counted \(strokes.strokeCount), expected \(count) ±3%")
            }
            if let rate = truth.strokeRateSPM {
                let actual = try #require(strokes.averageStrokeRate, "\(context): no mean stroke rate")
                #expect(rate > 0 && abs(actual - rate) <= 2, "\(context): measured \(actual) SPM, expected \(rate) ±2")
            }
        }

        if truth.maneuvers != nil || truth.windDirectionDeg != nil {
            try #require(
                session.meta.sport == .sailing, "\(context): tack, gybe and wind labels need a sailing session")
            let selection = try SessionSelection(session: session)
            if let wind = truth.windDirectionDeg {
                try #require((0...360).contains(wind), "\(context): invalid wind direction")
                // The prior selects the side of the axis. The track must still
                // produce its own estimate within 10° of the measured direction.
                let estimate = try #require(selection.estimatedWind(prior: wind), "\(context): no wind estimate")
                let error = abs(GPSFilter.signedDifference(from: wind, to: estimate.fromDegrees))
                #expect(error <= 10, "\(context): estimated \(estimate.fromDegrees)°, expected \(wind)° ±10°")
            }
            if let maneuvers = truth.maneuvers.map({ $0.map { SessionEvent(t: $0.t, type: $0.type) } }) {
                try #require(
                    maneuvers.allSatisfy {
                        ($0.type == .tack || $0.type == .gybe) && (0...selection.duration).contains($0.t)
                    }, "\(context): invalid maneuver type or timestamp")
                let detected = selection.sailingAnalysis(windFromDegreesTrue: truth.windDirectionDeg).maneuvers
                expectManeuversMatch(detected, labels: maneuvers, context: context)
            }
        }
    }
}

/// PLAN §5 thresholds. Use the same one-to-one scoring for synthetic courses and
/// recordings. A match must be the right type and within 2 s of the labeled crossing,
/// with that crossing inside the observed turn.
func expectManeuversMatch(
    _ maneuvers: [SailingManeuver], labels: [SessionEvent], context: String = "synthetic course",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var unmatched = maneuvers
    var matches = 0
    for label in labels.sorted(by: { $0.t < $1.t }) {
        if let index = unmatched.firstIndex(where: {
            $0.event.type == label.type && abs($0.event.t - label.t) <= 2 && $0.range.contains(label.t)
        }) {
            unmatched.remove(at: index)
            matches += 1
        }
    }
    #expect(
        labels.isEmpty || Double(matches) / Double(labels.count) >= 0.95,
        "\(context): matched \(matches) of \(labels.count) labeled maneuvers", sourceLocation: sourceLocation)
    #expect(
        Double(unmatched.count) / Double(max(1, maneuvers.count)) < 0.05,
        "\(context): \(unmatched.count) false positives in \(maneuvers.count) detections",
        sourceLocation: sourceLocation)
}
