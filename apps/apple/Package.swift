// swift-tools-version: 6.2
import PackageDescription

// Compile the sync cores (private Voyage sync and session upload) and their synthetic
// tests without requiring an iOS simulator.
let package = Package(
    name: "MadeGoodPrivateVoyageSync",
    platforms: [.macOS(.v15), .iOS("26.0")],
    dependencies: [
        .package(path: "../../packages/WaterKit"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.4"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
    ],
    targets: [
        .target(
            name: "PrivateVoyageSync",
            dependencies: [
                "WaterKit",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ],
            path: "App/Sources",
            sources: ["PrivateVoyageSync/Core", "SessionSync/Core"]
        ),
        .testTarget(name: "PrivateVoyageSyncTests", dependencies: ["PrivateVoyageSync", "WaterKit"]),
        .testTarget(name: "SessionSyncTests", dependencies: ["PrivateVoyageSync", "WaterKit"]),
    ]
)
