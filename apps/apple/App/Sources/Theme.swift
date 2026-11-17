import SwiftUI

/// Brand colors from the logo (assets/icon.svg). The app's accent is AccentColor in the
/// asset catalog; these are for the few places that need the full palette.
enum Theme {
    static let teal = Color(red: 0x05 / 255, green: 0x60 / 255, blue: 0x5F / 255)
    static let cream = Color(red: 0xFC / 255, green: 0xF0 / 255, blue: 0xDA / 255)
    static let coral = Color(red: 0xEE / 255, green: 0x7B / 255, blue: 0x57 / 255)

    /// Track colors from slow to fast.
    static let speedScale: [Color] = [
        Color(red: 0.16, green: 0.45, blue: 0.70),
        Color(red: 0.10, green: 0.62, blue: 0.62),
        Color(red: 0.55, green: 0.74, blue: 0.30),
        Color(red: 0.96, green: 0.72, blue: 0.20),
        coral,
    ]
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(identifier ?? "stat.\(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
