import Foundation
import VektorPlugin

// The test kit: a Vektor stand-in that drives a plugin through `startup`, view events, storage calls and `shutdown` — from
// XCTest, Swift Testing, or a plain executable (`swift run my-plugin-check`, which needs only the Command Line Tools).
//
// It answers the way `vektor-plugin test` does: the same `startup` parameters (setting defaults from plugin.json under your
// settings), `{}` to the plugin's requests unless `autoReply` says otherwise, fake places (`{"$place": "boards"}` in the
// settings) backed by a temporary folder with the storage service's path rules, versions, refusal codes, pages and a
// stand-in Trash. `runScript` plays a `test/checks.json`, so one script runs here and in `vektor-plugin test`.
//
// Two ways to run the plugin:
//   * in memory: `TestHost.start(folder:setup:)`, where `setup(plugin)` registers your handlers (keep them in a function
//     your main.swift calls too: `setup(Plugin()).run()`). Use `plugin.dataFolder`, not the environment.
//   * as a process: `TestHost.spawn(folder:)` starts the compiled program the way Vektor does.

/// The PATH Vektor gives a plugin.
public let pluginPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

/// A message as the test host sees it: `{kind, id?, method?, params?, result?, error?}` — the shape scripts match against.
public struct Envelope: Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case request, notification, response, failure }
    public var kind: Kind
    public var json: JSONValue
    public var id: JSONValue? { json["id"] }
    public var method: String? { json["method"]?.stringValue }
    public var params: JSONValue { json["params"] ?? [:] }
    public var result: JSONValue? { json["result"] }
    public var error: JSONValue? { json["error"] }
    public var description: String { json.jsonText }
}

/// What a step expects: `kind`, `method`, and `match` — paths into the envelope compared with a value or tested with
/// `{"exists": bool}`, `{"contains": …}`, `{"matches": "regex"}`, `{"count": n}`.
public struct Expectation: Sendable {
    public var kind: Envelope.Kind?
    public var method: String?
    public var match: [String: JSONValue]
    public init(kind: Envelope.Kind? = nil, method: String? = nil, match: [String: JSONValue] = [:]) {
        self.kind = kind
        self.method = method
        self.match = match
    }

    public var description: String {
        var parts = [kind?.rawValue ?? "message"]
        if let method { parts.append(method) }
        if !match.isEmpty { parts.append("with " + match.keys.sorted().map { "\($0) = \(match[$0]!.jsonText)" }.joined(separator: ", ")) }
        return parts.joined(separator: " ")
    }
}

// MARK: - Matching (the test host's language)

public enum Matching {
    public static func matches(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
        if case .object(let object) = expected, object.count == 1, let (key, argument) = object.first {
            switch key {
            case "exists": return (actual != nil) == (argument.boolValue ?? true)
            case "contains":
                switch actual {
                case .string(let text)?: return argument.stringValue.map { text.contains($0) } ?? false
                case .array(let items)?: return items.contains(argument)
                default: return false
                }
            case "matches":
                guard case .string(let text)? = actual, let pattern = argument.stringValue,
                    let expression = try? NSRegularExpression(pattern: pattern)
                else { return false }
                return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            case "count":
                guard let wanted = argument.numberValue else { return false }
                switch actual {
                case .array(let items)?: return Double(items.count) == wanted
                case .object(let items)?: return Double(items.count) == wanted
                case .string(let text)?: return Double(text.count) == wanted
                default: return false
                }
            default: break
            }
        }
        guard let actual else { return false }
        return actual == expected
    }

    public static func matches(_ envelope: Envelope, _ expectation: Expectation, requestID: Int? = nil) -> Bool {
        if let kind = expectation.kind, kind != envelope.kind { return false }
        if let method = expectation.method, envelope.method != method { return false }
        if let kind = expectation.kind, kind == .response || kind == .failure, let requestID, envelope.id?.intValue != requestID { return false }
        for (path, expected) in expectation.match where !matches(envelope.json.value(at: path), expected) { return false }
        return true
    }
}

// MARK: - The in-memory pipe

@MainActor
final class MemoryTransport: PluginTransport {
    var toHost: @MainActor (Data) -> Void = { _ in }
    var exited: @MainActor (Int32) -> Void = { _ in }
    private var onData: (@MainActor (Data) -> Void)?
    private var onEnd: (@MainActor () -> Void)?
    private var gone = false

