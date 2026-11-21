import Foundation

enum Formatting {
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// A longer span in words: "1 h 23 min", "48 min", "35 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m) = (total / 3600, total % 3600 / 60)
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return m > 0 ? "\(m) min" : "\(total) s"
    }

    /// Metrics on one line, "3 sessions · 24.2 km · 1 h 46 min", that wrap only between
    /// metrics: a space next to a number is non-breaking, so a value never leaves its unit,
    /// and each "·" stays at the end of a line rather than starting the next. A space between
    /// two words ("awaiting metrics") stays breakable, so a phrase longer than a line still
    /// wraps at a word instead of mid-word.
    static func metricLine(_ metrics: [String]) -> String {
        metrics.map(bindValuesToUnits).joined(separator: "\u{00A0}· ")
    }

    private static func bindValuesToUnits(_ metric: String) -> String {
        let chars = Array(metric)
        var out = ""
        for (i, c) in chars.enumerated() {
            let betweenWords = i > 0 && i + 1 < chars.count && chars[i - 1].isLetter && chars[i + 1].isLetter
            out.append(c == " " && !betweenWords ? "\u{00A0}" : c)
        }
        return out
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
