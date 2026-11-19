import SwiftUI

/// Brand colors from the logo (assets/icon.svg). The apps' accent is AccentColor in each
/// asset catalog; these are for the few places that need the full palette.
enum Theme {
    /// The logo's mid petrol blue (#0B5470), the light-mode accent.
    static let petrol = Color(red: 0x0B / 255, green: 0x54 / 255, blue: 0x70 / 255)
    /// The logo's glyph: a cool pearl white (#F4F5F2).
    static let pearl = Color(red: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF2 / 255)
    static let coral = Color(red: 0xEE / 255, green: 0x7B / 255, blue: 0x57 / 255)
    /// The dark-mode accent (#4AAED4): petrol lifted for contrast on black.
    static let brightPetrol = Color(red: 0x4A / 255, green: 0xAE / 255, blue: 0xD4 / 255)

    /// The app icon's background: light petrol at the top to deep petrol at the bottom.
    static let iconBackground = LinearGradient(
        stops: [
            .init(color: Color(red: 0x23 / 255, green: 0x87 / 255, blue: 0xA6 / 255), location: 0),
            .init(color: petrol, location: 0.55),
            .init(color: Color(red: 0x04 / 255, green: 0x24 / 255, blue: 0x3A / 255), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The app icon's glyph: white at the crests to pearl at the base.
    static let iconGlyph = LinearGradient(
        colors: [.white, pearl, Color(red: 0xDC / 255, green: 0xDC / 255, blue: 0xD2 / 255)],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// The logo: the pearl wave on a petrol rounded square, as on the app icon (assets/icon.svg).
struct LogoMark: View {
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2227, style: .continuous)
        Image("logo.wave")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Theme.iconGlyph)
            .shadow(color: Color(red: 0, green: 0x0F / 255, blue: 0x1A / 255).opacity(0.65), radius: size * 0.018, y: size * 0.016)
            .frame(width: size, height: size)
            .background(Theme.iconBackground, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
