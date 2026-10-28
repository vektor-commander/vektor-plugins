import BoardPlugin
import Foundation
import VektorPlugin
import VektorPluginTestKit

// A small harness: the plugin's tests are a plain executable (`swift run board-tests`), because the Command Line Tools ship
// neither XCTest nor Swift Testing. Each test is an async closure on the main actor; a failed check throws.
//
// Every test runs against the SDK's test kit: an in-memory Vektor (`TestHost`) whose fake place is a folder in a temporary
// folder, answered with the storage service's own rules (versions, `ifVersion`, refusal codes). Nothing touches the network
// or the user's Vektor configuration: data folders are temporary folders too, removed at the end.

struct Failure: Error, CustomStringConvertible {
    var description: String
}

@MainActor
final class Suite {
    static let shared = Suite()
    private(set) var passed = 0
    private(set) var failed: [String] = []

    func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        // `swift run board-tests thousands` runs the tests whose name contains the word.
        let only = CommandLine.arguments.dropFirst()
        if !only.isEmpty, !only.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return }
        do {
            try await body()
            passed += 1
            print("ok   \(name)")
        } catch {
            failed.append(name)
            print("FAIL \(name)\n     \(String(describing: error).replacingOccurrences(of: "\n", with: "\n     "))")
        }
    }
}

@MainActor
func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
    await Suite.shared.test(name, body)
}

func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line, file: String = #fileID) throws {
    if !condition { throw Failure(description: "\(file):\(line): \(message())") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "", line: Int = #line, file: String = #fileID) throws {
    if actual != expected { throw Failure(description: "\(file):\(line): \(message())\n  got:      \(actual)\n  expected: \(expected)") }
}

@MainActor
func checkThrows(_ pattern: String, line: Int = #line, file: String = #fileID, _ body: @MainActor () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        let text = String(describing: error)
        if text.range(of: pattern, options: .regularExpression) == nil { throw Failure(description: "\(file):\(line): the error “\(text)” does not match /\(pattern)/") }
        return
    }
    throw Failure(description: "\(file):\(line): expected an error matching /\(pattern)/")
}

/// The plugin's folder (this file is samples/board/Sources/board-tests/Harness.swift).
let pluginFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A temporary folder, removed by `cleanUp()`.
@MainActor var temporaryFolders: [URL] = []
@MainActor
func temporaryFolder(_ name: String = "data") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("board-tests-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    temporaryFolders.append(folder)
    return folder
}

@MainActor
func cleanUp() async {
    for world in World.all { await world.close() }
    World.all = []
    for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
    temporaryFolders = []
}

/// A clock the tests move by hand: every change gets a later time.
@MainActor
final class Clock {
    var now = Date(timeIntervalSince1970: 1_792_000_000)
    func tick() -> Date {
        now = now.addingTimeInterval(1)
        return now
    }
}

/// One test world: a test host (Vektor) with a fake place "boards", and as many "copies" (controllers with their own data
/// folders) as a test needs, all reaching the place through the plugin's storage service on the wire.
@MainActor
final class World {
    let host: TestHost
    let plugin: Plugin
    let clock: Clock
    /// The place's folder on disk: what "another copy" or a person editing the JSON by hand changes.
    let placeFolder: URL
    let handle: PlaceHandle
    var logs: [String] = []
    /// The texts a test put into records: none of them may appear in the Log.
    var secrets: [String] = []

    /// Every world a test made: closed (their temporary folders removed) by `cleanUp()`.
    static var all: [World] = []

    /// With `install`, the plugin itself is registered (`setup`), as Vektor runs it: its own controller (the one the view draws) is
    /// `controller`, and `copy(…)` makes the other copies that share the place. `data` is put into the plugin's data folder first.
    init(remote: Bool = true, workspace: Workspace? = Workspace(id: "w1", name: "Work"), install: Bool = false, author: String = "Ada", place: Bool = true, prepare: ((URL) throws -> Void)? = nil) async throws {
        var options = TestHost.Options()
        // An installed plugin starts with no place chosen (the folder exists in the test host as "pending"), then is told its place
        // the way Vektor tells it: by a settings change that carries the handle.
        if place { options.settings = [install ? "pending" : "place": ["$place": "boards"]] }
        options.workspace = workspace
        let clock = Clock()
        self.clock = clock
        host = try TestHost.start(folder: pluginFolder, options: options) { plugin in
            if install { setup(plugin, options: BoardController.Options(author: author, now: { clock.tick() })) }
        }
        plugin = host.plugin!
        try prepare?(host.dataFolder)
        try await host.startup()
        placeFolder = URL(fileURLWithPath: host.variables["place.boards"] ?? host.work.path)
        let given = host.startupParams()["settings"]?[install ? "pending" : "place"] ?? [:]
        var object = given.objectValue.flatMap { $0.isEmpty ? nil : $0 } ?? ["place": "boards", "label": "No place"]
        object["remote"] = .bool(remote)
        handle = try JSONValue.object(object).decode(PlaceHandle.self)
        World.all.append(self)
        if install { await settleStartup() }
        // The fake place is always local; a place on a connection is told to the plugin the way Vektor tells it: by a
        // settings change that carries the handle.
        if install, place {
            host.send("settingsChanged", ["settings": ["place": .object(object)]])
            try await until("the plugin knows its place") { self.controller?.status.mode != .pluginFolder }
            await controller?.settle()
        }
    }

