// swift-tools-version:6.0
// Hello Plugin (Swift) on the Vektor SDK for Swift.
//
//   ./build.sh                 builds the program Vektor runs (bin/hello) and signs it ad hoc
//   swift run hello-check      plays test/checks.json against the plugin in memory (the SDK's test kit)
//
// Three targets: HelloPlugin (everything the plugin does, in `setup`), hello (the program: `setup(Plugin()).run()`) and
// hello-check (the test runner). Keeping the plugin in a library is what lets a test drive it without starting a process.
import Foundation
import PackageDescription

// Inside the plugins repository the SDK is the repository's own package (two folders up); a copy of this folder anywhere
// else gets it by URL. Either way the package is named after the repository's folder, "vektor-plugins" for a clone.
let repository = URL(fileURLWithPath: Context.packageDirectory + "/../..").standardizedFileURL
let insideRepository = FileManager.default.fileExists(atPath: repository.appendingPathComponent("sdk/swift/Package.swift").path)
let sdk: Package.Dependency = insideRepository
    ? .package(path: "../..")
    : .package(url: "https://github.com/vektor-commander/vektor-plugins", from: "0.1.0")
let sdkPackage = insideRepository ? repository.lastPathComponent : "vektor-plugins"

let package = Package(
    name: "HelloPlugin",
    platforms: [.macOS(.v13)],
    dependencies: [sdk],
    targets: [
        .target(name: "HelloPlugin", dependencies: [.product(name: "VektorPlugin", package: sdkPackage)]),
        .executableTarget(name: "hello", dependencies: ["HelloPlugin", .product(name: "VektorPlugin", package: sdkPackage)]),
        .executableTarget(
            name: "hello-check",
            dependencies: ["HelloPlugin", .product(name: "VektorPlugin", package: sdkPackage), .product(name: "VektorPluginTestKit", package: sdkPackage)]),
    ]
)
