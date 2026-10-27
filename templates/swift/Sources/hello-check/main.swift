// Plays test/checks.json against the plugin in memory: `swift run hello-check`. It is the same script
// `vektor-plugin test . test/checks.json` plays against the built program; this runs without building or signing, and with
// only the Command Line Tools. Add checks of your own below with `TestHost`.
import Foundation
import HelloPlugin
import VektorPlugin
import VektorPluginTestKit

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let report = try await runScript(file: folder.appendingPathComponent("test/checks.json"), folder: folder, target: .inMemory { setup($0) })
print(report.summary)
if !report.passed {
    print(report.transcript.joined(separator: "\n"))
    exit(1)
}
