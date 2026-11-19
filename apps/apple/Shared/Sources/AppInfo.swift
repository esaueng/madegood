import Foundation

/// Facts about the running build, shared by the iPhone and watch apps.
enum AppInfo {
    static let name = "MadeGood"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(marketing) (\(build))"
    }

    /// `<MadeGoodSiteURL>/privacy` (Config/MadeGood.xcconfig), or nil when the build names no
    /// HTTPS site. Only the iPhone app's Info.plist sets the key.
    static var privacyPolicyURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MadeGoodSiteURL") as? String,
            let site = URL(string: value.trimmingCharacters(in: .whitespaces)), site.scheme == "https",
            site.host() != nil
        else { return nil }
        return site.appending(path: "privacy")
    }
}
