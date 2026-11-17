import SwiftUI

/// Brand colors from the logo (assets/icon.svg). The apps' accent is AccentColor in each
/// asset catalog; these are for the few places that need the full palette.
enum Theme {
    static let teal = Color(red: 0x05 / 255, green: 0x60 / 255, blue: 0x5F / 255)
    static let cream = Color(red: 0xFC / 255, green: 0xF0 / 255, blue: 0xDA / 255)
    static let coral = Color(red: 0xEE / 255, green: 0x7B / 255, blue: 0x57 / 255)
    /// The dark-mode accent: teal lifted for contrast on black.
    static let brightTeal = Color(red: 0x3F / 255, green: 0xB8 / 255, blue: 0xA6 / 255)
}
