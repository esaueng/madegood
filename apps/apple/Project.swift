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

/// Permission prompts shared by both apps.
let usageKeys: [String: Plist.Value] = [
    "NSLocationWhenInUseUsageDescription":
        "MadeGood records your track, speed, and course while you are on the water.",
    "NSMotionUsageDescription":
        "MadeGood records wrist motion to count paddle strokes and detect maneuvers.",
    "NSHealthShareUsageDescription":
        "MadeGood reads your heart rate during a session.",
    "NSHealthUpdateUsageDescription":
        "MadeGood runs a workout session so recording continues with the screen off.",
]

let healthKit: Entitlements = .dictionary([
    "com.apple.developer.healthkit": true,
    "com.apple.developer.healthkit.access": [],
])

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
            .debug(name: .debug, xcconfig: "Config/MadeGood.xcconfig"),
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
                "UILaunchScreen": [:],
                "UIRequiredDeviceCapabilities": ["arm64"],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                // Location keeps recording with the screen off; workout-processing lets
                // the phone run its own workout session (iOS 26).
                "UIBackgroundModes": ["location", "workout-processing"],
                // Recordings in Documents are visible in the Files app.
                "UIFileSharingEnabled": true,
                "LSSupportsOpeningDocumentsInPlace": true,
            ]),
            sources: ["App/Sources/**", "Shared/Sources/**"],
            resources: ["App/Resources/**"],
            entitlements: healthKit,
            dependencies: [
                .target(name: "MadeGoodWatch"),
                .external(name: "WaterKit"),
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
            resources: ["Watch/Resources/**"],
            entitlements: healthKit,
            dependencies: [
                .external(name: "WaterKit"),
            ]
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
