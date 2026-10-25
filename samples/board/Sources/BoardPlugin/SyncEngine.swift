import Foundation
import VektorPlugin

// The sync of one workspace's boards with its place: the working copy on this Mac, the last synced base, and the place.
//
// One sync:
//   1. Finish what an interrupted sync left (the journal): a write that reached the place is recorded on this Mac too.
//   2. List the place (names and versions only). Nothing changed here and every version is the one recorded: done, nothing
//      read, nothing written.
//   3. Read only the files whose version changed. Merge the index (the list of boards), then each board, record by record,
//      against the base (Merge.swift). A real conflict is reported with both versions and that board (or, for a conflict in
//      the list of boards, the list) is left as it is on both sides until the user has answered.
//   4. Write what changed, in an order that keeps the place readable at every moment: board files first, then the index
//      that lists them, then the files of deleted boards. Every write is all or nothing (Vektor writes a temporary file and
//      renames it) and carries `ifVersion`: if anyone changed the file since it was read, Vektor refuses and the sync starts
//      again from step 2 instead of overwriting.
//   5. After each write, this Mac's copy and the base are updated and the new version recorded. A journal entry, written
//      before the write and removed after, covers a stop between the two: step 1 of the next sync reads the file back and
//      adopts the write if the place has it, or forgets it if not. So an interrupted sync leaves each file as it was or as it
//      was meant to be, never half, and the next one resumes.
//
// Unsynced changes on this Mac are never lost: they are only ever replaced by a merge that contains them, or by the user's
// answer to a conflict.

/// A conflict to show the user: both versions as readable text (for the diff block) and the answers that apply.
public struct SyncConflictItem: Equatable, Sendable, Identifiable {
    public enum Subject: String, Sendable {
        /// A board's entry in the list (its name), changed on both sides or deleted on one and renamed on the other.
        case board
        /// A whole board deleted on one side while its tasks, columns or tags changed on the other.
        case boardContents
        case column, task, tag, comment
    }
    /// Stable while the same conflict stands: pass it to `resolveConflict`.
    public var id: String
    public var boardID: String
    public var boardName: String
    public var subject: Subject
    public var recordID: String
    public var reason: ConflictReason
    /// "Task “Write the docs”", for a heading.
    public var title: String
    /// This Mac's version as text; nil when it was deleted on this Mac.
    public var mine: String?
    /// The place's version as text; nil when it was deleted there.
    public var theirs: String?
    /// The answers that apply: keep mine, keep theirs, and for a task both sides have, keep both.
    public var choices: [ConflictChoice]
    var mineDigest: String
    var theirsDigest: String
}

/// What a sync did.
public struct SyncReport: Equatable, Sendable {
    /// Files written to the place, files taken from it, board files deleted there.
    public var sent = 0
    public var received = 0
    public var deleted = 0
    /// Files read from the place.
    public var reads = 0
    /// Questions for the user. Until they are answered the boards (or the list of boards) they are in stay unsynced.
    public var conflicts: [SyncConflictItem] = []
    /// How many times the sync started again because the place changed while it ran.
    public var restarts = 0
}

@MainActor
final class SyncEngine {
    let store: LocalStore
    let place: PlaceStore
    let policy: MergePolicy
    let now: () -> String
    let log: (String) -> Void
    let progress: (String) -> Void
    var resolutions: [String: ConflictResolution]
    /// How many times one sync starts again before it gives up (each start is caused by someone else's write).
    static let attempts = 6

    init(store: LocalStore, place: PlaceStore, policy: MergePolicy, resolutions: [String: ConflictResolution], now: @escaping () -> String,
         log: @escaping (String) -> Void, progress: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.place = place
        self.policy = policy
        self.resolutions = resolutions
        self.now = now
        self.log = log
        self.progress = progress
    }

    func run() async throws -> SyncReport {
        if store.state().placeLabel != place.label {
            // Another place than the last sync's (or the first sync): no base, so nothing is taken as deleted.
            try store.resetBase(for: place.label)
        }
        try await resume()
        var restarts = 0
        while true {
            do {
                var report = try await pass()
                report.restarts = restarts
                return report
            } catch is PlaceChanged {
                restarts += 1
                log("Sync: the place changed while this Mac synced; starting again.")
                if restarts >= Self.attempts {
                    throw BoardError("The place kept changing while this Mac synced. Nothing was lost; sync again in a moment.")
                }
            }
        }
    }

    // MARK: 1. The journal

