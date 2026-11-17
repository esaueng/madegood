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
}
