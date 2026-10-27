import Foundation

// MARK: - Sidebar items

/// Items under one of the plugin's sidebar entries (API 2): boards, projects. Vektor remembers them per workspace and draws
/// them without starting the plugin; send them again when they change and after a workspace switch. With a provider set, the
/// SDK does the second part for you.
///
///     plugin.sidebar("boards").provide { workspace in boards.map { SidebarItem(id: $0.id, title: $0.name) } }
///     plugin.sidebar("boards").onMenu("rename") { item, _, _ in … }      // a `sidebarItem` menu's command
@MainActor
public final class SidebarItems {
    /// At most this many items under one entry (Vektor's protection limit).
    public static let maxItems = 2000

    public let entry: String
    /// What was sent last.
    public private(set) var items: [SidebarItem] = []
    private unowned let plugin: Plugin
    private var provider: (@MainActor (Workspace?) async throws -> [SidebarItem])?

    init(plugin: Plugin, entry: String) {
        self.plugin = plugin
        self.entry = entry
    }

    /// Sends the items, in this order (`[]` clears them), after checking what Vektor would refuse.
    public func set(_ items: [SidebarItem]) throws {
        guard items.count <= Self.maxItems else { throw PluginError("A sidebar entry can list at most \(Self.maxItems) items.") }
        var seen = Set<String>()
        for item in items {
            guard !item.id.isEmpty, !item.title.isEmpty else { throw PluginError("Every sidebar item needs an “id” and a “title”.") }
            guard seen.insert(item.id).inserted else { throw PluginError("The sidebar item “\(item.id)” is listed twice.") }
        }
        self.items = items
        plugin.notify(Method.sidebarItems, ["entry": .string(entry), "items": try JSONValue(encoding: items)])
    }

    public func clear() throws { try set([]) }

    /// Where the items come from: asked once the plugin is ready and again after every workspace change.
    public func provide(_ provider: @escaping @MainActor (Workspace?) async throws -> [SidebarItem]) {
        self.provider = provider
        plugin.onReady { [weak self] _ in try await self?.refresh() }
        if plugin.startupParams != nil { Task { @MainActor [weak self] in try? await self?.refresh() } }
    }

    /// Asks the provider again and sends what it says.
    public func refresh() async throws {
        if let provider { try set(try await provider(plugin.workspace)) }
    }

    /// A command of a `sidebarItem` menu for this entry: the handler gets the item's id.
    public func onMenu(_ command: String, _ handler: @escaping @MainActor (String, InvokeTarget, RequestContext) async throws -> InvokeResult) {
        let entry = self.entry
        plugin.command(command) { target, context in
            if let other = target.entry, other != entry { throw PluginError("“\(command)” is not a command of the sidebar entry “\(other)”.") }
            guard let item = target.item else { throw PluginError("“\(command)” needs a sidebar item.") }
            return try await handler(item, target, context)
        }
    }
}

// MARK: - Per-workspace state

/// One value per workspace, kept in the plugin's data folder (`<name>.workspaces.json`, written atomically), so "the board
/// this workspace had open" survives a restart. `Plugin.workspace` is always the active workspace; `onWorkspaceChanged`
/// runs on a switch.
@MainActor
public final class WorkspaceState<Value: Codable> {
    /// The key used when there is no active workspace.
    public static var noWorkspace: String { "" }

    public let name: String
    private unowned let plugin: Plugin
    private let initial: Value
    private let folder: String?
    private var values: [String: Value] = [:]
    private var loaded = false

    public init(plugin: Plugin, name: String, initial: Value, folder: String? = nil) throws {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw PluginError("A workspace state name is letters, digits, “.”, “-” and “_”.")
        }
        self.plugin = plugin
        self.name = name
        self.initial = initial
        self.folder = folder
    }

    private var file: URL? {
        (folder ?? plugin.dataFolder).map { URL(fileURLWithPath: $0).appendingPathComponent("\(name).workspaces.json") }
    }

    private struct Document: Codable {
        var version: Int
        var workspaces: [String: Value]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file), let document = try? JSONDecoder().decode(Document.self, from: data) else { return }
        values = document.workspaces
    }

    private func key(_ workspace: Workspace?) -> String { workspace?.id ?? Self.noWorkspace }

    /// The value of `workspace` (the active one by default).
    public func get(_ workspace: Workspace?) -> Value {
        load()
        return values[key(workspace)] ?? initial
    }

    /// The active workspace's value; setting it saves.
    public var current: Value {
        get { get(plugin.workspace) }
        set { try? set(newValue, for: plugin.workspace) }
    }

    public func set(_ value: Value, for workspace: Workspace?) throws {
        load()
        values[key(workspace)] = value
        try save()
    }

    /// Forgets a workspace's value (one that was deleted).
    public func forget(_ workspace: Workspace) throws {
        load()
        values[key(workspace)] = nil
        try save()
    }

    /// Writes every workspace's value: to a temporary file, then renamed over the real one, so a crash never leaves half.
    public func save() throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(Document(version: 1, workspaces: values)) + Data("\n".utf8)).write(to: file, options: .atomic)
    }
}