    /// Writes an interrupted sync may have made: adopted when the place has them, forgotten when not.
    func resume() async throws {
        let entries = store.journal()
        guard !entries.isEmpty else { return }
        var state = store.state()
        for entry in entries {
            let remote = try await place.read(entry.path)
            let reached: Bool
            if let planned = entry.planned {
                reached = try remote.map { try same(entry.path, $0.data, Data(planned.utf8)) } ?? false
            } else {
                reached = remote == nil
            }
            if reached {
                try adopt(entry, version: remote?.version, state: &state)
                log("Sync: finished a write the last sync had started.")
            }
            try store.removeJournal(entry.path)
        }
        try store.setState(state)
    }

    private func same(_ path: String, _ a: Data, _ b: Data) throws -> Bool {
        if path == "index.json" { return try BoardJSON.index(a, path: path) == BoardJSON.index(b, path: path) }
        guard let id = Ids.boardID(fromFileName: String(path.dropFirst("boards/".count))) else { return false }
        return try BoardJSON.board(a, path: path, id: id) == BoardJSON.board(b, path: path, id: id)
    }

    /// The place has what the journal planned: this Mac takes it as the base, and as its copy unless the copy changed since.
    private func adopt(_ entry: JournalEntry, version: String?, state: inout SyncStateFile) throws {
        let path = entry.path
        if path == "index.json" {
            let planned = try entry.planned.map { try BoardJSON.index(Data($0.utf8), path: path) }
            let mine = try entry.mine.map { try BoardJSON.index(Data($0.utf8), path: path) }
            let working = try store.index(.working)
            var next = working
            if working == mine { next = planned } else if working != planned, let planned, let working {
                // Changed here after the interrupted sync: those changes go on top of what was written, if they can.
                let rebased = mergeIndex(base: mine, mine: working, theirs: planned, policy: .record, resolutions: [:])
                guard rebased.conflicts.isEmpty else { return }
                next = BoardIndexFile(boards: rebased.records)
            }
            try store.setIndex(next, .working)
            try store.setIndex(planned, .base)
        } else {
            guard let id = Ids.boardID(fromFileName: String(path.dropFirst("boards/".count))) else { return }
            let planned = try entry.planned.map { try BoardJSON.board(Data($0.utf8), path: path, id: id) }
            let mine = try entry.mine.map { try BoardJSON.board(Data($0.utf8), path: path, id: id) }
            let working = try store.board(id, .working)
            var next = working
            if working == mine { next = planned } else if working != planned, let planned, let working {
                let rebased = mergeBoard(id: id, base: mine, mine: working, theirs: planned, policy: .record, resolutions: [:], now: now())
                guard !rebased.hasConflicts else { return }
                next = rebased.file
            }
            try store.setBoard(next, id: id, .working)
            try store.setBoard(planned, id: id, .base)
        }
        state.versions[path] = version
        if try workingEqualsBase(path) { state.unsynced.removeAll { $0 == path } } else if !state.unsynced.contains(path) { state.unsynced.append(path) }
    }

    private func workingEqualsBase(_ path: String) throws -> Bool {
        if path == "index.json" { return try store.index(.working) == store.index(.base) }
        guard let id = Ids.boardID(fromFileName: String(path.dropFirst("boards/".count))) else { return true }
        return try store.board(id, .working) == store.board(id, .base)
    }

    // MARK: 2–5. One pass

