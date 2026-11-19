import SwiftUI

/// The wind relative to the boat: the top of the dial is the course over ground and the
/// arrow points the way the wind blows, so on a beat it comes in at the top corner.
/// Without a course it is drawn north-up. Hidden from VoiceOver: callers label it.
struct WindArrow: View {
    /// Direction the wind blows from, degrees true.
    let windFrom: Double
    /// Course over ground, degrees true; nil for north-up.
    let course: Double?
    var size: CGFloat = 44

    var body: some View {
        let relative = windFrom - (course ?? 0)
        ZStack {
            Circle()
                .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.5)
            // A small mark for the bow (or north).
            Capsule()
                .fill(.secondary)
                .frame(width: 2, height: size * 0.14)
                .offset(y: -size * 0.40)
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Theme.brightTeal)
                .offset(y: -size * 0.12)
                .rotationEffect(.degrees(relative))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
