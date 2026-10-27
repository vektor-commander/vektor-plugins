import Foundation
import VektorPlugin
import VektorPluginTestKit

// The SDK's own tests: `swift run vektor-sdk-tests`. Exit status 0 when all pass.
// Started by `stdoutTests` as a plugin process of its own (it needs a real stdout): serve as that plugin instead.
if ProcessInfo.processInfo.environment["VEKTOR_SDK_TEST_CHILD"] == "stray-print" { strayPrintChild() }
await framingTests()
await blockTests()
await viewTests()
await syncTests()
await pluginTests()
await storageTests()
await layoutTests()
await templateTests()
await stdoutTests()

let suite = Suite.shared
print("\n\(suite.passed) passed, \(suite.failed.count) failed")
if !suite.failed.isEmpty {
    print("failed: \(suite.failed.joined(separator: ", "))")
    exit(1)
}
exit(0)
