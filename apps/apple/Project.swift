import ProjectDescription

// Bundle IDs derive from BUNDLE_ID_PREFIX (Config/MadeGood.xcconfig), which a
// gitignored Config/Local.xcconfig overrides together with DEVELOPMENT_TEAM.

let iOSTarget: DeploymentTargets = .iOS("26.0")
let watchOSTarget: DeploymentTargets = .watchOS("26.0")

let versionKeys: [String: Plist.Value] = [
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "CFBundleDisplayName": "MadeGood",
]

/// Permission prompts shared by both apps (docs/app-store.md, item 6). Each says what the
/// app actually does with the permission.
let usageKeys: [String: Plist.Value] = [
    "NSLocationWhenInUseUsageDescription":
        "MadeGood records your track, speed and course during a session, including with the screen off. It also uses your position for start-line pings, and to mark a man-overboard position and guide you back to it.",
    "NSMotionUsageDescription":
        "MadeGood records motion during a session to count paddle strokes. The samples stay in the recording on your devices.",
    "NSHealthShareUsageDescription":
        "MadeGood reads your heart rate during a session to show it live, with your heart-rate zone, and in your session summary.",
    "NSHealthUpdateUsageDescription":
        "MadeGood saves your sessions to Health as workouts, with the route and heart rate, if you turn on Save to Health.",
]

let healthKitEntitlements: [String: Plist.Value] = [
    "com.apple.developer.healthkit": true,
    "com.apple.developer.healthkit.access": [],
]
let healthKit: Entitlements = .dictionary(healthKitEntitlements)
let iPhoneEntitlements: Entitlements = .dictionary(
    healthKitEntitlements.merging([
        "com.apple.developer.applesignin": ["Default"],
        "com.apple.developer.weatherkit": true,
    ]) { _, new in new }
)

func plist(_ parts: [String: Plist.Value]...) -> InfoPlist {
    .extendingDefault(with: parts.reduce(into: [:]) { result, part in
        result.merge(part) { _, new in new }
    })
}

