import SwiftUI

/// The iPhone app's light or dark choice, kept on this device only. The watch is always
/// dark, so it isn't synced.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The window style to apply; `.unspecified` follows the iPhone's setting.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Sets the style on every window, so sheets and alerts follow too.
    /// `preferredColorScheme(nil)` doesn't reliably return to the iPhone's style after
    /// an explicit one, so this uses the window override instead.
    @MainActor
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

/// Applies the Appearance setting now and whenever it changes. It lives in a view, as an
/// `@AppStorage` on the App struct doesn't see changes made from Settings.
struct FollowsAppearance: ViewModifier {
    @AppStorage(UserSettings.Key.appearance) private var appearance: Appearance = .system

    func body(content: Content) -> some View {
        content.onChange(of: appearance, initial: true) { _, appearance in
            appearance.apply()
        }
    }
}