    func write(_ bytes: Data) {
        guard !gone else { return }
        let deliver = toHost
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(bytes) } }
    }
    func start(onData: @escaping @MainActor (Data) -> Void, onEnd: @escaping @MainActor () -> Void) {
        self.onData = onData
        self.onEnd = onEnd
    }
    func exit(_ code: Int32) {
        guard !gone else { return }
        gone = true
        let exited = self.exited
        DispatchQueue.main.async { MainActor.assumeIsolated { exited(code) } }
    }
    func deliver(_ bytes: Data) {
        guard !gone, let onData else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onData(bytes) } }
    }
    func endInput() {
        guard let onEnd else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onEnd() } }
    }
}

// MARK: - The host

@MainActor
public final class TestHost {
    public struct Options {
        public var settings: [String: JSONValue] = [:]
        public var workspace: Workspace?
        public var previousSessionEndedUncleanly = false
        /// Answers to the plugin's requests by method; `{"$error": "words"}` refuses. Default `{}`.
        public var autoReply: [String: JSONValue] = [:]
        /// Extra environment for a spawned program.
        public var environment: [String: String] = [:]
        /// Keep the temporary folder.
        public var keep = false
        public init() {}
    }

    /// Every message the plugin sent, in order.
    public private(set) var received: [Envelope] = []
    /// A readable record of the conversation (→ to the plugin, ← from it, ! a problem).
    public private(set) var transcript: [String] = []
    /// `folder`, `data`, `session` and `place.<name>`, for `${…}` in scripts.
    public private(set) var variables: [String: String] = [:]
    /// The plugin object, in memory mode.
    public private(set) var plugin: Plugin?
    /// The exit status once the plugin left.
    public private(set) var exitCode: Int32?
    public let work: URL
    public let dataFolder: URL
    public let sessionFolder: URL
    public let places: TestPlaces
    public let manifest: JSONValue
    public let folder: URL

    private let options: Options
    private var settings: [String: JSONValue]
    private var nextID = 1
    private var writeToPlugin: @MainActor (Data) -> Void = { _ in }
    private var closeInput: @MainActor () -> Void = {}
    private var process: Process?
    private var reader = MessageReader()

    private init(folder: URL, options: Options) throws {
        self.folder = folder
        self.options = options
        let manifestData: Data
        do { manifestData = try Data(contentsOf: folder.appendingPathComponent("plugin.json")) } catch {
            throw PluginError("The plugin folder “\(folder.path)” has no readable plugin.json.")
        }
        manifest = try JSONValue.parse(manifestData)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("vektor-plugin-test-\(UUID().uuidString)")
        dataFolder = work.appendingPathComponent("data")
        sessionFolder = work.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        places = TestPlaces(work: work)
        var merged: [String: JSONValue] = [:]
        for item in manifest.value(at: "settings.items")?.arrayValue ?? [] {
            if let key = item["key"]?.stringValue, let value = item["default"] { merged[key] = value }
        }
        for (key, value) in options.settings { merged[key] = value }
        let substituted = places.substitute(merged)
        settings = substituted.settings
        variables = ["folder": folder.path, "data": dataFolder.path, "session": sessionFolder.path].merging(substituted.variables) { a, _ in a }
    }

    /// Runs the plugin in memory: `setup` registers its handlers on the SDK `Plugin` it is given. Send `startup()` next.
    public static func start(folder: URL, options: Options = Options(), setup: (Plugin) -> Void) throws -> TestHost {
        let host = try TestHost(folder: folder, options: options)
        let transport = MemoryTransport()
        transport.toHost = { [weak host] bytes in host?.fromPlugin(bytes) }
        transport.exited = { [weak host] code in
            host?.exitCode = code
            host?.log("! the plugin exited (status \(code))")
        }
        host.writeToPlugin = { [weak transport] bytes in transport?.deliver(bytes) }
        host.closeInput = { [weak transport] in transport?.endInput() }
        let plugin = Plugin(transport: transport, api: host.manifest["api"]?.intValue)
        plugin.diagnostics = { [weak host] text in MainActor.assumeIsolated { host?.log("stderr: \(text)") } }
        host.plugin = plugin
        setup(plugin)
        plugin.start()
        return host
    }

