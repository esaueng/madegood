import Foundation
import Testing

@testable import WaterKit

@Suite struct FixtureAccuracyTests {
    private struct Labels: Decodable {
        struct Truth: Decodable {
            var strokes: Int?
            var strokeRateSPM: Double?
            var maneuvers: [SessionEvent]?
            var windDirectionDeg: Double?
        }

        var v: Int
        var sport: Sport
        var truth: Truth
    }

    @Test func labeledRecordingsMeetPlanThresholds() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = repository.appendingPathComponent("fixtures")
        let fm = FileManager.default
        for root in [fixtures, fixtures.appendingPathComponent(".corpus")] {
            for sport in Sport.allCases {
                let sportFolder = root.appendingPathComponent(sport.rawValue)
                guard fm.fileExists(atPath: sportFolder.path) else { continue }
                let folders = try fm.contentsOfDirectory(at: sportFolder, includingPropertiesForKeys: nil)
                for folder in folders.sorted(by: { $0.path < $1.path }) {
                    let file = folder.appendingPathComponent("labels.json")
                    guard fm.fileExists(atPath: file.path) else { continue }
                    let context = folder.path.replacingOccurrences(of: repository.path + "/", with: "")
                    do {
                        let problems = FixtureCheck.labelsProblems(file)
                        try #require(problems.isEmpty, "\(context): \(problems)")
                        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: file))
                        try #require(labels.v == 1, "\(context): unsupported labels version")
                        let session = try Self.loadRecording(folder, truth: labels.truth)
                        try #require(
                            labels.sport == sport && labels.sport == session.meta.sport, "\(context): sport mismatch")
                        try #require(session.issues.isEmpty, "\(context): \(session.issues)")
                        try Self.check(labels.truth, session: session, context: context)
                        // The thresholds must also hold after writing the recording with the
                        // current writer (rounded values) and reading it back.
                        if let rewritten = try Self.rewritten(folder, session, truth: labels.truth) {
                            try Self.check(labels.truth, session: rewritten, context: context + " (rewritten)")
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Issue.record("\(context): \(error)")
                    }
                }
            }
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

    private static func check(_ truth: Labels.Truth, session: RawSession, context: String) throws {
        if truth.strokes != nil || truth.strokeRateSPM != nil {
            try #require(
                session.meta.sport.isPaddling && !session.motion.isEmpty,
                "\(context): stroke labels need raw paddling motion")
            let strokes = StrokeAnalysis(
                detection: StrokeAnalysis.detect(session: session), sport: session.meta.sport, distance: nil)
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
            if let maneuvers = truth.maneuvers {
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
