import Foundation
import WaterKit

/// The recording device, without its user-assigned name (docs/formats.md).
enum DeviceInfo {
    static var current: RawFormat.Device {
        #if os(watchOS)
            let kind = "watch"
            let osName = "watchOS"
        #else
            let kind = "phone"
            let osName = "iOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(osName) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return RawFormat.Device(kind: kind, model: modelIdentifier, os: os)
    }

    /// Hardware model such as `Watch7,5` or `iPhone18,1` (`x86_64`/`arm64` in the simulator).
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var app: RawFormat.App {
        let info = Bundle.main.infoDictionary
        return RawFormat.App(
            version: info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0")
    }
}