// MARK: - Web views

/// The plugin's side of the web view bridge (API 2). A page posts with `vektor.post(message)` and the plugin receives
/// `web/message`; the plugin sends `web/post` and the page's `vektor.onmessage` receives it. This helper adds the convention
/// the page side (`sdk/web/vektor-bridge.js`) shares: a message is an object with a `type` (handlers are routed by it); a
/// page's request carries `requestId`, and what the handler returns goes back as `{type: "reply", replyTo, result}` (or
/// `{type: "reply", replyTo, error}` in plain words).
///
///     plugin.web("sketch").on("load") { _, _ in ["strokes": strokes] }
///     plugin.web("sketch").on("save") { message, _ in strokes = message["strokes"] ?? []; return nil }
@MainActor
public final class WebBridge {
    /// The largest message either way (Vektor's limit).
    public static let maxMessageBytes = 1024 * 1024

    public let view: String
    private unowned let plugin: Plugin
    private var handlers: [String: @MainActor (JSONValue, WebMessageParams) async throws -> JSONValue?] = [:]
    private var fallback: (@MainActor (JSONValue, WebMessageParams) async throws -> JSONValue?)?

    init(plugin: Plugin, view: String) {
        self.plugin = plugin
        self.view = view
    }

    /// Handles page messages whose `type` is `type`. For a request, the return value is the reply.
    public func on(_ type: String, _ handler: @escaping @MainActor (JSONValue, WebMessageParams) async throws -> JSONValue?) {
        handlers[type] = handler
    }

    /// Handles messages no `on` claims.
    public func onAny(_ handler: @escaping @MainActor (JSONValue, WebMessageParams) async throws -> JSONValue?) {
        fallback = handler
    }

    /// Sends `message` to this plugin's pages showing the view — all of them, or only the `web` block `block`.
    public func post(_ message: JSONValue, block: String? = nil) throws {
        let size = message.jsonData.count
        guard size <= Self.maxMessageBytes else {
            throw PluginError("A message to a page is at most 1 MB; this one is \((size + 1023) / 1024) KB.")
        }
        var params: [String: JSONValue] = ["view": .string(view), "message": message]
        if let block { params["block"] = .string(block) }
        plugin.notify(Method.webPost, .object(params))
    }

    /// Called by the plugin for this view's `web/message`.
    func receive(_ params: WebMessageParams) async {
        let message = params.message
        let type = message["type"]?.stringValue
        let requestID = message["requestId"]
        guard let handler = type.flatMap({ handlers[$0] }) ?? fallback else {
            if let requestID {
                try? post(["type": "reply", "replyTo": requestID, "error": .string("This plugin does not handle “\(type ?? "")”.")], block: params.block)
            }
            return
        }
        do {
            let result = try await handler(message, params)
            if let requestID { try post(["type": "reply", "replyTo": requestID, "result": result ?? .null], block: params.block) }
        } catch {
            if !(error is PluginError) { logToStderr("vektor-sdk: a web message handler failed: \(error)") }
            if let requestID {
                let text = (error as? PluginError)?.message ?? genericFailureMessage
                try? post(["type": "reply", "replyTo": requestID, "error": .string(text)], block: params.block)
            }
        }
    }
}

// MARK: - Version

public enum SDK {
    /// This SDK's own version (it is versioned separately from Vektor).
    public static let version = "0.1.0"
    /// The plugin API this SDK targets (it also speaks to API 1 plugins, which never receive an API 2 message).
    public static let pluginAPI = 2
    /// The oldest Vektor this SDK needs for everything it offers (block views, storage places, web views: plugin API 2).
    public static let minVektor = "1.0.0"
}
