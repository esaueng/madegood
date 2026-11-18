import Foundation

extension SessionStats {
    /// A plain-text report for terminals, with SI values and knots alongside speeds.
    public func textReport() -> String {
        var lines: [String] = []
        lines.append("Session   \(sessionId)  \(sport)  \(startedAt)")
        lines.append("Duration  \(Self.clock(duration)) (\(Self.fixed(duration, 1)) s)")
        lines.append("")
        lines.append(Self.row("Stream", "Samples", "Rate", "Span (s)", "Gaps"))
        for name in ["gps", "motion", "hr", "heading", "events"] {
            guard let stream = streams[name] else { continue }
            let rate = stream.medianRate.map { "\(Self.fixed($0, $0 >= 10 ? 1 : 2)) Hz" } ?? "-"
            let span =
                stream.start.map { start in
                    "\(Self.fixed(start, 1))–\(Self.fixed(stream.end ?? start, 1))"
                } ?? "-"
            let gaps = stream.gaps == 0 ? "0" : "\(stream.gaps) (longest \(Self.fixed(stream.longestGap ?? 0, 1)) s)"
            lines.append(Self.row(name, "\(stream.count)", rate, span, gaps))
        }
        lines.append("")
        lines.append(
            "Distance  \(Self.fixed(distance / 1000, 2)) km  (\(acceptedFixes) fixes used, \(rejectedFixes) rejected: "
                + "accuracy worse than \(Int(Self.maxHorizontalAccuracy)) m)")
        lines.append("Avg speed \(Self.speed(averageSpeed))")
        lines.append("Max speed 2 s: \(Self.speed(maxSpeed2s))   10 s: \(Self.speed(maxSpeed10s))")
        if let categories = speedCategories {
            let rows = [
                ("5 × 10 s", "best5x10s"), ("100 m", "best100m"), ("500 m", "best500m"),
                ("Nautical mile", "bestNauticalMile"), ("1 hour", "best1h"), ("Alpha 500", "alpha500"),
            ]
            for (label, key) in rows {
                let padded = label.padding(toLength: 14, withPad: " ", startingAt: 0)
                lines.append("  \(padded)\(Self.speed(categories[key]))")
            }
        }
        if let average = heartRateAverage, let max = heartRateMax {
            lines.append("Heart rate avg \(Self.fixed(average, 0)) bpm, max \(Self.fixed(max, 0)) bpm")
        }
        if let strokes {
            var line = "Strokes   \(strokes.count)"
            if let rate = strokes.averageRate { line += ", avg \(Self.fixed(rate, 1)) spm" }
            if let perStroke = strokes.distancePerStroke { line += ", \(Self.fixed(perStroke, 2)) m/stroke" }
            if let switches = strokes.sideSwitches { line += ", \(switches) side switches" }
            if let balance = strokes.sideBalance { line += " (\(Self.fixed(balance * 100, 0)) % on first side)" }
            lines.append(line)
        }
        let eventList = events.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
        lines.append("Events    \(eventList.isEmpty ? "none" : eventList.joined(separator: ", "))")
        if issues.isEmpty {
            lines.append("Issues    none")
        } else {
            lines.append("Issues    \(issues.count)")
            lines += issues.map { "  - \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Pretty-printed JSON with sorted keys, for scripts and tests.
    public func jsonReport() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static let metersPerSecondToKnots = 3600.0 / 1852.0

    static func speed(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(fixed(value, 2)) m/s (\(fixed(value * metersPerSecondToKnots, 2)) kn)"
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? "\(h):\(pad(m)):\(pad(s))" : "\(m):\(pad(s))"
    }

    static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// Fixed-point formatting without Foundation's locale-dependent formatters.
    static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return "\(value)" }
        let scale = (0..<digits).reduce(1.0) { result, _ in result * 10 }
        let scaled = (abs(value) * scale).rounded()
        let integer = Int(scaled / scale)
        let fraction = Int(scaled.truncatingRemainder(dividingBy: scale))
        let sign = value < 0 && scaled != 0 ? "-" : ""
        guard digits > 0 else { return "\(sign)\(integer)" }
        let fractionText = String(fraction)
        return "\(sign)\(integer).\(String(repeating: "0", count: digits - fractionText.count))\(fractionText)"
    }

    static func row(_ columns: String...) -> String {
        let widths = [9, 9, 10, 18, 0]
        return zip(columns, widths).map { column, width in
            width == 0 ? column : column.padding(toLength: max(width, column.count + 1), withPad: " ", startingAt: 0)
        }.joined()
    }
}
