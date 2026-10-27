import Foundation
import VektorPlugin
import VektorPluginTestKit

/// A plugin whose command prints: the test binary itself, started again as a process (see main.swift).
@MainActor
func strayPrintChild() -> Never {
    let plugin = Plugin()
    plugin.command("x") { _, _ in
        print("stray line")      // what an author writes out of habit
        return "done"
    }
    plugin.run()
}

/// stdout carries only messages, even when the plugin `print`s: a real process, since only a real stdout can be broken.
@MainActor
func stdoutTests() async {
    await test("a stray print goes to stderr, never into the message stream") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vektor-sdk-stdout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("child"), withDestinationURL: me)
        let manifest: JSONValue = ["id": "com.example.stdout-test", "name": "stdout", "version": "0.1.0", "api": 2, "executable": "child",
                                   "contributes": ["commands": [["id": "x", "title": "X"]]]]
        try manifest.jsonData.write(to: folder.appendingPathComponent("plugin.json"))
        var options = TestHost.Options()
        options.environment = ["VEKTOR_SDK_TEST_CHILD": "stray-print"]
        let host = try TestHost.spawn(folder: folder, options: options)
        _ = try await host.startup()
        let answer = try await host.request("invoke", ["command": "x", "target": [:]])
        try checkEqual(answer.result?["message"]?.stringValue, "done", host.transcript.joined(separator: "\n"))
        let ping = try await host.request("ping", [:])
        try check(ping.kind == .response, host.transcript.joined(separator: "\n"))
        try check(host.transcript.contains { $0.hasPrefix("stderr:") && $0.contains("stray line") }, host.transcript.joined(separator: "\n"))
        try await host.shutdown()
    }
}
