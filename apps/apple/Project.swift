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

let project = Project(
    name: "MadeGood",
    options: .options(
        automaticSchemesOptions: .enabled(),
        developmentRegion: "en"
    ),
    settings: .settings(
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
            infoPlist: .extendingDefault(with: versionKeys.merging([
                "UILaunchScreen": [:],
                "UIRequiredDeviceCapabilities": ["arm64"],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            ]) { _, new in new }),
            sources: ["App/Sources/**", "Shared/Sources/**"],
            resources: ["App/Resources/**"],
            dependencies: [
                .target(name: "MadeGoodWatch"),
            ]
        ),
        .target(
            name: "MadeGoodWatch",
            destinations: [.appleWatch],
            product: .app,
            productName: "MadeGoodWatch",
            bundleId: "$(BUNDLE_ID_PREFIX).watchkitapp",
            deploymentTargets: watchOSTarget,
            infoPlist: .extendingDefault(with: versionKeys.merging([
                "WKApplication": true,
                "WKCompanionAppBundleIdentifier": "$(BUNDLE_ID_PREFIX)",
                "WKRunsIndependentlyOfCompanionApp": false,
            ]) { _, new in new }),
            sources: ["Watch/Sources/**", "Shared/Sources/**"],
            resources: ["Watch/Resources/**"]
        ),
    ]
)
