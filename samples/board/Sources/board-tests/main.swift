// The Board plugin's tests: `swift run board-tests`. Exit status 0 when all pass.
import BoardPlugin
import Foundation
import VektorPluginTestKit

await modelTests()
await syncTests()
await viewTests()
await test("test/checks.json passes in memory (the script `vektor-plugin test` plays against the built program)") {
    let report = try await runScript(file: pluginFolder.appendingPathComponent("test/checks.json"), folder: pluginFolder, target: .inMemory { setup($0) })
    if !report.passed { throw Failure(description: report.summary + "\n" + report.transcript.joined(separator: "\n")) }
}
await cleanUp()

let suite = Suite.shared
print("\n\(suite.passed) passed, \(suite.failed.count) failed")
if !suite.failed.isEmpty {
    print("failed: \(suite.failed.joined(separator: ", "))")
    exit(1)
}
exit(0)
