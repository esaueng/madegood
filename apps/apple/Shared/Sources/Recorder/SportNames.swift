import SwiftUI
import WaterKit

extension Sport {
    var displayName: String {
        switch self {
        case .sailing: "Sailing"
        case .windsurfing: "Windsurfing"
        case .motorboating: "Motorboating"
        case .kayak: "Kayak"
        case .canoe: "Canoe"
        case .sup: "SUP"
        }
    }

    /// The sport's icon in Shared/Resources/SportIcons.xcassets (template vector images).
    var iconName: String { "sport.\(rawValue)" }
}

/// A sport's icon, `size` points square (scaled with Dynamic Type), in the foreground style.
/// Decorative unless `labeled`, when VoiceOver reads the sport's name.
struct SportIcon: View {
    let sport: Sport
    var size: CGFloat
    var labeled = false
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        let image = Image(sport.iconName)
            .resizable()
            .scaledToFit()
            .frame(width: size * scale, height: size * scale)
        if labeled {
            image.accessibilityLabel(sport.displayName)
        } else {
            image.accessibilityHidden(true)
        }
    }
}

extension Sport: @retroactive Identifiable {
    public var id: String { rawValue }
}
