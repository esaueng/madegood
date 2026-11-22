import Foundation

/// A fixture's `labels.json` (fixtures/README.md): how the truth was measured, and the truth.
/// Encoding writes only the documented fields.
public struct FixtureLabelsFile: Sendable, Hashable, Codable {
    public struct Maneuver: Sendable, Hashable, Codable {
        public var t: Double
        public var type: EventType
    }

    public struct Truth: Sendable, Hashable, Codable {
        public var strokes: Int?
        public var strokeRateSPM: Double?
        public var strokeTimes: [StrokeLabels.Stroke]?
        public var excluded: [StrokeLabels.Segment]?
        public var maneuvers: [Maneuver]?
        public var windDirectionDeg: Double?
        public var distanceM: Double?

        public init(
            strokes: Int? = nil, strokeRateSPM: Double? = nil, strokeTimes: [StrokeLabels.Stroke]? = nil,
            excluded: [StrokeLabels.Segment]? = nil, maneuvers: [Maneuver]? = nil, windDirectionDeg: Double? = nil,
            distanceM: Double? = nil
        ) {
            self.strokes = strokes
            self.strokeRateSPM = strokeRateSPM
            self.strokeTimes = strokeTimes
            self.excluded = excluded
            self.maneuvers = maneuvers
            self.windDirectionDeg = windDirectionDeg
            self.distanceM = distanceM
        }
    }

    /// `source` of labels nobody has reviewed yet. FixtureCheck rejects it, so a draft can
    /// never pass as a fixture's ground truth.
    public static let draftSource = "draft"

    public var v: Int
    public var sport: Sport
    public var source: String
    public var description: String?
    public var license: String
    public var truth: Truth

    public init(
        sport: Sport, source: String, description: String? = nil, license: String = "CC-BY-4.0", truth: Truth
    ) {
        v = 1
        self.sport = sport
        self.source = source
        self.description = description
        self.license = license
        self.truth = truth
    }

    /// Unreviewed labels from the detector's candidates, times rounded to the millisecond.
    public static func draft(sport: Sport, labels: StrokeLabels) -> FixtureLabelsFile {
        let strokes = labels.strokes.map { StrokeLabels.Stroke(t: ($0.t * 1000).rounded() / 1000, side: $0.side) }
        return FixtureLabelsFile(
            sport: sport, source: draftSource, description: "",
            truth: Truth(strokeTimes: strokes, excluded: labels.excluded))
    }

    /// The stroke-by-stroke labels, when the truth has them.
    public var strokeLabels: StrokeLabels? {
        truth.strokeTimes.map { StrokeLabels(strokes: $0, excluded: truth.excluded ?? []) }
    }

    /// The truth's stroke count and average rate: as labelled, or derived from the stroke
    /// times. Throws when both are given and disagree.
    public func strokeTruth() throws(FixtureLabelsError) -> (strokes: Int?, strokeRateSPM: Double?) {
        guard let labels = strokeLabels else { return (truth.strokes, truth.strokeRateSPM) }
        let count = labels.count
        let rate = labels.strokeRate(sport: sport)
        var problems: [String] = []
        if let stated = truth.strokes, stated != count {
            problems.append("truth.strokes is \(stated) but strokeTimes has \(count) strokes")
        }
        if let stated = truth.strokeRateSPM, rate.map({ abs($0 - stated) > 0.05 }) ?? true {
            problems.append(
                "truth.strokeRateSPM is \(stated) but strokeTimes give \(rate.map { "\($0)" } ?? "no rate")")
        }
        guard problems.isEmpty else { throw FixtureLabelsError(problems: problems) }
        return (count, truth.strokeRateSPM ?? rate)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

public struct FixtureLabelsError: Error, Sendable, Hashable, CustomStringConvertible {
    public var problems: [String]
    public var description: String { problems.joined(separator: "; ") }
}

public enum FixtureLabels {
    /// Checks reviewed labels against the recording they were made on and returns them
    /// re-encoded with only the documented fields. Times are seconds since the session
    /// start, which anonymizing keeps, so they stay valid for the anonymized recording. The
    /// free-text description is left out: it could name a person, a place or a date, and
    /// no check can tell. Add one by hand in the fixture's pull request, where it is reviewed.
    /// Throws for a draft, a schema problem, another sport, or times outside the recording.
    public static func export(_ data: Data, for session: RawSession) throws(FixtureLabelsError) -> Data {
        var problems = FixtureCheck.labelsProblems(data)
        guard problems.isEmpty else { throw FixtureLabelsError(problems: problems) }
        var labels: FixtureLabelsFile
        do {
            labels = try JSONDecoder().decode(FixtureLabelsFile.self, from: data)
        } catch {
            throw FixtureLabelsError(problems: ["labels.json: \(error)"])
        }
        if labels.v != 1 { problems.append("labels.json: unsupported version \(labels.v)") }
        if labels.sport != session.meta.sport {
            problems.append(
                "labels.json is for \(labels.sport.rawValue), the recording is \(session.meta.sport.rawValue)")
        }
        let duration = max(session.duration, session.motion.last?.t ?? 0, session.gps.last?.t ?? 0)
        if let strokes = labels.strokeLabels {
            problems += strokes.problems(duration: duration).map { "labels.json: \($0)" }
            if strokes.count == 0 { problems.append("labels.json: truth.strokeTimes is empty") }
            // The accuracy test scores both count and rate, so labels must give a rate.
            if strokes.count > 0, strokes.strokeRate(sport: labels.sport) == nil {
                problems.append("labels.json: the strokes give no rate (no bout of three strokes in a row)")
            }
        }
        if (labels.truth.maneuvers ?? []).contains(where: { $0.t < 0 || $0.t > duration + 1 }) {
            problems.append("labels.json: maneuver times must lie within the recording")
        }
        do {
            _ = try labels.strokeTruth()
        } catch {
            problems += error.problems.map { "labels.json: \($0)" }
        }
        guard problems.isEmpty else { throw FixtureLabelsError(problems: problems) }
        labels.description = nil
        do {
            return try labels.encoded()
        } catch {
            throw FixtureLabelsError(problems: ["labels.json: \(error)"])
        }
    }
}

extension Anonymizer {
    /// Anonymizes the raw recording in `input` into the new folder `output` (streams
    /// gzipped), with its reviewed `labels` when given, and checks the result with
    /// `FixtureCheck`. This is `scripts/anonymize-track`'s path for a recording folder.
    public func exportFixture(from input: URL, to output: URL, labels: Data? = nil) throws {
        let session = try RawSessionReader.read(folder: input)
        // Validate the labels before writing anything.
        var exportedLabels: Data?
        if let labels { exportedLabels = try FixtureLabels.export(labels, for: session) }
        try RawSessionWriter.write(anonymize(session), to: output)
        if let exportedLabels {
            try exportedLabels.write(to: output.appendingPathComponent(FixtureCheck.labelsFileName))
        }
        let problems = FixtureCheck.problems(inFolder: output)
        guard problems.isEmpty else {
            throw FixtureLabelsError(problems: ["anonymized output failed its check"] + problems)
        }
    }
}
