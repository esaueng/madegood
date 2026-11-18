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
