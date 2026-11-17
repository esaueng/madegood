import Foundation

/// ISO 8601 UTC timestamps as used in track files: `2027-05-01T10:00:00.250Z`.
enum Timestamp {
    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Parses with or without fractional seconds.
    static func parse(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