    /// Starts the folder's program as a process, the way Vektor does (its fixed PATH, the minimal environment).
    public static func spawn(folder: URL, options: Options = Options()) throws -> TestHost {
        let host = try TestHost(folder: folder, options: options)
        try host.spawnProcess()
        return host
    }

    private func spawnProcess() throws {
        let process = Process()
        process.executableURL = folder.appendingPathComponent(manifest["executable"]?.stringValue ?? "")
        process.arguments = manifest["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
        process.currentDirectoryURL = folder
        var environment = [
            "PATH": pluginPATH, "HOME": NSHomeDirectory(), "TMPDIR": sessionFolder.path + "/", "LANG": "en_US.UTF-8",
            "VEKTOR_PLUGIN_ID": manifest["id"]?.stringValue ?? "", "VEKTOR_PLUGIN_DATA": dataFolder.path,
            "VEKTOR_PLUGIN_SESSION": sessionFolder.path, "VEKTOR_PLUGIN_API": String(manifest["api"]?.intValue ?? 1),
        ]
        environment.merge(options.environment) { _, new in new }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fromPlugin(data) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { self?.log("stderr: \(line)") }
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.exitCode = status
                    self?.log("! the plugin exited (status \(status))")
                }
            }
        }
        do { try process.run() } catch { throw PluginError("The plugin could not start: \(error.localizedDescription)") }
        self.process = process
        let writer = input.fileHandleForWriting
        writeToPlugin = { [weak self] bytes in
            guard self?.exitCode == nil else { return }
            try? writer.write(contentsOf: bytes)
        }
        closeInput = { try? writer.close() }
    }

    private func log(_ line: String) { transcript.append(line) }

    private func fromPlugin(_ bytes: Data) {
        let messages: [JSONValue]
        do { messages = try reader.push(bytes) } catch {
            log("! the plugin sent something Vektor would refuse: \(error)")
            return
        }
        for message in messages {
            if message["api"]?.numberValue == nil { log("! a message without “api”, which Vektor refuses") }
            var json: [String: JSONValue] = [:]
            let kind: Envelope.Kind
            if let method = message["method"] {
                json["method"] = method
                json["params"] = message["params"] ?? [:]
                if let id = message["id"] {
                    kind = .request
                    json["id"] = id
                } else {
                    kind = .notification
                }
            } else if let error = message["error"] {
                kind = .failure
                json["id"] = message["id"]
                json["error"] = error
            } else {
                kind = .response
                json["id"] = message["id"]
                json["result"] = message["result"] ?? [:]
            }
            json["kind"] = .string(kind.rawValue)
            let envelope = Envelope(kind: kind, json: .object(json))
            received.append(envelope)
            log("← \(envelope)")
            if kind == .notification, envelope.method == Method.viewUpdate || envelope.method == Method.viewPatch { checkView(envelope) }
            if kind == .request { answer(envelope) }
        }
    }

    /// A block description is checked the way Vektor checks it; what it would refuse goes into the transcript.
    private func checkView(_ envelope: Envelope) {
        let view = envelope.params["view"]?.stringValue ?? ""
        let declared = manifest.value(at: "contributes.views")?.arrayValue?.contains { $0["id"]?.stringValue == view } ?? false
        if !declared { log("! “\(envelope.method ?? "")” names the view “\(view)”, which the manifest does not declare.") }
        if envelope.method == Method.viewUpdate, let blocks = envelope.params.value(at: "description.blocks") {
            for problem in validateBlocks(blocks).problems { log("! \(problem)") }
        }
    }

    private func answer(_ request: Envelope) {
        let method = request.method ?? ""
        var reply: [String: JSONValue] = ["id": request.id ?? .null, "api": .int(manifest["api"]?.intValue ?? 1)]
        if method.hasPrefix("storage/"), options.autoReply[method] == nil {
            switch places.answer(method, request.params) {
            case .success(let result): reply["result"] = result
            case .failure(let refusal): reply["error"] = refusal.json
            }
        } else if let scripted = options.autoReply[method], let refusal = scripted["$error"]?.stringValue {
            reply["error"] = ["message": .string(refusal)]
        } else {
            reply["result"] = options.autoReply[method] ?? [:]
        }
        log("→ \(JSONValue.object(reply).jsonText)")
        if let framed = try? Framing.encode(.object(reply)) { writeToPlugin(framed) }
    }

    /// `startup`'s parameters, as Vektor (and `vektor-plugin test`) sends them.
    public func startupParams() -> JSONValue {
        [
            "vektorVersion": "1.0.0", "pluginID": .string(manifest["id"]?.stringValue ?? ""),
            "previousSessionEndedUncleanly": .bool(options.previousSessionEndedUncleanly),
            "sessionTemporaryFolder": .string(sessionFolder.path), "dataFolder": .string(dataFolder.path),
            "settings": .object(settings), "workspace": (try? options.workspace.map { try JSONValue(encoding: $0) }) ?? .null,
        ]
    }

    /// Sends a message: a request (returns its id) unless the method is one Vektor sends as a notification.
    @discardableResult
    public func send(_ method: String, _ params: JSONValue = [:], asNotification: Bool? = nil) -> Int? {
        let notification = asNotification ?? Method.vektorNotifications.contains(method)
        var message: [String: JSONValue] = ["api": .int(manifest["api"]?.intValue ?? 1), "method": .string(method), "params": params]
        var id: Int?
        if !notification {
            id = nextID
            message["id"] = .int(nextID)
            nextID += 1
        }
        log("→ \(JSONValue.object(message).jsonText)")
        if let framed = try? Framing.encode(.object(message)) { writeToPlugin(framed) }
        return id
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits until a message received after `since` satisfies `test`.
    public func waitUntil(since: Int = 0, timeout: Double = 5, _ what: String, _ test: (Envelope) -> Bool) async throws -> Envelope {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = received.dropFirst(since).first(where: test) { return found }
            if let exitCode { throw PluginError("\(what) (the plugin had exited, status \(exitCode))\n\(transcript.joined(separator: "\n"))") }
            if Date() > deadline { throw PluginError("\(what)\n\(transcript.joined(separator: "\n"))") }
            await pause(0.01)
        }
    }

    /// Waits for a message after `since` that fits `expectation`.
    @discardableResult
    public func waitFor(_ expectation: Expectation, since: Int = 0, requestID: Int? = nil, timeout: Double = 5) async throws -> Envelope {
        try await waitUntil(since: since, timeout: timeout, "did not receive \(expectation.description)") {
            Matching.matches($0, expectation, requestID: requestID)
        }
    }

    /// Sends a request and waits for its answer (a response or a failure).
    @discardableResult
    public func request(_ method: String, _ params: JSONValue = [:], timeout: Double = 5) async throws -> Envelope {
        let since = received.count
        let id = send(method, params, asNotification: false)!
        return try await waitUntil(since: since, timeout: timeout, "no answer to “\(method)”") {
            ($0.kind == .response || $0.kind == .failure) && $0.id?.intValue == id
        }
    }

    /// Sends `startup` and waits for its answer.
    @discardableResult
    public func startup() async throws -> Envelope { try await request(Method.startup, startupParams()) }

    public func openView(_ view: String, item: String? = nil) {
        send(Method.viewOpened, item.map { ["view": .string(view), "item": .string($0)] } ?? ["view": .string(view)])
    }

    /// Sends a `view/event`; `revision` defaults to the last one the plugin sent for that view.
    public func viewEvent(_ view: String, _ action: String, _ fields: [String: JSONValue] = [:]) {
        var params = fields
        params["view"] = .string(view)
        params["action"] = .string(action)
        if params["revision"] == nil, let revision = lastRevision(view) { params["revision"] = .int(revision) }
        send(Method.viewEvent, .object(params))
    }

    /// Sends `web/message` as a page would.
    public func webMessage(_ view: String, _ message: JSONValue, block: String? = nil) {
        var params: [String: JSONValue] = ["view": .string(view), "message": message]
        if let block { params["block"] = .string(block) }
        send(Method.webMessage, .object(params))
    }

    /// Simulates Vektor refusing what the plugin sent last for `view` (`view/refused`, plugin API 2): `kind` says whether that
    /// was a whole description or a patch (by default, whichever the plugin sent last), `refusedRevision` its revision, and
    /// `revision` the one Vektor still shows — by default the revision the plugin sent before it (nil when there was none).
    /// The view state answers a refused patch with the whole description; `viewEvent` keeps defaulting to the plugin's last
    /// revision, so pass `"revision"` to make an event against the one Vektor still shows.
    @discardableResult
    public func refuse(_ view: String, problem: String = "Vektor could not show it.", kind: ViewRefusal.Kind? = nil, revision: Int?? = nil,
                       refusedRevision: Int?? = nil) -> ViewRefusal {
        let sent = sentRevisions(view)
        let last = sent.last
        let refused = ViewRefusal(
            view: view, kind: kind ?? (last?.method == Method.viewPatch ? .patch : .description),
            revision: revision ?? (sent.count >= 2 ? sent[sent.count - 2].revision : nil),
            refusedRevision: refusedRevision ?? last?.revision, problem: problem)
        send(Method.viewRefused, refused.json)
        return refused
    }

    /// The `view/update` and `view/patch` messages the plugin sent for `view`, in order, with their revisions.
    private func sentRevisions(_ view: String) -> [(method: String, revision: Int?)] {
        received.compactMap { envelope in
            guard envelope.kind == .notification, envelope.params["view"]?.stringValue == view else { return nil }
            if envelope.method == Method.viewUpdate { return (Method.viewUpdate, envelope.params.value(at: "description.revision")?.intValue) }
            if envelope.method == Method.viewPatch { return (Method.viewPatch, envelope.params["revision"]?.intValue) }
            return nil
        }
    }

    /// The revision of the description the plugin sent last for `view`.
    public func lastRevision(_ view: String) -> Int? {
        for envelope in received.reversed() where envelope.kind == .notification && envelope.params["view"]?.stringValue == view {
            if envelope.method == Method.viewUpdate { return envelope.params.value(at: "description.revision")?.intValue }
            if envelope.method == Method.viewPatch { return envelope.params["revision"]?.intValue }
        }
        return nil
    }

    public func notifications(_ method: String) -> [Envelope] { received.filter { $0.kind == .notification && $0.method == method } }

    /// Waits for the plugin to leave by itself; true when it did.
    public func waitForExit(timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while exitCode == nil, Date() < deadline { await pause(0.01) }
        return exitCode != nil
    }

    /// Sends `shutdown`, expects its answer and the plugin's exit.
    public func shutdown(reason: String = "quit") async throws {
        let answer = try await request(Method.shutdown, ["reason": .string(reason)])
        guard answer.kind == .response else { throw PluginError("shutdown was refused: \(answer)") }
        guard await waitForExit() else { throw PluginError("the plugin did not exit after answering shutdown") }
    }

    /// Ends the plugin if it is still there and removes the temporary folder (unless `keep`).
    public func close() async {
        if exitCode == nil {
            closeInput()
            if !(await waitForExit(timeout: 1)), let process, process.isRunning { process.terminate() }
        }
        if !options.keep { try? FileManager.default.removeItem(at: work) }
    }
}

