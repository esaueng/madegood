import SwiftUI
import WaterKit

/// A sport's glyph in a filled accent circle, as on the start screen and in Settings.
/// The circle and glyph grow with text size together, up to xxxLarge, so the badge never
/// crowds out the text beside it or spills out of its circle.
struct SportBadge: View {
    let sport: Sport
    /// The circle's size at the default text size.
    let diameter: CGFloat
    var dimmed = false

    var body: some View {
        Scaled(sport: sport, dimmed: dimmed, diameter: diameter)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityHidden(true)
    }

    private struct Scaled: View {
        let sport: Sport
        let dimmed: Bool
        @ScaledMetric private var diameter: CGFloat

        init(sport: Sport, dimmed: Bool, diameter: CGFloat) {
            self.sport = sport
            self.dimmed = dimmed
            _diameter = ScaledMetric(wrappedValue: diameter)
        }

        var body: some View {
            Image(sport.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: diameter * 0.73, height: diameter * 0.73)
                .foregroundStyle(Theme.pearl)
                .frame(width: diameter, height: diameter)
                .background(Color.accentColor.opacity(dimmed ? 0.4 : 1), in: .circle)
        }
    }
}
