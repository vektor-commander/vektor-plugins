// swift-tools-version:6.0
// Board: Kanban boards for each workspace, on the Vektor SDK for Swift.
//
//   ./build.sh                 builds the program Vektor runs (bin/board) and signs it ad hoc
//   swift run board-tests      the plugin's own tests: the data model, storage and sync against the SDK's test kit
//
// Three targets: BoardPlugin (everything the plugin does: the model, storage, sync, the controller the views call, and
// `setup`), board (the program: `setup(Plugin()).run()`) and board-tests (a plain executable: the Command Line Tools ship
// neither XCTest nor Swift Testing).
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
    name: "BoardPlugin",
    platforms: [.macOS(.v13)],
    dependencies: [sdk],
    targets: [
        .target(name: "BoardPlugin", dependencies: [.product(name: "VektorPlugin", package: sdkPackage)]),
        .executableTarget(name: "board", dependencies: ["BoardPlugin", .product(name: "VektorPlugin", package: sdkPackage)]),
        .executableTarget(
            name: "board-tests",
            dependencies: ["BoardPlugin", .product(name: "VektorPlugin", package: sdkPackage), .product(name: "VektorPluginTestKit", package: sdkPackage)]),
    ]
)
