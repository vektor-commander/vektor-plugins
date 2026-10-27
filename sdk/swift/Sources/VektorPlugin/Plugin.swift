import Foundation

// The protocol core: one `Plugin` per program. It reads framed messages from stdin, answers Vektor's requests through the
// handlers you register, sends your requests with ids and timeouts, and handles the parts every plugin gets wrong once:
// `ping`, `$/cancel`, `startup` state, `shutdown` with its grace period, end of input, and errors in plain words.
//
//     import VektorPlugin
//     let plugin = Plugin()
//     plugin.command("hello") { target, _ in "Hello! You chose \(target.items?.count ?? 0) item(s)." }
//     plugin.run()      // never returns
//
// Everything runs on the main actor, one message after another; a handler that awaits (a dialog, a storage call) lets the
// next message in meanwhile, so `ping` is always answered.

/// Where the bytes go: stdin/stdout for a real plugin, an in-memory pair in the test kit.
@MainActor
public protocol PluginTransport: AnyObject {
    func write(_ bytes: Data)
    /// Starts delivering input: every chunk to `onData`, then `onEnd` once when the input ends (Vektor is gone).
    func start(onData: @escaping @MainActor (Data) -> Void, onEnd: @escaping @MainActor () -> Void)
    /// Ends the plugin with `code` (everything written is already flushed: writes are synchronous).
    func exit(_ code: Int32)
}

/// stdin and stdout. stdout carries messages and NOTHING else. The SDK keeps a private copy of stdout for messages and
/// points file descriptor 1 at stderr, so a stray `print` (yours or a library's) becomes a line in the plugin's Log instead
/// of breaking the framing, which would end the plugin in Vektor. Write your own lines with `logToStderr` or `plugin.log`.
@MainActor
public final class StdioTransport: PluginTransport {
    public init() {}

    /// Taken once, before anything else is written: a duplicate of the real stdout, after which descriptor 1 is stderr.
    private static let messages: FileHandle = {
        fflush(stdout)
        let copy = dup(STDOUT_FILENO)
        guard copy >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return FileHandle.standardOutput }
        setvbuf(stdout, nil, _IOLBF, 0)   // a `print` reaches the Log line by line, not when the plugin exits
        return FileHandle(fileDescriptor: copy, closeOnDealloc: false)
    }()

    public func write(_ bytes: Data) {
        Self.messages.write(bytes)
    }

    public func start(onData: @escaping @MainActor (Data) -> Void, onEnd: @escaping @MainActor () -> Void) {
        let deliver: @Sendable (Data) -> Void = { data in DispatchQueue.main.async { MainActor.assumeIsolated { onData(data) } } }
        let end: @Sendable () -> Void = { DispatchQueue.main.async { MainActor.assumeIsolated { onEnd() } } }
        let reader = Thread {
            let input = FileHandle.standardInput
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { end(); return }
                deliver(chunk)
            }
        }
        reader.start()
    }

    public func exit(_ code: Int32) {
        Foundation.exit(code)
    }
}

/// What a request handler gets besides its parameters.
public struct RequestContext: Sendable {
    public let id: JSONValue
    public let method: String
    /// Whether Vektor sent `$/cancel` for this request (or the plugin is stopping).
    public var isCancelled: Bool { Task.isCancelled }
    /// Throws a cancelled `PluginError` once the request was cancelled. Call it between steps of long work.
    public func checkCancellation() throws {
        if Task.isCancelled { throw PluginError.cancelled() }
    }
}

/// The first id of the plugin's own requests (the reference: "start yours at 1000 or so").
public let firstRequestID = 1000

@MainActor
public final class Plugin: NotificationSink {
    /// The plugin API written on every message: what Vektor writes to this plugin (its manifest's), else
    /// `$VEKTOR_PLUGIN_API`, else 2.
    public private(set) var api: Int
    /// Every setting's value (defaults filled in), as of the latest `startup`, `settingsChanged` or `settings/get`.
    public var settings: [String: JSONValue] = [:]
    /// The active workspace.
    public var workspace: Workspace?
    /// `startup`'s parameters once it arrived.
    public private(set) var startupParams: StartupParams?
    /// How long `onShutdown` handlers may take before the plugin leaves anyway, in seconds (Vektor's grace is about 2 s).
    public var shutdownGrace: Double = 1.5
    /// Default timeout of the plugin's own requests, in seconds (dialogs and confirmations wait for the user: none).
    public var requestTimeout: Double = 60
    /// Where the SDK's own diagnostics go. Default: stderr (the plugin's Log in Vektor).
    public var diagnostics: (String) -> Void = logToStderr

