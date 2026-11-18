// swift-tools-version: 6.2
import PackageDescription

#if TUIST
    import struct ProjectDescription.PackageSettings

    // Packages link statically into the apps, so they are never signed on their own;
    // without this an archive asks for a signing certificate for each package target.
    let packageSettings = PackageSettings(
        productTypes: [:],
        baseSettings: .settings(base: ["CODE_SIGNING_ALLOWED": "NO"])
    )
#endif

// Packages the apps depend on. `tuist install` resolves them; reference products in
// Project.swift with `.external(name:)`.
let package = Package(
    name: "MadeGoodDependencies",
    dependencies: [
        .package(path: "../../../packages/WaterKit"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.4"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
    ]
)
