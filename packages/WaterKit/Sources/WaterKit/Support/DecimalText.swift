import Foundation

/// Plain decimal text for numbers: "." as the separator, no exponent, no grouping, and
/// the same output on every platform and locale. Used for file formats (GPX) and for
/// the display helpers' fallback text.
enum DecimalText {
    /// `value` rounded half away from zero to `digits` fractional digits (0...9).
    /// With `trimZeros`, trailing fractional zeros (and a bare ".") are dropped.
    /// Negative zero prints as "0". Non-finite values print as "nan", "inf" or "-inf".
    static func fixed(_ value: Double, digits: Int, trimZeros: Bool = false) -> String {
        precondition((0...9).contains(digits), "digits must be 0...9")
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }

        var scale: Int64 = 1
        for _ in 0..<digits { scale *= 10 }
        let scaled = (abs(value) * Double(scale)).rounded(.toNearestOrAwayFromZero)
        guard scaled < 1e15 else {
            // Far outside any value the app records; let the C formatter handle it.
            return String(format: "%.\(digits)f", value)
        }

        let units = Int64(scaled)
        let integerPart = units / scale
        var text = (value < 0 && units != 0 ? "-" : "") + String(integerPart)
        if digits > 0 {
            var fraction = String(units % scale)
            fraction = String(repeating: "0", count: digits - fraction.count) + fraction
            if trimZeros {
                while fraction.last == "0" { fraction.removeLast() }
            }
            if !fraction.isEmpty { text += "." + fraction }
        }
        return text
    }
}