    private let transport: PluginTransport
    private var reader = MessageReader()
    private var nextID = firstRequestID
    private var pending: [Int: (method: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var requestHandlers: [String: @MainActor (JSONValue, RequestContext) async throws -> JSONValue] = [:]
    private var notificationHandlers: [String: [@MainActor (JSONValue) async throws -> Void]] = [:]
    private var commands: [String: @MainActor (InvokeTarget, RequestContext) async throws -> InvokeResult] = [:]
    private var startupHandlers: [@MainActor (StartupParams) async throws -> Void] = []
    private var readyHandlers: [@MainActor (StartupParams) async throws -> Void] = []
    private var shutdownHandlers: [@MainActor (String) async -> Void] = []
    private var settingsHandlers: [@MainActor ([String: JSONValue], Workspace?) async throws -> Void] = []
    private var workspaceHandlers: [@MainActor (Workspace?) async throws -> Void] = []
    private var views: [String: ViewState] = [:]
    private var bridges: [String: WebBridge] = [:]
    private var sidebars: [String: SidebarItems] = [:]
    private var started = false
    private var stopping = false
    private var left = false

    public init(transport: PluginTransport? = nil, api: Int? = nil) {
        self.transport = transport ?? StdioTransport()
        let fromEnvironment = ProcessInfo.processInfo.environment["VEKTOR_PLUGIN_API"].flatMap(Int.init)
        self.api = api ?? fromEnvironment.flatMap { $0 >= 1 ? $0 : nil } ?? 2
    }

    // MARK: Registering handlers

    /// Runs when `startup` arrives, before it is answered. `settings`, `workspace` and `startupParams` are already set.
    @discardableResult
    public func onStartup(_ handler: @escaping @MainActor (StartupParams) async throws -> Void) -> Self {
        startupHandlers.append(handler)
        return self
    }

    /// Runs right after `startup` has been answered: send a first `view/update`, sidebar items or a badge here.
    @discardableResult
    public func onReady(_ handler: @escaping @MainActor (StartupParams) async throws -> Void) -> Self {
        readyHandlers.append(handler)
        return self
    }

    /// Runs on `shutdown` (after it is answered) and at the end of input: stop what you started. Bounded by `shutdownGrace`.
    @discardableResult
    public func onShutdown(_ handler: @escaping @MainActor (String) async -> Void) -> Self {
        shutdownHandlers.append(handler)
        return self
    }

    /// `settingsChanged`. `settings` and `workspace` are already updated.
    @discardableResult
    public func onSettingsChanged(_ handler: @escaping @MainActor ([String: JSONValue], Workspace?) async throws -> Void) -> Self {
        settingsHandlers.append(handler)
        return self
    }

    /// The active workspace changed: `workspace/changed` (API 2), or a `settingsChanged` naming another workspace.
    @discardableResult
    public func onWorkspaceChanged(_ handler: @escaping @MainActor (Workspace?) async throws -> Void) -> Self {
        workspaceHandlers.append(handler)
        return self
    }

    /// A command of the manifest (`invoke`). Return `"text"` for a short notice or `InvokeResult()` for none. Throw a
    /// `PluginError` to show its message in an alert.
    @discardableResult
    public func command(_ name: String, _ handler: @escaping @MainActor (InvokeTarget, RequestContext) async throws -> InvokeResult) -> Self {
        commands[name] = handler
        return self
    }

    /// Any request method from Vektor (`decorations/get`, `info/get`, `footer/get`, or one this SDK does not type).
    @discardableResult
    public func onRequest(_ method: String, _ handler: @escaping @MainActor (JSONValue, RequestContext) async throws -> JSONValue) -> Self {
        requestHandlers[method] = handler
        return self
    }

    /// Any notification from Vektor. Several handlers may listen to one method.
    @discardableResult
    public func onNotification(_ method: String, _ handler: @escaping @MainActor (JSONValue) async throws -> Void) -> Self {
        notificationHandlers[method, default: []].append(handler)
        return self
    }

    @discardableResult
    public func onDecorations(_ handler: @escaping @MainActor (DecorationsGetParams, RequestContext) async throws -> DecorationsGetResult) -> Self {
        onRequest(Method.decorationsGet) { params, context in try JSONValue(encoding: try await handler(try params.decode(), context)) }
    }
    @discardableResult
    public func onInfo(_ handler: @escaping @MainActor (InfoGetParams, RequestContext) async throws -> InfoGetResult) -> Self {
        onRequest(Method.infoGet) { params, context in try JSONValue(encoding: try await handler(try params.decode(), context)) }
    }
    @discardableResult
    public func onFooter(_ handler: @escaping @MainActor (FooterGetParams, RequestContext) async throws -> FooterGetResult) -> Self {
        onRequest(Method.footerGet) { params, context in try JSONValue(encoding: try await handler(try params.decode(), context)) }
    }
    @discardableResult
    public func onProcessOutput(_ handler: @escaping @MainActor (ProcessOutputParams) async throws -> Void) -> Self {
        onNotification(Method.processOutput) { params in try await handler(try params.decode()) }
    }
    @discardableResult
    public func onProcessExited(_ handler: @escaping @MainActor (ProcessExitedParams) async throws -> Void) -> Self {
        onNotification(Method.processExited) { params in try await handler(try params.decode()) }
    }

    /// The state of a view the plugin describes: its description, revision, patches and event routing.
    public func view(_ id: String) -> ViewState {
        if let existing = views[id] { return existing }
        let state = ViewState(view: id, sink: self)
        views[id] = state
        return state
    }

    /// The bridge to the plugin's web pages showing view `id`.
    public func web(_ view: String) -> WebBridge {
        if let existing = bridges[view] { return existing }
        let bridge = WebBridge(plugin: self, view: view)
        bridges[view] = bridge
        return bridge
    }

    /// The items listed under sidebar entry `entry` (API 2).
    public func sidebar(_ entry: String) -> SidebarItems {
        if let existing = sidebars[entry] { return existing }
        let items = SidebarItems(plugin: self, entry: entry)
        sidebars[entry] = items
        return items
    }

    /// The storage service on a place: a `place` setting's handle.
    public func storage(_ place: PlaceHandle) -> Storage { Storage(plugin: self, place: place.place) }
    public func storage(place: String) -> Storage { Storage(plugin: self, place: place) }

    /// A `place` setting's current handle (nil until the user chose a folder).
    public func place(_ key: String) -> PlaceHandle? { try? settings[key]?.decode(PlaceHandle.self) }

    /// The data folder: `startup`'s `dataFolder`, else `$VEKTOR_PLUGIN_DATA`.
    public var dataFolder: String? { startupParams?.dataFolder ?? ProcessInfo.processInfo.environment["VEKTOR_PLUGIN_DATA"] }

    // MARK: Running

    /// Starts reading messages. Call it once, after registering handlers (`run()` does).
    public func start() {
        guard !started else { return }
        started = true
        transport.start(onData: { [weak self] chunk in self?.receive(chunk) }, onEnd: { [weak self] in self?.stop(reason: "endOfInput") })
    }

    /// Starts and serves until the plugin leaves. Never returns.
    public func run() -> Never {
        start()
        dispatchMain()
    }

    /// Feeds bytes as if they came from stdin.
    public func receive(_ chunk: Data) {
        let messages: [JSONValue]
        do {
            messages = try reader.push(chunk)
        } catch {
            diagnostics("vektor-sdk: \(error) Stopping.")
            leave(1)
            return
        }
        for message in messages { dispatch(message) }
    }

    private func dispatch(_ message: JSONValue) {
        if let api = message["api"]?.intValue, api >= 1 { self.api = api }
        let params = message["params"] ?? [:]
        if let method = message["method"]?.stringValue {
            // A message with an id is a request and is answered, even one of a method Vektor usually sends as a notification.
            if let id = message["id"], id != .null { handleRequest(id, method, params) } else { handleNotification(method, params) }
            return
        }
        guard let id = message["id"]?.intValue, let waiting = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            waiting.continuation.resume(throwing: PluginError(
                error["message"]?.stringValue ?? "Vektor refused the request.", code: error["code"]?.stringValue, data: error["data"], method: waiting.method))
        } else {
            waiting.continuation.resume(returning: message["result"] ?? [:])
        }
    }

    private func handleRequest(_ id: JSONValue, _ method: String, _ params: JSONValue) {
        switch method {
        case Method.ping:
            reply(id, [:])
            return
        case Method.shutdown:
            reply(id, [:])
            stop(reason: params["reason"]?.stringValue ?? "quit")
            return
        case Method.startup:
            if let decoded = try? params.decode(StartupParams.self) { startupParams = decoded }
            settings = params["settings"]?.objectValue ?? [:]
            workspace = try? params["workspace"]?.decode(Workspace.self)
        default:
            break
        }
        let key = id.jsonText
        let context = RequestContext(id: id, method: method)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.answer(method, params, context)
                self.reply(id, result)
            } catch {
                self.replyError(id, error)
                self.inFlight[key] = nil
                return
            }
            self.inFlight[key] = nil
            if method == Method.startup, let startup = self.startupParams {
                for handler in self.readyHandlers {
                    do { try await handler(startup) } catch { self.report("a ready handler failed", error) }
                }
            }
        }
        inFlight[key] = task
    }

    private func answer(_ method: String, _ params: JSONValue, _ context: RequestContext) async throws -> JSONValue {
        switch method {
        case Method.startup:
            if let startup = startupParams { for handler in startupHandlers { try await handler(startup) } }
            return [:]
        case Method.invoke:
            let command = params["command"]?.stringValue ?? ""
            guard let handler = commands[command] else { throw PluginError("This plugin has no command “\(command)”.") }
            let target = (try? params["target"]?.decode(InvokeTarget.self)) ?? InvokeTarget()
            return try JSONValue(encoding: try await handler(target, context))
        default:
            if let handler = requestHandlers[method] { return try await handler(params, context) }
            if Method.vektorNotifications.contains(method) || notificationHandlers[method] != nil {
                await notification(method, params)
                return [:]
            }
            throw PluginError("This plugin does not handle “\(method)”.")
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        if method == Method.cancel {
            if let id = params["id"] { inFlight[id.jsonText]?.cancel() }
            return
        }
        Task { @MainActor [weak self] in await self?.notification(method, params) }
    }

    private func notification(_ method: String, _ params: JSONValue) async {
        do {
            switch method {
            case Method.settingsChanged:
                settings = params["settings"]?.objectValue ?? [:]
                let before = workspace
                let after: Workspace? = params["workspace"] == nil ? before : try? params["workspace"]?.decode(Workspace.self)
                for handler in settingsHandlers { try await handler(settings, after) }
                if before?.id != after?.id { await applyWorkspace(after) }
            case Method.workspaceChanged:
                await applyWorkspace(try? params.decode(Workspace.self))
            case Method.viewOpened, Method.viewClosed, Method.viewEvent, Method.viewRefused:
                if let view = params["view"]?.stringValue, let state = views[view] { try await state.receive(method, params) }
            case Method.webMessage:
                if let view = params["view"]?.stringValue, let bridge = bridges[view] {
                    await bridge.receive(WebMessageParams(view: view, block: params["block"]?.stringValue, message: params["message"] ?? .null))
                }
            default:
                break
            }
            for handler in notificationHandlers[method] ?? [] { try await handler(params) }
        } catch {
            report("a “\(method)” handler failed", error)
        }
    }

    private func applyWorkspace(_ next: Workspace?) async {
        if workspace == next { return }
        workspace = next
        for handler in workspaceHandlers {
            do { try await handler(next) } catch { report("a workspace handler failed", error) }
        }
        for items in sidebars.values {
            do { try await items.refresh() } catch { report("sidebar items", error) }
        }
    }

    /// Leaves: cancels work in flight, runs the shutdown handlers for at most `shutdownGrace`, and exits.
    public func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        for task in inFlight.values { task.cancel() }
        for (_, waiting) in pending { waiting.continuation.resume(throwing: PluginError.cancelled("The plugin is stopping.")) }
        pending.removeAll()
        let handlers = shutdownHandlers
        Task { @MainActor [weak self] in
            for handler in handlers { await handler(reason) }
            self?.leave(0)
        }
        let grace = shutdownGrace
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.left else { return }
                self.diagnostics("vektor-sdk: shutdown handlers took longer than \(grace) s; leaving anyway.")
                self.leave(0)
            }
        }
    }

    private func leave(_ code: Int32) {
        guard !left else { return }
        left = true
        transport.exit(code)
    }

    // MARK: Sending

    private func write(_ message: [String: JSONValue]) {
        var full = message
        full["api"] = .int(api)
        do {
            transport.write(try Framing.encode(.object(full)))
        } catch {
            diagnostics("vektor-sdk: \(error)")
        }
    }

    private func reply(_ id: JSONValue, _ result: JSONValue) {
        write(["id": id, "result": result])
    }

    private func replyError(_ id: JSONValue, _ error: Error) {
        if let error = error as? PluginError {
            var body: [String: JSONValue] = ["message": .string(error.message)]
            if let code = error.code, error.method == nil, code != "cancelled" { body["code"] = .string(code) }
            write(["id": id, "error": .object(body)])
        } else if error is CancellationError {
            write(["id": id, "error": ["message": "Cancelled."]])
        } else {
            report("a request handler failed", error)
            write(["id": id, "error": ["message": .string(genericFailureMessage)]])
        }
    }

    private func report(_ what: String, _ error: Error) {
        diagnostics("vektor-sdk: \(what): \(error)")
    }

    /// Sends a notification.
    public func notify(_ method: String, _ params: JSONValue) {
        write(["method": .string(method), "params": params])
    }

    /// Sends a request and returns its result. Throws a `PluginError`: Vektor's refusal (with `code` and `data` when it gave
    /// them, and `method`), a timeout, or a cancellation. `timeout` in seconds; 0 waits for ever (the default for
    /// `dialog/show` and `confirm`, which wait for the user).
    public func request(_ method: String, _ params: JSONValue = [:], timeout: Double? = nil) async throws -> JSONValue {
        guard !stopping else { throw PluginError.cancelled("The plugin is stopping.") }
        let id = nextID
        nextID += 1
        let waitsForUser = method == Method.dialogShow || method == Method.confirm
        let seconds = timeout ?? (waitsForUser ? 0 : requestTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = (method, continuation)
                write(["id": .int(id), "method": .string(method), "params": params])
                if seconds > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                        MainActor.assumeIsolated {
                            self?.pending.removeValue(forKey: id)?.continuation.resume(throwing: PluginError.timeout(method, seconds: seconds))
                        }
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.pending.removeValue(forKey: id)?.continuation.resume(throwing: PluginError.cancelled()) }
            }
        }
    }

    /// Requests of the plugin still waiting for an answer.
    public var pendingRequests: Int { pending.count }

    // MARK: Services, typed

    /// A line in the plugin's Log in Vektor.
    public func log(_ message: String, level: LogLevel = .info) { notify(Method.log, ["level": .string(level.rawValue), "message": .string(message)]) }
    public func toast(_ message: String) { notify(Method.toast, ["message": .string(message)]) }
    public func alert(title: String, message: String) { notify(Method.alert, ["title": .string(title), "message": .string(message)]) }
    public func confirm(_ params: ConfirmParams) async throws -> Bool {
        try await request(Method.confirm, try JSONValue(encoding: params))["confirmed"]?.boolValue == true
    }
    public func copyText(_ text: String) { notify(Method.clipboardWriteText, ["text": .string(text)]) }
    /// Asks Vektor for the settings now; also updates `settings` and `workspace`.
    public func getSettings() async throws -> SettingsGetResult {
        let result = try await request(Method.settingsGet, [:]).decode(SettingsGetResult.self)
        settings = result.settings
        workspace = result.workspace
        return result
    }
    /// A status line under a setting; empty `text` clears it.
    public func setStatus(_ params: SettingsStatusParams) { if let value = try? JSONValue(encoding: params) { notify(Method.settingsStatus, value) } }
    public func showDialog(_ params: DialogShowParams) async throws -> DialogShowResult {
        try await request(Method.dialogShow, try JSONValue(encoding: params)).decode(DialogShowResult.self)
    }
    public func openURL(_ url: String) async throws { _ = try await request(Method.openURL, ["url": .string(url)]) }
    public func navigate(_ path: String, placement: String? = nil) async throws {
        var params: [String: JSONValue] = ["path": .string(path)]
        if let placement { params["placement"] = .string(placement) }
        _ = try await request(Method.navigate, .object(params))
    }
    public func reveal(_ path: String) async throws { _ = try await request(Method.reveal, ["path": .string(path)]) }
    public func startProcess(_ params: ProcessStartParams) async throws -> String {
        try await request(Method.processStart, try JSONValue(encoding: params))["processID"]?.stringValue ?? ""
    }
    public func stopProcess(_ processID: String) async throws { _ = try await request(Method.processStop, ["processID": .string(processID)]) }
    public func readSecret(_ key: String) async throws -> String { try await request(Method.secretsRead, ["key": .string(key)])["value"]?.stringValue ?? "" }
    public func writeSecret(_ key: String, _ value: String) async throws { _ = try await request(Method.secretsWrite, ["key": .string(key), "value": .string(value)]) }
    public func deleteSecret(_ key: String) async throws { _ = try await request(Method.secretsDelete, ["key": .string(key)]) }
    /// A sidebar entry's badge; neither a count above zero nor a text clears it.
    public func setBadge(_ params: SidebarBadgeParams) { if let value = try? JSONValue(encoding: params) { notify(Method.sidebarBadge, value) } }
    /// Your decorations went stale: for these paths, or all.
    public func decorationsChanged(_ paths: [String]? = nil) {
        notify(Method.decorationsChanged, paths.map { ["paths": .array($0.map(JSONValue.string))] } ?? [:])
    }
    public func footerChanged() { notify(Method.footerChanged, [:]) }
}
