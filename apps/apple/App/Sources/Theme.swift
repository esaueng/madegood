import SwiftUI

extension Theme {
    /// Track colors from slow to fast.
    static let speedScale: [Color] = [
        Color(red: 0.16, green: 0.45, blue: 0.70),
        Color(red: 0.10, green: 0.62, blue: 0.62),
        Color(red: 0.55, green: 0.74, blue: 0.30),
        Color(red: 0.96, green: 0.72, blue: 0.20),
        coral,
    ]

    /// One color per kind of metric, for captions and charts on every iPhone screen, so a
    /// distance always reads as a distance. Light values keep 5:1 contrast on white; dark
    /// values keep 6:1 on the dark card background.
    enum Metric {
        /// Petrol in light mode, the bright petrol accent in dark mode.
        static let distance = dynamic(light: 0x0B5470, dark: 0x4AAED4)
        static let time = dynamic(light: 0x0E7A70, dark: 0x3CC2B1)
        /// The brand coral, darkened in light mode for contrast.
        static let speed = dynamic(light: 0xB5482A, dark: 0xEE7B57)
        static let heartRate = dynamic(light: 0xC4303A, dark: 0xFF6B70)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}

/// A metric as a colored caption over a large number with smaller units: "Distance" over
/// "6.42 km", or "Moving time" over "1 h 46 min". The value is the display text; words
/// that start with a digit (or "–" for no value) are drawn large, the rest as units.
struct MetricValue: View {
    enum Size {
        case large, medium

        var number: Font { self == .large ? .title.weight(.bold) : .title3.weight(.bold) }
    }

    let title: String
    let value: String
    var color: Color = .secondary
    var size: Size = .large
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            styled
                .monospacedDigit()
                .fontDesign(.rounded)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // No default identifier: UI tests find card values by their text.
                .accessibilityIdentifier(identifier ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var styled: Text {
        var text = Text(verbatim: "")
        for (index, part) in Self.parts(value).enumerated() {
            // A thin space ties a unit to its number; a full space starts the next number.
            let separator = index == 0 ? "" : part.isNumber ? " " : "\u{2009}"
            let piece =
                part.isNumber
                ? Text(verbatim: separator + part.text).font(size.number)
                : Text(verbatim: separator + part.text).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            text = Text("\(text)\(piece)")
        }
        return text
    }

    static func parts(_ value: String) -> [(text: String, isNumber: Bool)] {
        value.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map { word in
            let first = word.first
            return (String(word), first?.isNumber == true || first == "–" || first == "-")
        }
    }
}

/// A metric shown as a small caption over a large value.
struct StatTile: View {
    let title: String
    let value: String
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .fontDesign(.rounded)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(identifier ?? "stat.\(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