let project = Project(
    name: "MadeGood",
    options: .options(
        automaticSchemesOptions: .enabled(),
        developmentRegion: "en"
    ),
    settings: .settings(
        // Must be in the manifest: Tuist sets a target-level SWIFT_VERSION = 5 unless the
        // project's base settings define it, and that would override the xcconfig.
        base: ["SWIFT_VERSION": "6.0"],
        configurations: [
            .debug(
                name: .debug,
                settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) MADEGOOD_VOYAGES"],
                xcconfig: "Config/MadeGood.xcconfig"
            ),
            .release(name: .release, xcconfig: "Config/MadeGood.xcconfig"),
        ]
    ),
    targets: [
        .target(
            name: "MadeGood",
            destinations: [.iPhone],
            product: .app,
            bundleId: "$(BUNDLE_ID_PREFIX)",
            deploymentTargets: iOSTarget,
            infoPlist: plist(versionKeys, usageKeys, [
                // The iPhone also shows local conditions and runs the anchor alarm. Release-accurate:
                // Voyages is Debug-only (#138), so voyage legs are not mentioned.
                "NSLocationWhenInUseUsageDescription":
                    "MadeGood records your track, speed and course during a session, including with the screen off. It also uses your position for start-line pings, to mark a man-overboard position and guide you back to it, to set an anchor point and watch for drift while the anchor alarm is armed, and, rounded to about 11 km, for local conditions if you turn them on.",
                "NSAlarmKitUsageDescription":
                    "MadeGood sounds an alarm if your boat drifts outside the swing radius you set, or if usable GPS positions stop arriving while the anchor alarm is armed.",
                "UILaunchScreen": [:],
                "UIRequiredDeviceCapabilities": ["arm64"],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                // Location keeps recording with the screen off. `workout-processing` is a
                // watchOS mode: App Store Connect rejects it in an iPhone app's
                // UIBackgroundModes, so the phone's own workout session relies on location.
                "UIBackgroundModes": ["location"],
                // Lock Screen and Dynamic Island while recording (Widgets/).
                "NSSupportsLiveActivities": true,
                // Recordings in Documents are visible in the Files app.
                "UIFileSharingEnabled": true,
                "LSSupportsOpeningDocumentsInPlace": true,
                // Session sync's API root (Config/MadeGood.xcconfig); empty turns sync off.
                "MadeGoodAPIURL": "$(MADEGOOD_API_URL)",
                // The website, for the privacy policy link in Settings (Config/MadeGood.xcconfig).
                "MadeGoodSiteURL": "$(MADEGOOD_SITE_URL)",
                // Only standard HTTPS, so App Store Connect needs no export compliance answer.
                "ITSAppUsesNonExemptEncryption": false,
            ]),
            sources: ["App/Sources/**", "Shared/Sources/**"],
            resources: ["App/Resources/**", "Shared/Resources/**"],
            entitlements: iPhoneEntitlements,
            dependencies: [
                .target(name: "MadeGoodWatch"),
                .target(name: "MadeGoodWidgets"),
                .external(name: "WaterKit"),
                .external(name: "OpenAPIRuntime"),
                .external(name: "HTTPTypes"),
                .external(name: "HTTPTypesFoundation"),
            ]
        ),
        .target(
            name: "MadeGoodWatch",
            destinations: [.appleWatch],
            product: .app,
            productName: "MadeGoodWatch",
            bundleId: "$(BUNDLE_ID_PREFIX).watchkitapp",
            deploymentTargets: watchOSTarget,
            infoPlist: plist(versionKeys, usageKeys, [
                "WKApplication": true,
                "WKCompanionAppBundleIdentifier": "$(BUNDLE_ID_PREFIX)",
                "WKRunsIndependentlyOfCompanionApp": false,
                "WKBackgroundModes": ["workout-processing"],
            ]),
            sources: ["Watch/Sources/**", "Shared/Sources/**"],
            resources: ["Watch/Resources/**", "Shared/Resources/**"],
            entitlements: healthKit,
            dependencies: [
                .target(name: "MadeGoodWatchWidgets"),
                .external(name: "WaterKit"),
            ]
        ),
        .target(
            name: "MadeGoodWidgets",
            destinations: [.iPhone],
            product: .appExtension,
            bundleId: "$(BUNDLE_ID_PREFIX).widgets",
            deploymentTargets: iOSTarget,
            infoPlist: plist(versionKeys, [
                "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
            ]),
            sources: ["Widgets/Sources/**", "Shared/Sources/LiveActivity/SessionActivityAttributes.swift"],
            resources: ["Shared/Resources/**"]
        ),
        .target(
            name: "MadeGoodWatchWidgets",
            destinations: [.appleWatch],
            product: .appExtension,
            bundleId: "$(BUNDLE_ID_PREFIX).watchkitapp.complications",
            deploymentTargets: watchOSTarget,
            infoPlist: plist(versionKeys, [
                "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
            ]),
            sources: ["WatchWidgets/Sources/**"]
        ),
        .target(
            name: "MadeGoodTests",
            destinations: [.iPhone],
            product: .unitTests,
            bundleId: "$(BUNDLE_ID_PREFIX).tests",
            deploymentTargets: iOSTarget,
            infoPlist: .default,
            sources: ["Tests/iOS/**"],
            dependencies: [.target(name: "MadeGood")]
        ),
        // UI tests run the apps in demo mode (DemoFeed): no GPS, Health or prompts.
        .target(
            name: "MadeGoodUITests",
            destinations: [.iPhone],
            product: .uiTests,
            bundleId: "$(BUNDLE_ID_PREFIX).uitests",
            deploymentTargets: iOSTarget,
            infoPlist: .default,
            sources: ["UITests/iOS/**", "UITests/Shared/**"],
            dependencies: [.target(name: "MadeGood")]
        ),
        .target(
            name: "MadeGoodWatchUITests",
            destinations: [.appleWatch],
            product: .uiTests,
            bundleId: "$(BUNDLE_ID_PREFIX).watchkitapp.uitests",
            deploymentTargets: watchOSTarget,
            infoPlist: .default,
            sources: ["UITests/Watch/**", "UITests/Shared/**"],
            dependencies: [.target(name: "MadeGoodWatch")]
        ),
    ]
)
