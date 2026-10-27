import Foundation

// A small test harness: the SDK's tests run as a plain executable (`swift run vektor-sdk-tests`), because the Command Line
// Tools ship neither XCTest nor Swift Testing. Each test is an async closure on the main actor; a failed check throws.

struct Failure: Error, CustomStringConvertible {
    var description: String
}

@MainActor
final class Suite {
    static let shared = Suite()
    private(set) var passed = 0
    private(set) var failed: [String] = []

    func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("ok   \(name)")
        } catch {
            failed.append(name)
            print("FAIL \(name)\n     \(String(describing: error).replacingOccurrences(of: "\n", with: "\n     "))")
        }
    }
}

@MainActor
func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
    await Suite.shared.test(name, body)
}

func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line, file: String = #fileID) throws {
    if !condition { throw Failure(description: "\(file):\(line): \(message())") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "", line: Int = #line, file: String = #fileID) throws {
    if actual != expected { throw Failure(description: "\(file):\(line): \(message())\n  got:      \(actual)\n  expected: \(expected)") }
}

func checkThrows(_ body: () throws -> Void, matching pattern: String, line: Int = #line, file: String = #fileID) throws {
    do {
        try body()
    } catch {
        let text = String(describing: error)
        if text.range(of: pattern, options: .regularExpression) == nil { throw Failure(description: "\(file):\(line): the error “\(text)” does not match /\(pattern)/") }
        return
    }
    throw Failure(description: "\(file):\(line): expected an error matching /\(pattern)/")
}

@MainActor
func checkThrowsAsync(_ body: @MainActor () async throws -> Void, matching pattern: String, line: Int = #line, file: String = #fileID) async throws {
    do {
        try await body()
    } catch {
        let text = String(describing: error)
        if text.range(of: pattern, options: .regularExpression) == nil { throw Failure(description: "\(file):\(line): the error “\(text)” does not match /\(pattern)/") }
        return
    }
    throw Failure(description: "\(file):\(line): expected an error matching /\(pattern)/")
}

/// The plugins repository (this file is sdk/swift/Tests/SDKTests/Harness.swift).
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// A temporary plugin folder with this manifest.
func pluginFolder(_ manifest: [String: Any]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vektor-sdk-swift-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var full: [String: Any] = ["id": "com.example.sdk-test", "name": "SDK test", "api": 2, "executable": "bin/plugin"]
    full.merge(manifest) { _, new in new }
    try JSONSerialization.data(withJSONObject: full).write(to: folder.appendingPathComponent("plugin.json"))
    return folder
}
