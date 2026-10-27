// swift-tools-version:6.0
// The Vektor plugin SDK for Swift. Authors depend on the plugins repository by URL (its root Package.swift exposes the same
// products); this package is where the SDK is built and tested.
//
//   swift build                     the libraries
//   swift run vektor-sdk-tests      the SDK's own tests (a plain executable: no XCTest or Xcode needed)
import PackageDescription

let package = Package(
    name: "VektorPluginSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VektorPlugin", targets: ["VektorPlugin"]),
        .library(name: "VektorPluginTestKit", targets: ["VektorPluginTestKit"]),
    ],
    targets: [
        .target(name: "VektorPlugin"),
        .target(name: "VektorPluginTestKit", dependencies: ["VektorPlugin"]),
        .executableTarget(name: "vektor-sdk-tests", dependencies: ["VektorPlugin", "VektorPluginTestKit"], path: "Tests/SDKTests"),
    ]
)
