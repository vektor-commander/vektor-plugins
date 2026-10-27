// Hello Plugin (Swift) - the compiled plugin template, on the Vektor SDK (plugin API 2).
//
// It shows the two things most plugins do:
//   * a COMMAND in the file menu ("Say Hello"): Vektor sends `invoke`, the handler's answer is shown as a notice;
//   * a VIEW in the sidebar ("Hello"): a block view the plugin describes as data; Vektor draws it and sends back what the
//     user did as events, routed here by their action.
//
// The SDK does the protocol: Content-Length framing by bytes, ids and timeouts, `ping`, `$/cancel`, `shutdown` within the
// grace period, errors in plain words, and patches instead of whole descriptions where it can. docs/reference.md in the
// plugins repository is the protocol itself.
//
// Rules this plugin still follows by itself:
//   * stdout carries messages and nothing else: never `print`. Diagnostics go to stderr (`logToStderr`) or `plugin.log`.
//   * Keep state in `plugin.dataFolder` ($VEKTOR_PLUGIN_DATA), never inside the plugin folder (it is replaced on update).
//   * The program must be signed, or macOS kills it silently: build.sh signs it ad hoc (`codesign -s -`). Sign AFTER the
//     last change.
import VektorPlugin

/// Registers everything the plugin does. The program calls it (Sources/hello/main.swift); so does the test runner.
@MainActor
@discardableResult
public func setup(_ plugin: Plugin) -> Plugin {
    var names: [(id: String, name: String)] = []   // kept only while the plugin runs; a real plugin would save them
    var nextID = 1
    func greeting() -> String { plugin.settings["greeting"]?.stringValue ?? "Hello" }

    // --- The command ----------------------------------------------------------------------------------------------------
    plugin.command("hello") { target, _ in
        // target.items: the items the command was chosen for, each with a `path` (or a `location` when remote).
        InvokeResult(message: "\(greeting())! You chose \(target.items?.count ?? 0) item(s).")
    }

    // --- The view -------------------------------------------------------------------------------------------------------
    let view = plugin.view("hello")

    // The whole view, as it should look now. `show` compares it with what Vektor has and sends a patch when it can. Ids are
    // stable (a name keeps its id), which is what lets the SDK patch instead of resending everything.
    @MainActor func describe() throws {
        try view.show(ViewDescription(header: Header(title: "Hello"), root: .vstack([
            .textField("name", action: "add", placeholder: "Type a name and press Return"),
            .list("names", names.map { entry in
                Block.row(entry.id, title: "\(greeting()), \(entry.name)!", symbol: "person", delete: "remove")
                    .menu([.item(title: "Remove", action: "remove", symbol: "trash", destructive: true)])
            }, placeholder: "Nobody greeted yet."),
        ])))
    }

    view.onOpen { _ in try describe() }
    view.on("add") { event in
        let name = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        names.append((id: "name-\(nextID)", name: name))
        nextID += 1
        try describe()
    }
    view.on("remove") { event in
        names.removeAll { $0.id == event.block }
        try describe()
    }

    // --- Lifecycle ------------------------------------------------------------------------------------------------------
    plugin.onSettingsChanged { _, _ in if view.isOpen { try describe() } }
    plugin.onReady { _ in plugin.log("Hello Plugin started.") }
    plugin.onShutdown { _ in
        // Stop what you started (nothing here). The SDK answers `shutdown` and exits within the grace period.
    }
    return plugin
}