    /// The controller of the installed plugin.
    var controller: BoardController? { BoardPluginState.controller(of: plugin) }
    var model: BoardViewModel? { BoardPluginState.model(of: plugin) }

    func settleStartup() async {
        for _ in 0..<200 where controller?.isLoaded != true { try? await Task.sleep(nanoseconds: 5_000_000) }
        await controller?.settle()
    }

    /// A copy: its own data folder (unless given, for a restart), reaching the place through `wrap`.
    func copy(
        _ name: String, data: URL? = nil, author: String? = nil, policy: MergePolicy = .record, autoSync: BoardController.RemoteAutoSync? = nil,
        wrap: ((PlaceStore) -> PlaceStore)? = nil
    ) throws -> BoardController {
        let folder = try data ?? temporaryFolder(name)
        let plugin = self.plugin
        var options = BoardController.Options(
            author: author ?? "Author \(name)", now: { [clock] in clock.tick() }, policy: policy, remoteAutoSync: autoSync)
        options.log = { [weak self] message in self?.logs.append(message) }
        return BoardController(dataFolder: folder, options: options) { handle in
            let place = VektorPlace(plugin: plugin, handle: handle)
            return wrap?(place) ?? place
        }
    }

    func close() async { await host.close() }

    /// Storage calls the plugin made, by method.
    func calls(_ method: String) -> Int { host.received.filter { $0.kind == .request && $0.method == method }.count }

    /// A file in the place, as JSON.
    func placeJSON(_ path: String) throws -> JSONValue { try JSONValue.parse(try Data(contentsOf: placeFolder.appendingPathComponent(path))) }
    func placeHas(_ path: String) -> Bool { FileManager.default.fileExists(atPath: placeFolder.appendingPathComponent(path).path) }

    /// Changes a file in the place the way a person with a text editor would (or another program).
    func editPlace(_ path: String, _ change: (inout JSONValue) throws -> Void) throws {
        var json = try placeJSON(path)
        try change(&json)
        // Pretty or not does not matter: the plugin reads JSON. A new modification time gives a new version.
        try json.jsonData.write(to: placeFolder.appendingPathComponent(path), options: .atomic)
    }
}

/// A place that can be made to fail: the plugin is "killed" right before or right after a write, or another copy writes the
/// same file just before this one does (so `ifVersion` refuses).
@MainActor
final class FaultyPlace: PlaceStore {
    struct Killed: Error, CustomStringConvertible { var description: String { "the plugin was stopped (test)" } }
    let inner: PlaceStore
    var label: String { inner.label }
    var isRemote: Bool { inner.isRemote }
    /// Stop before the write with this number (1-based) reaches the place.
    var killBeforeWrite: Int?
    /// Stop right after the write with this number reached the place, before the plugin heard the answer.
    var killAfterWrite: Int?
    /// Runs before every write (the path): another copy acting at the worst moment.
    var beforeWrite: ((String) async throws -> Void)?
    private(set) var writes = 0
    private(set) var reads = 0

    init(_ inner: PlaceStore) { self.inner = inner }

    func list(_ folder: String) async throws -> [StorageEntry] { try await inner.list(folder) }
    func read(_ path: String) async throws -> (data: Data, version: String)? {
        reads += 1
        return try await inner.read(path)
    }
    func write(_ path: String, data: Data, ifVersion: IfVersion) async throws -> String {
        writes += 1
        if writes == killBeforeWrite { throw Killed() }
        if let beforeWrite { try await beforeWrite(path) }
        let version = try await inner.write(path, data: data, ifVersion: ifVersion)
        if writes == killAfterWrite { throw Killed() }
        return version
    }
    func delete(_ path: String, ifVersion: String) async throws {
        writes += 1
        if writes == killBeforeWrite { throw Killed() }
        try await inner.delete(path, ifVersion: ifVersion)
        if writes == killAfterWrite { throw Killed() }
    }
    func createFolder(_ path: String) async throws { try await inner.createFolder(path) }
}

extension BoardController {
    /// The board's tasks by column title, in order: "To do: A, B | Done: C".
    func layout(_ board: String) -> String {
        columns(of: board).map { "\($0.column.title): \($0.tasks.map(\.task.title).joined(separator: ", "))" }.joined(separator: " | ")
    }

    func taskID(_ title: String, in board: String) -> String? { file(board)?.tasks.first { $0.title == title }?.id }
    func columnID(_ title: String, in board: String) -> String? { file(board)?.columns.first { $0.title == title }?.id }
}

/// Waits (at most `timeout` seconds) until `condition` holds.
@MainActor
func until(_ what: String, timeout: Double = 5, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw Failure(description: "gave up waiting until \(what)") }
        try await Task.sleep(nanoseconds: 3_000_000)
    }
}
