import Foundation
import VektorPlugin

// One workspace's local boards, in the plugin's data folder (`$VEKTOR_PLUGIN_DATA`):
//
//     workspaces/<workspace>/working/index.json, working/boards/<id>.json    what the user sees; saved on every change
//     workspaces/<workspace>/sync/base/…                                    the last synced copy (the merge's base)
//     workspaces/<workspace>/sync/state.json                                versions on the place, unsynced files, last sync
//     workspaces/<workspace>/sync/journal/<file>.json                       a write to the place in progress (see SyncEngine)
//
// With no place chosen the working copy IS the storage. With a place it is the local copy every change is saved to at once;
// a sync brings it and the place together. Every file is written whole to a temporary file and renamed into place, so a quit
// or a crash never leaves half a file. A workspace's folder is named from its id, never its name; a board's file from the
// board's id, which `Ids.isBoardID` has accepted.

enum Area: String { case working, base }

/// The name of a workspace's folder in the data folder (from its id, never its name).
public enum WorkspaceFolders {
    public static func name(for workspace: Workspace?) -> String { LocalStore.folderName(for: workspace) }
}

/// What the last sync knew about the place.
struct SyncStateFile: Codable, Equatable {
    var version = 1
    /// The place this state belongs to (its label). Another place starts without a base: its first sync asks about every
    /// record both hold differently and loses nothing.
    var placeLabel: String?
    /// The version of each file on the place at the last sync (`index.json`, `boards/<id>.json`).
    var versions: [String: String] = [:]
    /// Files changed locally since they were last synced.
    var unsynced: [String] = []
    /// When the last sync finished without an error or a question (ISO 8601).
    var lastSynced: String?
}

/// A write to the place about to happen: what it will write (nil: a delete), and the local copy and the base when it was
/// planned. If the plugin stops before it is recorded, the next sync finds out whether it reached the place (see SyncEngine).
struct JournalEntry: Codable, Equatable {
    var path: String
    var planned: String?
    var mine: String?
    var base: String?
}

final class LocalStore {
    let root: URL
    private let manager = FileManager.default

    init(dataFolder: URL, workspace: Workspace?) {
        root = dataFolder.appendingPathComponent("workspaces").appendingPathComponent(Self.folderName(for: workspace))
    }

    /// A workspace's folder: `w-<id>` when the id is plain letters and digits, else a hash of it (never its name).
    static func folderName(for workspace: Workspace?) -> String {
        guard let id = workspace?.id, !id.isEmpty else { return "default" }
        if Ids.isBoardID(id) { return "w-\(id)" }
        var hash: UInt64 = 0xcbf29ce484222325   // FNV-1a: stable across runs, unlike Hasher
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "h-" + String(hash, radix: 16)
    }

    private func url(_ path: String, _ area: Area) -> URL {
        switch area {
        case .working: return root.appendingPathComponent("working").appendingPathComponent(path)
        case .base: return root.appendingPathComponent("sync/base").appendingPathComponent(path)
        }
    }

    // MARK: Files

    func data(_ path: String, _ area: Area) -> Data? { try? Data(contentsOf: url(path, area)) }

    func exists(_ path: String, _ area: Area) -> Bool { manager.fileExists(atPath: url(path, area).path) }

    /// Writes (or with nil removes) a file, whole: a crash leaves the old file or the new one.
    func setData(_ data: Data?, _ path: String, _ area: Area) throws {
        let target = url(path, area)
        guard let data else {
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            return
        }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    func index(_ area: Area) throws -> BoardIndexFile? {
        try data("index.json", area).map { try BoardJSON.index($0, path: "index.json") }
    }

    func setIndex(_ file: BoardIndexFile?, _ area: Area) throws {
        try setData(try file.map { try BoardJSON.encode($0.normalized()) }, "index.json", area)
    }

    func board(_ id: String, _ area: Area) throws -> BoardFile? {
        guard Ids.isBoardID(id) else { return nil }
        return try data(Ids.boardPath(id), area).map { try BoardJSON.board($0, path: Ids.boardPath(id), id: id) }
    }

    func setBoard(_ file: BoardFile?, id: String, _ area: Area) throws {
        guard Ids.isBoardID(id) else { throw BoardError("That board cannot be saved: its id cannot be used.") }
        try setData(try file.map { try BoardJSON.encode($0.normalized()) }, Ids.boardPath(id), area)
    }

    /// The ids of the board files in an area.
    func boardIDs(_ area: Area) -> [String] {
        let folder = url("boards", area)
        return ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap(Ids.boardID(fromFileName:)).sorted()
    }

    // MARK: Sync state

    private var stateURL: URL { root.appendingPathComponent("sync/state.json") }

    func state() -> SyncStateFile {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(SyncStateFile.self, from: $0) } ?? SyncStateFile()
    }

    func setState(_ state: SyncStateFile) throws {
        var state = state
        state.unsynced = Array(Set(state.unsynced)).sorted()
        try manager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BoardJSON.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Forgets the base and the versions (another place): the next sync starts as the first one.
    func resetBase(for label: String?) throws {
        let base = root.appendingPathComponent("sync/base")
        if manager.fileExists(atPath: base.path) { try manager.removeItem(at: base) }
        var state = SyncStateFile()
        state.placeLabel = label
        // Everything held locally is unsynced with the new place.
        state.unsynced = (try? index(.working)).map { ["index.json"] + $0.boards.map { Ids.boardPath($0.id) } } ?? []
        try setState(state)
    }

    // MARK: Journal

    private var journalFolder: URL { root.appendingPathComponent("sync/journal") }

    private func journalURL(_ path: String) -> URL {
        journalFolder.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__"))
    }

    func journal() -> [JournalEntry] {
        let names = ((try? manager.contentsOfDirectory(atPath: journalFolder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { name in
            (try? Data(contentsOf: journalFolder.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(JournalEntry.self, from: $0) }
        }
    }

    func addJournal(_ entry: JournalEntry) throws {
        try manager.createDirectory(at: journalFolder, withIntermediateDirectories: true)
        try BoardJSON.encode(entry).write(to: journalURL(entry.path), options: .atomic)
    }

    func removeJournal(_ path: String) throws {
        let file = journalURL(path)
        if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
    }
}
