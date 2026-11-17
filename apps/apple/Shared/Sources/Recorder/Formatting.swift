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

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