// MARK: - Scripts: the test/checks.json format of `vektor-plugin test`

public struct ScriptReport: Sendable {
    public struct Step: Sendable {
        public var name: String
        public var failures: [String]
    }
    public var steps: [Step]
    public var transcript: [String]
    public var passed: Bool { !steps.isEmpty && steps.allSatisfy { $0.failures.isEmpty } }

    /// One line per step (`PASS name` / `FAIL name: why`), as `vektor-plugin test` prints them.
    public var summary: String {
        var lines = steps.map { $0.failures.isEmpty ? "PASS \($0.name)" : "FAIL \($0.name): \($0.failures.joined(separator: "; "))" }
        lines.append(passed ? "ALL \(steps.count) STEPS PASSED" : "FAILED")
        return lines.joined(separator: "\n")
    }
}

/// How `runScript` starts the plugin.
public enum ScriptTarget {
    case inMemory((Plugin) -> Void)
    case process(environment: [String: String])
}

private func substitute(_ value: JSONValue, _ variables: [String: String]) -> JSONValue {
    switch value {
    case .string(var text):
        for (name, replacement) in variables { text = text.replacingOccurrences(of: "${\(name)}", with: replacement) }
        return .string(text)
    case .array(let items): return .array(items.map { substitute($0, variables) })
    case .object(let object): return .object(object.mapValues { substitute($0, variables) })
    default: return value
    }
}

