import Foundation
import VektorPlugin
import VektorPluginTestKit

/// The Swift template's own checks.json, against its compiled program, as a process started the way Vektor starts it.
@MainActor
func templateTests() async {
    let template = repository.appendingPathComponent("templates/swift")
    let program = template.appendingPathComponent("bin/hello")
    guard FileManager.default.isExecutableFile(atPath: program.path) else {
        print("skip templates/swift: bin/hello is not built (templates/swift/build.sh)")
        return
    }
    await test("template: templates/swift passes its checks.json as a process") {
        let report = try await runScript(file: template.appendingPathComponent("test/checks.json"), folder: template, target: .process(environment: [:]))
        try check(report.passed, report.summary + "\n" + report.transcript.joined(separator: "\n"))
    }
    await test("test kit: a failing expectation fails the step, with the reason") {
        let script: JSONValue = ["steps": [
            ["name": "startup", "startup": true, "expect": [["kind": "response"]]],
            ["name": "wrong", "send": ["method": "invoke", "params": ["command": "hello", "target": [:]]],
             "expect": [["kind": "response", "match": ["result.message": "nope"]]], "timeout": 0.3],
            ["name": "absent", "send": ["method": "view/opened", "params": ["view": "hello"]], "expect": [["method": "view/update", "absent": true]]],
        ]]
        let report = try await runScript(script, folder: template, target: .process(environment: [:]))
        try check(!report.passed)
        try checkEqual(report.steps.map(\.failures.count), [0, 1, 1])
        try check(report.steps[1].failures[0].contains("did not receive response with result.message = \"nope\""))
        try check(report.steps[2].failures[0].contains("which must not arrive"))
    }
}
