// swift-tools-version:6.0
// The Vektor plugin SDK for Swift, for depending on this repository by URL:
//
//     .package(url: "https://github.com/vektor-commander/vektor-plugins", from: "<SDK version>")
//     .product(name: "VektorPlugin", package: "vektor-plugins")
//
// The SDK itself lives in sdk/swift (its own Package.swift builds and tests it there); this file only exposes the same
// sources from the repository's root, where SwiftPM looks for a package.
import PackageDescription

let package = Package(
    name: "VektorPluginSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VektorPlugin", targets: ["VektorPlugin"]),
        .library(name: "VektorPluginTestKit", targets: ["VektorPluginTestKit"]),
    ],
    targets: [
        .target(name: "VektorPlugin", path: "sdk/swift/Sources/VektorPlugin"),
        .target(name: "VektorPluginTestKit", dependencies: ["VektorPlugin"], path: "sdk/swift/Sources/VektorPluginTestKit"),
    ]
)
