// swift-tools-version: 6.2
import PackageDescription

#if TUIST
    import struct ProjectDescription.PackageSettings

    let packageSettings = PackageSettings(productTypes: [:])
#endif

// Packages the apps depend on. `tuist install` resolves them; reference products in
// Project.swift with `.external(name:)`.
let package = Package(
    name: "MadeGoodDependencies",
    dependencies: [
        .package(path: "../../../packages/WaterKit"),
    ]
)