    private func pass() async throws -> SyncReport {
        var state = store.state()
        var report = SyncReport()
        progress("Looking at the place…")
        let root = try await place.list("")
        var hasBoardsFolder = root.contains { $0.isFolder && $0.name == "boards" }
        var remote: [String: String] = [:]
        if let index = root.first(where: { !$0.isFolder && $0.name == "index.json" }) { remote["index.json"] = index.version ?? "" }
        if hasBoardsFolder {
            for entry in try await place.list("boards") where !entry.isFolder {
                if let id = Ids.boardID(fromFileName: entry.name) { remote[Ids.boardPath(id)] = entry.version ?? "" }
            }
        }

        // Nothing changed on either side: nothing is read or written. (A board file no index names — another Mac half way
        // through its sync — changes nothing until the index names it, and then the index's version has changed.)
        let placeUnchanged = remote["index.json"] != nil && state.versions.allSatisfy { remote[$0.key] == $0.value }
            && remote["index.json"] == state.versions["index.json"]
        if state.unsynced.isEmpty, resolutions.isEmpty, placeUnchanged, store.journal().isEmpty {
            state.lastSynced = now()
            try store.setState(state)
            log("Sync: nothing changed on either side.")
            return report
        }

        // --- The index ---------------------------------------------------------------------------------------------------
        let workIndex = try store.index(.working) ?? BoardIndexFile()
        var baseIndex = try store.index(.base)
        // (`resultBoards` may gain a board below: one deleted on a side while the other changed it, kept by the user's answer.)
        var theirsIndex = BoardIndexFile()
        var theirsIndexVersion = remote["index.json"]
        // A place whose index is gone after a sync (emptied, or another folder now): never read as "every board deleted".
        var wiped = false
        if let version = theirsIndexVersion {
            if version == state.versions["index.json"], let baseIndex {
                theirsIndex = baseIndex
            } else {
                guard let read = try await place.read("index.json") else { throw PlaceChanged() }
                theirsIndex = try BoardJSON.index(read.data, path: "index.json")
                theirsIndexVersion = read.version
                report.reads += 1
            }
        } else if baseIndex != nil {
            wiped = true
            baseIndex = nil
            log("Sync: the place has no list of boards any more; this Mac's boards are sent to it again.")
        }
        func base(_ id: String) throws -> BoardFile? { wiped ? nil : try store.board(id, .base) }

        let indexMerge = mergeIndex(base: baseIndex, mine: workIndex, theirs: theirsIndex, policy: policy, resolutions: resolutions)
        var resultBoards = indexMerge.records
        var indexConflicts: [SyncConflictItem] = indexMerge.conflicts.map { conflict in
            let name = conflict.mine?.name ?? conflict.theirs?.name ?? conflict.base?.name ?? ""
            return SyncConflictItem(
                id: conflict.key, boardID: conflict.id, boardName: name, subject: .board, recordID: conflict.id, reason: conflict.reason,
                title: "Board “\(name)”", mine: conflict.mine.map { "Name: \($0.name)" }, theirs: conflict.theirs.map { "Name: \($0.name)" },
                choices: [.keepMine, .keepTheirs], mineDigest: digest(conflict.mine), theirsDigest: digest(conflict.theirs))
        }

        // A board deleted on one side whose contents changed on the other is asked about, never dropped.
        let resultIDs = Set(resultBoards.map(\.id))
        let conflictIDs = Set(indexMerge.conflicts.map(\.id))
        var remoteBoards: [String: (file: BoardFile, version: String)] = [:]
        func theirsBoard(_ id: String) async throws -> BoardFile? {
            let path = Ids.boardPath(id)
            guard let version = remote[path] else { return nil }
            if let held = remoteBoards[id] { return held.file }
            if version == state.versions[path], let base = try base(id) { return base }
            guard let read = try await place.read(path) else { throw PlaceChanged() }
            let file = try BoardJSON.board(read.data, path: path, id: id)
            remoteBoards[id] = (file, read.version)
            report.reads += 1
            return file
        }
        for entry in baseIndex?.boards ?? [] where !resultIDs.contains(entry.id) && !conflictIDs.contains(entry.id) {
            let id = entry.id
            let mineEntry = workIndex.boards.first { $0.id == id }
            let theirsEntry = theirsIndex.boards.first { $0.id == id }
            let baseFile = try base(id)
            var mineFile: BoardFile?
            var theirsFile: BoardFile?
            var reason: ConflictReason?
            if mineEntry != nil {
                mineFile = try store.board(id, .working)
                if let mineFile, mineFile != (baseFile ?? BoardFile(board: id)) { reason = .deletedThere }
            } else if theirsEntry != nil {
                theirsFile = try await theirsBoard(id)
                if let theirsFile, theirsFile != (baseFile ?? BoardFile(board: id)) { reason = .deletedHere }
            }
            guard let reason else { continue }
            let key = conflictKey(scope: "index", kind: "boardContents", id: id)
            if let answer = resolutions[key], answer.mine == digest(mineFile), answer.theirs == digest(theirsFile) {
                if answer.choice == .keepMine, let mineEntry { resultBoards.append(mineEntry) }
                if answer.choice == .keepTheirs, let theirsEntry { resultBoards.append(theirsEntry) }
                continue
            }
            indexConflicts.append(SyncConflictItem(
                id: key, boardID: id, boardName: entry.name, subject: .boardContents, recordID: id, reason: reason, title: "Board “\(entry.name)”",
                mine: mineFile.map { ConflictText.board($0) }, theirs: theirsFile.map { ConflictText.board($0) }, choices: [.keepMine, .keepTheirs],
                mineDigest: digest(mineFile), theirsDigest: digest(theirsFile)))
        }
        let blocked = !indexConflicts.isEmpty
        let resultIndex = BoardIndexFile(boards: resultBoards).normalized()
        var conflicts = indexConflicts

        // --- The boards --------------------------------------------------------------------------------------------------
        let workIDs = Set(workIndex.boards.map(\.id))
        let theirsIDs = Set(theirsIndex.boards.map(\.id))
        let keep: [String] = blocked
            ? workIndex.normalized().boards.map(\.id).filter { theirsIDs.contains($0) }
            : resultIndex.boards.map(\.id)
        let keepSet = Set(keep)
        let names = Dictionary(resultIndex.boards.map { ($0.id, $0.name) } + workIndex.boards.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var unsynced = Set<String>()
        if blocked { unsynced.insert("index.json") }

        let answeredBoards = Set(resolutions.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
        for (number, id) in keep.enumerated() {
            progress("Board \(number + 1) of \(keep.count)…")
            let path = Ids.boardPath(id)
            // Unchanged here since the last sync and unchanged on the place: not even read from this Mac's disk.
            if !wiped, !state.unsynced.contains(path), !answeredBoards.contains(id), let version = remote[path], version == state.versions[path],
                store.exists(path, .base), store.exists(path, .working)
            {
                continue
            }
            let baseFile = try base(id)
            let working = try store.board(id, .working)
            let theirs = try await theirsBoard(id)
            let theirsVersion = remoteBoards[id]?.version ?? remote[path]
            let mineFile = working ?? baseFile ?? theirs ?? BoardFile(board: id)
            let theirsFile = theirs ?? baseFile ?? mineFile
            var planned = mineFile
            if mineFile != theirsFile {
                let merged = mergeBoard(id: id, base: baseFile, mine: mineFile, theirs: theirsFile, policy: policy, resolutions: resolutions, now: now())
                if merged.hasConflicts {
                    conflicts += ConflictText.items(merged, board: id, name: names[id] ?? "", mine: mineFile, theirs: theirsFile)
                    unsynced.insert(path)
                    continue
                }
                planned = merged.file
            }
            if working == planned, baseFile == planned, theirs == planned, state.versions[path] == theirsVersion {
                state.unsynced.removeAll { $0 == path }
                continue
            }
            if theirs == nil || planned != theirs {
                if !hasBoardsFolder {
                    try await place.createFolder("boards")
                    hasBoardsFolder = true
                }
                try store.addJournal(JournalEntry(path: path, planned: try text(planned), mine: try working.map(text), base: try baseFile.map(text)))
                let version = try await place.write(path, data: try BoardJSON.encode(planned), ifVersion: theirsVersion.map(IfVersion.version) ?? .absent)
                report.sent += 1
                try commitBoard(id, planned, working: working, version: version, state: &state, report: &report)
                remote[path] = version
                try store.removeJournal(path)
            } else {
                try commitBoard(id, planned, working: working, version: theirsVersion, state: &state, report: &report)
            }
        }

        // --- The index, then deleted boards ------------------------------------------------------------------------------
        if !blocked {
            if theirsIndexVersion == nil || resultIndex != theirsIndex.normalized() {
                try store.addJournal(JournalEntry(path: "index.json", planned: try text(resultIndex), mine: try text(workIndex), base: try baseIndex.map(text)))
                let version = try await place.write("index.json", data: try BoardJSON.encode(resultIndex), ifVersion: theirsIndexVersion.map(IfVersion.version) ?? .absent)
                report.sent += 1
                remote["index.json"] = version
                try commitIndex(resultIndex, working: workIndex, version: version, state: &state, report: &report)
                try store.removeJournal("index.json")
            } else {
                try commitIndex(resultIndex, working: workIndex, version: theirsIndexVersion, state: &state, report: &report)
            }
            let gone = workIDs.union(theirsIDs).union(baseIndex?.boards.map(\.id) ?? []).subtracting(keepSet)
            for id in gone.sorted() {
                let path = Ids.boardPath(id)
                if let version = remote[path] {
                    try store.addJournal(JournalEntry(path: path, planned: nil, mine: try store.board(id, .working).map(text), base: try base(id).map(text)))
                    try await place.delete(path, ifVersion: version)
                    report.deleted += 1
                    remote[path] = nil
                }
                try store.setBoard(nil, id: id, .working)
                try store.setBoard(nil, id: id, .base)
                state.versions[path] = nil
                state.unsynced.removeAll { $0 == path }
                try store.setState(state)
                try store.removeJournal(path)
            }
            // Board files on this Mac no list names (a board created here while the plugin stopped half way) go too.
            for id in store.boardIDs(.working) where !keepSet.contains(id) { try store.setBoard(nil, id: id, .working) }
        }

        // Only what was committed has a new version recorded (above): a board left with a question keeps the version its base
        // came from, so the next sync reads the place again and asks again instead of taking it for unchanged.
        state.unsynced = Array(Set(state.unsynced).subtracting(keepSet.map(Ids.boardPath)).union(unsynced))
        if !blocked { state.unsynced.removeAll { $0 == "index.json" } }
        if conflicts.isEmpty { state.lastSynced = now() }
        try store.setState(state)
        report.conflicts = conflicts
        log("Sync: \(report.sent) file(s) sent, \(report.received) received, \(report.deleted) deleted, \(conflicts.count) question(s).")
        return report
    }

    private func text<T: Encodable>(_ value: T) throws -> String { String(decoding: try BoardJSON.encode(value), as: UTF8.self) }

    private func commitBoard(_ id: String, _ planned: BoardFile, working: BoardFile?, version: String?, state: inout SyncStateFile, report: inout SyncReport) throws {
        let path = Ids.boardPath(id)
        if working != planned {
            try store.setBoard(planned, id: id, .working)
            report.received += 1
        }
        try store.setBoard(planned, id: id, .base)
        state.versions[path] = version
        state.unsynced.removeAll { $0 == path }
        try store.setState(state)
    }

    private func commitIndex(_ planned: BoardIndexFile, working: BoardIndexFile, version: String?, state: inout SyncStateFile, report: inout SyncReport) throws {
        if working.normalized() != planned {
            try store.setIndex(planned, .working)
            report.received += 1
        }
        try store.setIndex(planned, .base)
        state.versions["index.json"] = version
        state.unsynced.removeAll { $0 == "index.json" }
        try store.setState(state)
    }
}

// MARK: - Conflicts as text

/// Both versions of a record as plain text, for the diff block: what a person compares, never ids.
enum ConflictText {
    static func roleName(_ role: String?) -> String { role.flatMap(Role.init(rawValue:))?.title ?? "None" }

    static func board(_ file: BoardFile) -> String {
        "\(file.tasks.count) task(s) in \(file.columns.count) column(s), \(file.tags.count) tag(s), \(file.comments.count) comment(s)"
    }

    static func column(_ column: ColumnRecord) -> String { "\(column.title)\nColour: \(roleName(column.role))" }

    static func tag(_ tag: TagRecord) -> String { "\(tag.name)\nColour: \(roleName(tag.role))" }

    static func task(_ task: TaskRecord, in file: BoardFile) -> String {
        let column = file.columns.first { $0.id == task.column }?.title ?? "—"
        let tags = task.tags.compactMap { id in file.tags.first { $0.id == id }?.name }
        var lines = [task.title, "Column: \(column)", "Tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))", "Done: \(task.done ? "yes" : "no")"]
        if !task.description.isEmpty { lines += ["", task.description] }
        return lines.joined(separator: "\n")
    }

    static func comment(_ comment: CommentRecord) -> String { "\(comment.author), \(comment.time)\n\n\(comment.text)" }

    static func items(_ merge: BoardMerge, board: String, name: String, mine: BoardFile, theirs: BoardFile) -> [SyncConflictItem] {
        func item<R: BoardRecordType>(_ conflict: RecordConflict<R>, _ subject: SyncConflictItem.Subject, _ label: String, _ title: String,
                                      _ render: (R, BoardFile) -> String) -> SyncConflictItem {
            var choices: [ConflictChoice] = [.keepMine, .keepTheirs]
            if subject == .task, conflict.mine != nil, conflict.theirs != nil { choices.append(.keepBoth) }
            return SyncConflictItem(
                id: conflict.key, boardID: board, boardName: name, subject: subject, recordID: conflict.id, reason: conflict.reason,
                title: "\(label) “\(title)”", mine: conflict.mine.map { render($0, mine) }, theirs: conflict.theirs.map { render($0, theirs) },
                choices: choices, mineDigest: digest(conflict.mine), theirsDigest: digest(conflict.theirs))
        }
        var items: [SyncConflictItem] = []
        items += merge.columns.map { c in item(c, .column, "Column", (c.mine ?? c.theirs ?? c.base)?.title ?? "") { r, _ in column(r) } }
        items += merge.tags.map { c in item(c, .tag, "Tag", (c.mine ?? c.theirs ?? c.base)?.name ?? "") { r, _ in tag(r) } }
        items += merge.tasks.map { c in item(c, .task, "Task", (c.mine ?? c.theirs ?? c.base)?.title ?? "") { r, file in task(r, in: file) } }
        items += merge.comments.map { c in item(c, .comment, "Comment by", (c.mine ?? c.theirs ?? c.base)?.author ?? "") { r, _ in comment(r) } }
        return items
    }
}