/// Plays a `test/checks.json` script the way `vektor-plugin test` does. Each step sends one message (or `startup`), then
/// waits until every expectation is met (or its timeout, default 5 s); `absent` ones must not arrive; `capture` stores values
/// for `${name}` in later steps.
@MainActor
public func runScript(_ script: JSONValue, folder: URL, target: ScriptTarget) async throws -> ScriptReport {
    var options = TestHost.Options()
    options.settings = script["settings"]?.objectValue ?? [:]
    options.workspace = try? script["workspace"]?.decode(Workspace.self)
    options.previousSessionEndedUncleanly = script["previousSessionEndedUncleanly"]?.boolValue ?? false
    options.autoReply = script["autoReply"]?.objectValue ?? [:]
    let host: TestHost
    switch target {
    case .inMemory(let setup): host = try TestHost.start(folder: folder, options: options, setup: setup)
    case .process(let environment):
        options.environment = environment
        host = try TestHost.spawn(folder: folder, options: options)
    }
    var variables = host.variables
    var steps: [ScriptReport.Step] = []
    for step in script["steps"]?.arrayValue ?? [] {
        let mark = host.received.count
        var requestID: Int?
        if step["startup"] == .bool(true) {
            requestID = host.send(Method.startup, host.startupParams(), asNotification: false)
        } else if let send = step["send"], let method = send["method"]?.stringValue {
            let kind = send["kind"]?.stringValue
            requestID = host.send(method, substitute(send["params"] ?? [:], variables), asNotification: kind.map { $0 == "notification" })
        }
        struct Expect {
            var expectation: Expectation
            var absent: Bool
            var capture: [String: JSONValue]
        }
        let expectations: [Expect] = (step["expect"]?.arrayValue ?? []).map { raw in
            Expect(
                expectation: Expectation(
                    kind: raw["kind"]?.stringValue.flatMap(Envelope.Kind.init(rawValue:)), method: raw["method"]?.stringValue,
                    match: raw["match"]?.objectValue ?? [:]),
                absent: raw["absent"] == .bool(true), capture: raw["capture"]?.objectValue ?? [:])
        }
        let positives = expectations.filter { !$0.absent }.map(\.expectation)
        let deadline = Date().addingTimeInterval(step["timeout"]?.numberValue ?? 5)
        let unmet: () -> [Expectation] = {
            positives.filter { expectation in !host.received.dropFirst(mark).contains { Matching.matches($0, expectation, requestID: requestID) } }
        }
        while !unmet().isEmpty, Date() < deadline {
            if host.exitCode != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                break
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        if expectations.contains(where: \.absent) { try? await Task.sleep(nanoseconds: 300_000_000) }
        var failures = unmet().map { "did not receive \($0.description)" }
        for expect in expectations where expect.absent {
            if host.received.dropFirst(mark).contains(where: { Matching.matches($0, expect.expectation, requestID: requestID) }) {
                failures.append("received \(expect.expectation.description), which must not arrive")
            }
        }
        if !failures.isEmpty, let code = host.exitCode { failures.append("the plugin had exited (status \(code))") }
        if step["expectExit"] == .bool(true) {
            let exited = await host.waitForExit(timeout: step["timeout"]?.numberValue ?? 5)
            if !exited { failures.append("the plugin did not exit by itself after the step") }
        }
        for expect in expectations where !expect.capture.isEmpty {
            guard let message = host.received.dropFirst(mark).first(where: { Matching.matches($0, expect.expectation, requestID: requestID) }) else { continue }
            for (name, path) in expect.capture {
                guard let path = path.stringValue else { continue }
                switch message.json.value(at: path) {
                case .string(let text)?: variables[name] = text
                case .number(let number)?: variables[name] = number.rounded() == number ? String(Int(number)) : String(number)
                default: break
                }
            }
        }
        steps.append(ScriptReport.Step(name: step["name"]?.stringValue ?? "step", failures: failures))
    }
    let transcript = host.transcript
    await host.close()
    return ScriptReport(steps: steps, transcript: transcript)
}

/// `runScript` for a script file (`test/checks.json`).
@MainActor
public func runScript(file: URL, folder: URL, target: ScriptTarget) async throws -> ScriptReport {
    try await runScript(try JSONValue.parse(try Data(contentsOf: file)), folder: folder, target: target)
}
