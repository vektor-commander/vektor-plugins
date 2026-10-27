import Foundation
import VektorPlugin
import VektorPluginTestKit

private func manifest() -> [String: Any] { [
    "settings": ["items": [["key": "greeting", "kind": "text", "label": "Greeting", "default": "Hello"]]],
    "contributes": ["views": [["id": "v", "title": "V", "kind": "blocks"], ["id": "page", "title": "Page", "kind": "web", "entry": "index.html"]]],
] }

@MainActor
private func withHost(_ options: TestHost.Options = TestHost.Options(), setup: (Plugin) -> Void, _ body: (TestHost) async throws -> Void) async throws {
    let host = try TestHost.start(folder: try pluginFolder(manifest()), options: options, setup: setup)
    do {
        try await body(host)
        await host.close()
    } catch {
        await host.close()
        throw error
    }
}

@MainActor
func pluginTests() async {
    await test("answers Vektor may shorten: a cancel without `values` is {}, a bare storage status gets empty defaults") {
        let cancel = try JSONValue.parse(#"{"result":"cancel"}"#).decode(DialogShowResult.self)
        try checkEqual(cancel.submitted, false)
        try checkEqual(cancel.values, [:])
        let submit = try JSONValue.parse(#"{"result":"submit","values":{"name":"Roadmap"}}"#).decode(DialogShowResult.self)
        try checkEqual(submit.values["name"], "Roadmap")
        let bare = try JSONValue.parse(#"{"state":"missing"}"#).decode(StorageStatus.self)
        try checkEqual(bare.state, .missing)
        try checkEqual([bare.label, bare.writes, bare.conditional], ["", "", ""])
        try checkEqual(bare.remote, false)
        let labelled = try JSONValue.parse(#"{"state":"offline","label":"nas"}"#).decode(StorageStatus.self)
        try checkEqual(labelled.label, "nas")
    }

    await test("plugin: startup with defaults and workspace, answered {}, every message carries api") {
        var options = TestHost.Options()
        options.settings = ["greeting": "Ahoj"]
        options.workspace = Workspace(id: "w1", name: "Work")
        try await withHost(options, setup: { plugin in
            plugin.onStartup { params in plugin.log("started for \(params.workspace?.name ?? "") with \(plugin.settings["greeting"]?.stringValue ?? "")") }
        }) { host in
            let answer = try await host.startup()
            try checkEqual(answer.json, ["kind": "response", "id": 1, "result": [:]])
            try await host.waitFor(Expectation(method: "log", match: ["params.message": "started for Work with Ahoj"]))
            try checkEqual(host.plugin?.dataFolder, host.dataFolder.path)
            try check(!host.transcript.contains { $0.contains("without “api”") })
        }
    }

    await test("plugin: the test kit's refuse() is view/refused; the plugin resends the whole description") {
        try await withHost(setup: { plugin in
            let view = plugin.view("v")
            var rows = ["a", "b"]
            @MainActor func draw() throws { try view.show(ViewDescription(root: .list("l", rows.map { Block.row($0, title: $0.uppercased()) }))) }
            view.onOpen { _ in try draw() }
            view.on("flip") { _ in rows.reverse(); try draw() }
        }) { host in
            try await host.startup()
            host.openView("v")
            try await host.waitFor(Expectation(method: "view/update"))
            host.viewEvent("v", "flip")
            try await host.waitFor(Expectation(method: "view/patch", match: ["params.revision": 2]))
            let mark = host.received.count
            let refusal = host.refuse("v", problem: "operation 1 cannot apply.")
            try checkEqual(refusal.kind, .patch)
            try checkEqual(refusal.revision, 1)
            try checkEqual(refusal.refusedRevision, 2)
            try await host.waitFor(Expectation(method: "view/update", match: ["params.description.revision": 3, "params.description.blocks.children.0.id": "b"]), since: mark)
            try check(host.transcript.contains { $0.contains("\"method\":\"view/refused\"") && !$0.contains("\"id\"") }, "sent as a notification")
        }
    }

    await test("plugin: ping; unknown request refused in plain words; a bug becomes the generic message") {
        try await withHost(setup: { plugin in
            plugin.command("boom") { _, _ in throw CocoaError(.fileNoSuchFile) }
            plugin.command("refuse") { _, _ in throw PluginError("That folder is empty.") }
        }) { host in
            try await host.startup()
            try checkEqual(try await host.request("ping").kind, .response)
            try checkEqual(try await host.request("frobnicate").error, ["message": "This plugin does not handle “frobnicate”."])
            try checkEqual(try await host.request("invoke", ["command": "boom", "target": [:]]).error?["message"], .string(genericFailureMessage))
            try check(host.transcript.contains { $0.hasPrefix("stderr: vektor-sdk: a request handler failed") })
            try checkEqual(try await host.request("invoke", ["command": "refuse", "target": [:]]).error?["message"], "That folder is empty.")
        }
    }

    await test("plugin: commands answer a notice or nothing; targets are typed") {
        try await withHost(setup: { plugin in
            plugin.command("count") { target, _ in InvokeResult(message: "\(target.items?.count ?? 0) item(s) in \(target.menu ?? "")") }
            plugin.command("nothing") { _, _ in InvokeResult() }
        }) { host in
            try await host.startup()
            let counted = try await host.request("invoke", ["command": "count", "target": ["menu": "fileItem", "items": [["path": "/a", "name": "a", "isFolder": false]]]])
            try checkEqual(counted.result, ["message": "1 item(s) in fileItem"])
            try checkEqual(try await host.request("invoke", ["command": "nothing", "target": [:]]).result, [:])
            // The target exactly as Vektor sends it from a file's menu: `folder` is the folder's PATH (a string), not an item.
            let real = try await host.request("invoke", ["command": "count", "target": [
                "menu": "fileItem", "folder": "/Users/me/files",
                "items": [["path": "/Users/me/files/a.txt", "name": "a.txt", "isFolder": false]]]])
            try checkEqual(real.result, ["message": "1 item(s) in fileItem"])
            // A field of a shape this SDK does not expect costs that field only, never the whole target.
            let odd = try await host.request("invoke", ["command": "count", "target": [
                "menu": "fileItem", "connection": "not an object", "items": [["path": "/a", "name": "a", "isFolder": false]]]])
            try checkEqual(odd.result, ["message": "1 item(s) in fileItem"])
        }
    }

    await test("plugin: own requests get ids from 1000; refusals arrive as PluginError with the method") {
        var options = TestHost.Options()
        options.autoReply = ["confirm": ["confirmed": true], "secrets/read": ["$error": "No such secret."]]
        try await withHost(options, setup: { plugin in
            plugin.command("ask") { _, _ in
                let confirmed = try await plugin.confirm(ConfirmParams(title: "Sure?", message: "Really", confirmTitle: "Yes"))
                do { _ = try await plugin.readSecret("token") } catch let error as PluginError {
                    return InvokeResult(message: "\(confirmed) \(error.method ?? "") \(error.message)")
                }
                return "no error"
            }
        }) { host in
            try await host.startup()
            try checkEqual(try await host.request("invoke", ["command": "ask", "target": [:]]).result?["message"], "true secrets/read No such secret.")
            try checkEqual(host.received.filter { $0.kind == .request }.compactMap { $0.id?.intValue }, [1000, 1001])
        }
    }

    await test("plugin: a request of the plugin times out with plain words") {
        try await withHost(setup: { plugin in
            plugin.requestTimeout = 0.05
            plugin.command("wait") { _, _ in
                do { _ = try await plugin.request("navigate", ["path": "/tmp"]) } catch let error as PluginError { return InvokeResult(message: error.message) }
                return "answered"
            }
        }) { host in
            try await host.startup()
            // The test host answers at once, so make it not answer: a method it does not know still gets {}… use a fresh plugin.
            let plugin = Plugin(transport: Silent(), api: 2)
            plugin.requestTimeout = 0.05
            do {
                _ = try await plugin.request("openURL", ["url": "https://example.com"])
                throw Failure(description: "no timeout")
            } catch let error as PluginError {
                try checkEqual(error.message, "Vektor did not answer “openURL” within 0.05 seconds.")
                try checkEqual(error.code, "timeout")
            }
            try checkEqual(plugin.pendingRequests, 0)
        }
    }

    await test("plugin: $/cancel cancels the handler of that request") {
        try await withHost(setup: { plugin in
            plugin.command("slow") { _, context in
                while !context.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
                try context.checkCancellation()
                return "not cancelled"
            }
        }) { host in
            try await host.startup()
            let since = host.received.count
            let id = host.send("invoke", ["command": "slow", "target": [:]])!
            host.send("$/cancel", ["id": .int(id)])
            let answer = try await host.waitFor(Expectation(kind: .failure), since: since, requestID: id)
            try checkEqual(answer.error?["message"], "Cancelled.")
        }
    }

    await test("plugin: shutdown answered first, handlers run, exit; a slow handler is cut at the grace period") {
        try await withHost(setup: { plugin in
            plugin.shutdownGrace = 0.1
            plugin.onShutdown { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) }
        }) { host in
            try await host.startup()
            let started = Date()
            try await host.shutdown()
            try checkEqual(host.exitCode, 0)
            try check(Date().timeIntervalSince(started) < 2)
            try check(host.transcript.contains { $0.contains("leaving anyway") })
        }
    }

    await test("plugin: views opened → described; events routed; patches on change") {
        try await withHost(setup: { plugin in
            var items: [String] = []
            let view = plugin.view("v")
            @MainActor func show() throws {
                try view.show(ViewDescription(header: Header(title: "Items"), root: .list("l", items.enumerated().map { .row("r\($0.offset)", title: $0.element) })))
            }
            view.onOpen { _ in try show() }
            view.on("add") { event in
                items.append(event.text ?? "")
                try show()
            }
        }) { host in
            try await host.startup()
            host.openView("v")
            let update = try await host.waitFor(Expectation(method: "view/update"))
            try checkEqual(update.params.value(at: "description.revision"), 1)
            host.viewEvent("v", "add", ["block": "f", "value": "one"])
            let patch = try await host.waitFor(Expectation(method: "view/patch"))
            try checkEqual(patch.params, ["view": "v", "revision": 2, "ops": [["op": "insert", "parent": "l", "index": 0, "block": ["type": "row", "id": "r0", "title": "one"]]]])
        }
    }

    await test("plugin: workspace/changed updates the workspace, runs handlers, resends sidebar items") {
        var options = TestHost.Options()
        options.workspace = Workspace(id: "w1", name: "One")
        try await withHost(options, setup: { plugin in
            plugin.sidebar("boards").provide { workspace in [SidebarItem(id: "b-\(workspace?.id ?? "none")", title: "Board", badge: "3")] }
            plugin.onWorkspaceChanged { workspace in plugin.log("now in \(workspace?.name ?? "")") }
        }) { host in
            try await host.startup()
            try await host.waitFor(Expectation(method: "sidebar/items", match: ["params.entry": "boards", "params.items.0.id": "b-w1", "params.items.0.badge": "3"]))
            let since = host.received.count
            host.send("workspace/changed", ["id": "w2", "name": "Two"])
            try await host.waitFor(Expectation(method: "log", match: ["params.message": "now in Two"]), since: since)
            try await host.waitFor(Expectation(method: "sidebar/items", match: ["params.items.0.id": "b-w2"]), since: since)
            try checkEqual(host.plugin?.workspace, Workspace(id: "w2", name: "Two"))
            host.send("settingsChanged", ["settings": ["greeting": "Hi"], "workspace": ["id": "w3", "name": "Three"]])
            try await host.waitFor(Expectation(method: "log", match: ["params.message": "now in Three"]), since: since)
        }
    }

    await test("plugin: sidebar items refused before sending; a sidebarItem menu gets its item") {
        try await withHost(setup: { plugin in
            plugin.sidebar("boards").onMenu("rename") { item, _, _ in InvokeResult(message: "renaming \(item)") }
            plugin.command("bad") { _, _ in
                try plugin.sidebar("boards").set([SidebarItem(id: "a", title: "A"), SidebarItem(id: "a", title: "again")])
                return InvokeResult()
            }
        }) { host in
            try await host.startup()
            try checkEqual(try await host.request("invoke", ["command": "rename", "target": ["menu": "sidebarItem", "entry": "boards", "item": "b7"]]).result?["message"], "renaming b7")
            try check(try await host.request("invoke", ["command": "bad", "target": [:]]).error?["message"]?.stringValue?.contains("listed twice") == true)
        }
    }

    await test("plugin: WorkspaceState keeps one value per workspace, on disk") {
        var options = TestHost.Options()
        options.workspace = Workspace(id: "w1", name: "One")
        try await withHost(options, setup: { _ in }) { host in
            try await host.startup()
            let plugin = host.plugin!
            let state = try WorkspaceState<[String: String]>(plugin: plugin, name: "opened", initial: [:])
            state.current = ["board": "b1"]
            plugin.workspace = Workspace(id: "w2", name: "Two")
            try checkEqual(state.current, [:])
            let again = try WorkspaceState<[String: String]>(plugin: plugin, name: "opened", initial: [:])
            try checkEqual(again.get(Workspace(id: "w1", name: "One")), ["board": "b1"])
            try check(FileManager.default.fileExists(atPath: host.dataFolder.appendingPathComponent("opened.workspaces.json").path))
        }
    }

    await test("plugin: web bridge routes by type, answers requests with reply, posts to a block") {
        try await withHost(setup: { plugin in
            var strokes: JSONValue = []
            plugin.web("page").on("load") { _, _ in ["strokes": strokes] }
            plugin.web("page").on("save") { message, _ in strokes = message["strokes"] ?? []; return nil }
            plugin.web("page").on("fail") { _, _ in throw PluginError("Nothing to undo.") }
        }) { host in
            try await host.startup()
            host.webMessage("page", ["type": "save", "strokes": [1, 2]])
            host.webMessage("page", ["type": "load", "requestId": "r1"], block: "canvas")
            let reply = try await host.waitFor(Expectation(method: "web/post", match: ["params.message.replyTo": "r1"]))
            try checkEqual(reply.params, ["view": "page", "block": "canvas", "message": ["type": "reply", "replyTo": "r1", "result": ["strokes": [1, 2]]]])
            host.webMessage("page", ["type": "fail", "requestId": "r2"])
            try await host.waitFor(Expectation(method: "web/post", match: ["params.message.replyTo": "r2", "params.message.error": "Nothing to undo."]))
            host.webMessage("page", ["type": "unknown", "requestId": "r3"])
            try await host.waitFor(Expectation(method: "web/post", match: ["params.message.replyTo": "r3", "params.message.error": ["contains": "does not handle"]]))
        }
    }

    await test("plugin: a message with an id is answered even for a notification method") {
        try await withHost(setup: { _ in }) { host in
            try await host.startup()
            try checkEqual(try await host.request("view/event", ["view": "v", "action": "x"]).kind, .response)
        }
    }
}

/// A transport that never answers.
@MainActor
final class Silent: PluginTransport {
    func write(_ bytes: Data) {}
    func start(onData: @escaping @MainActor (Data) -> Void, onEnd: @escaping @MainActor () -> Void) {}
    func exit(_ code: Int32) {}
}
