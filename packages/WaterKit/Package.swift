// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WaterKit",
    platforms: [
        .iOS("26.0"),
        .watchOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "WaterKit", targets: ["WaterKit"])
    ],
    targets: [
        // Thin C shim over the system zlib (macOS/iOS/watchOS SDKs; zlib1g-dev on Linux).
        .target(
            name: "CZlib",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "WaterKit",
            dependencies: ["CZlib"]
        ),
        .testTarget(
            name: "WaterKitTests",
            dependencies: ["WaterKit"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
