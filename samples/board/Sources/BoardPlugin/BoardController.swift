import Foundation
import VektorPlugin

// The controller: everything the views (the sidebar entry, the board and list views, Board settings, the conflict sheet) ask
// of the plugin, and nothing they draw. A view calls a command (`createBoard`, `moveTask(…)`, `addComment` …), the controller
// changes the active workspace's boards, saves them on this Mac at once, marks them unsynced when a place is set (or, for a
// folder on this Mac, writes them there at once), and calls `onChange` so the view draws again from the queries
// (`boards`, `columns(of:)`, `listRows(of:sort:)` …).
//
// Commands wait for a sync that is running (they never interleave with one), so a sync never misses or overwrites a change.
// Errors are `BoardError`s in plain words, ready for an alert.

/// What changed, so a view draws only what it shows.
public enum BoardChange: Equatable, Sendable {
    /// The list of boards (names, order, created, deleted): the sidebar, the switcher.
    case boards
    /// One board's columns, tasks, tags or comments.
    case board(String)
    /// The sync state: running, progress, last synced, error, conflicts.
    case sync
    /// Another workspace (or another place) is active: everything.
    case workspace
}

/// Where the active workspace's boards are kept.
public enum StorageMode: Equatable, Sendable {
    /// The plugin's own data folder on this Mac (no place chosen). Saved on each change; no sync.
    case thisMac
    /// A folder on this Mac chosen as the place: saved on each change and written there at once; no Sync button.
    case folder(label: String)
    /// A folder on one of the workspace's connections: saved on this Mac at once and marked unsynced; Sync sends and receives.
    case remote(label: String)
}

public struct SyncStatus: Equatable, Sendable {
    public var mode: StorageMode = .thisMac
    public var isSyncing = false
    /// What a running sync is doing ("Board 2 of 5…").
    public var progress: String?
    /// When the last sync finished without an error or a question.
    public var lastSynced: Date?
    /// Changes on this Mac the place does not have yet (or questions not answered yet).
    public var unsynced = false
    /// The last sync's error, in plain words.
    public var error: String?
    /// Questions from the last sync, each with both versions.
    public var conflicts: [SyncConflictItem] = []
    /// Only a place on a connection has a Sync button.
    public var showsSyncButton: Bool { if case .remote = mode { return true } else { return false } }
}

/// What to do with a column's tasks when it is deleted.
public enum ColumnTasks: Equatable, Sendable {
    case moveTo(String)
    case delete
}

@MainActor
public final class BoardController {
    public struct Options {
        /// The author of new comments: the macOS user's name.
        public var author: String
        public var now: @MainActor () -> Date
        public var policy: MergePolicy
        /// The plugin's Log. Never given a record's contents or anything secret: counts and plain words only.
        public var log: @MainActor (String) -> Void
        public init(author: String = BoardController.userName(), now: @escaping @MainActor () -> Date = { Date() }, policy: MergePolicy = .record,
                    log: @escaping @MainActor (String) -> Void = { _ in }) {
            self.author = author
            self.now = now
            self.policy = policy
            self.log = log
        }
    }

    /// The macOS user's full name, else the account name.
    public nonisolated static func userName() -> String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    /// The plugin's data folder. `setup` runs before `startup` tells the plugin where it is, so the plugin sets it again on startup.
    public var dataFolder: URL
    public var options: Options
    /// Called after every change, on the main actor.
    public var onChange: ((BoardChange) -> Void)?
    public private(set) var workspace: Workspace?
    /// Whether a workspace's boards have been read yet (the views show "loading" until they have).
    public var isLoaded: Bool { activated }
    public private(set) var status = SyncStatus()
    /// The error that kept this workspace's boards from loading (they are then not changed, so nothing is overwritten).
    public private(set) var loadError: String?

    private let makePlace: @MainActor (PlaceHandle) -> PlaceStore
    private var store: LocalStore
    private var place: PlaceStore?
    private var index = BoardIndexFile()
    private var files: [String: BoardFile] = [:]
    private var derived: [String: Derived] = [:]
    private var filters: [String: BoardFilter] = [:]
    private var resolutions: [String: ConflictResolution] = [:]
    private let lock = AsyncLock()
    private var autoSyncWanted = false
    private var autoSyncRunning = false
    private var activated = false

    /// `makePlace` turns a `place` setting's handle into a place (the tests wrap Vektor's).
    public init(dataFolder: URL, options: Options = Options(), makePlace: @escaping @MainActor (PlaceHandle) -> PlaceStore) {
        self.dataFolder = dataFolder
        self.options = options
        self.makePlace = makePlace
        store = LocalStore(dataFolder: dataFolder, workspace: nil)
    }

    /// The controller of a running plugin: its data folder, Vektor's storage service, its Log.
    public convenience init(plugin: Plugin, options: Options = Options()) {
        let folder = plugin.dataFolder.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("vektor-board")
        var options = options
        options.log = { [weak plugin] message in plugin?.log(message) }
        self.init(dataFolder: folder, options: options) { [weak plugin] handle in
            guard let plugin else { return UnavailablePlace(label: handle.label, isRemote: handle.remote) }
            return VektorPlace(plugin: plugin, handle: handle)
        }
    }

    // MARK: - Workspace and place

    /// Shows `workspace`'s boards, kept in `place` (nil: the plugin's data folder). Call it after `startup`, after a workspace
    /// switch and when the place setting changes. A folder on this Mac is synced at once (it is the storage).
    public func activate(workspace: Workspace?, place handle: PlaceHandle?) async {
        await lock.run {
            let sameWorkspace = activated && workspace?.id == self.workspace?.id
            let samePlace = handle?.label == place?.label && handle?.remote == place?.isRemote
            if sameWorkspace, samePlace {
                // The same folder: only the handle is new (a handle is valid for one run of Vektor).
                place = handle.map(makePlace)
                return
            }
            activated = true
            self.workspace = workspace
            store = LocalStore(dataFolder: dataFolder, workspace: workspace)
            place = handle.map(makePlace)
            files = [:]
            derived = [:]
            resolutions = [:]
            loadError = nil
            do { index = try store.index(.working) ?? BoardIndexFile() } catch {
                index = BoardIndexFile()
                loadError = (error as? BoardError)?.message ?? "This workspace's boards could not be read."
                options.log("Boards: this workspace's list of boards could not be read; nothing will be changed.")
            }
            let state = store.state()
            status = SyncStatus()
            if let place {
                status.mode = place.isRemote ? .remote(label: place.label) : .folder(label: place.label)
                if state.placeLabel == place.label {
                    status.lastSynced = state.lastSynced.flatMap(Stamp.date)
                    status.unsynced = !state.unsynced.isEmpty
                } else {
                    status.unsynced = !index.boards.isEmpty
                }
            }
            onChange?(.workspace)
        }
        if case .folder = status.mode { requestAutoSync() }
    }

    // MARK: - Boards

    /// The active workspace's boards, in the user's order.
    public var boards: [BoardRecord] { index.boards }

    /// Whether `id` is a board of the active workspace (a view opened for a board of another workspace is not).
    public func contains(_ id: String) -> Bool { index.boards.contains { $0.id == id } }

    public func boardName(_ id: String) -> String? { index.boards.first { $0.id == id }?.name }

    /// The columns a new board starts with (the mock-up's).
    public static let defaultColumns: [(title: String, role: Role?)] = [
        ("Backlog", .neutral), ("In Progress", .label6), ("Review", .label7), ("Done", .label4),
    ]

    @discardableResult
    public func createBoard(name: String, columns: [(title: String, role: Role?)] = BoardController.defaultColumns) async throws -> String {
        try await mutate { [self] in
            let name = try required(name, "A board needs a name.")
            let id = Ids.make("b")
            let stamp = stamp()
            let ranks = Rank.spread(columns.count)
            let file = BoardFile(board: id, columns: zip(columns, ranks).map { column, rank in
                ColumnRecord(id: Ids.make("c"), title: column.title, role: column.role?.rawValue, rank: rank, updatedAt: stamp)
            })
            try save(file)
            index.boards.append(BoardRecord(id: id, name: name, rank: Rank.between(index.boards.last?.rank, nil), updatedAt: stamp))
            try saveIndex()
            options.log("Boards: a board was created.")
            return id
        }
    }

    public func renameBoard(_ id: String, to name: String) async throws {
        try await mutate { [self] in
            let name = try required(name, "A board needs a name.")
            guard let at = index.boards.firstIndex(where: { $0.id == id }) else { throw missingBoard }
            guard index.boards[at].name != name else { return }
            index.boards[at].name = name
            index.boards[at].updatedAt = stamp()
            try saveIndex()
        }
    }

    /// Deletes a board and only its data: its file on this Mac now, its file on the place at the next sync. Ask first.
    public func deleteBoard(_ id: String) async throws {
        try await mutate { [self] in
            guard index.boards.contains(where: { $0.id == id }) else { throw missingBoard }
            index.boards.removeAll { $0.id == id }
            try store.setBoard(nil, id: id, .working)
            files[id] = nil
            derived[id] = nil
            filters[id] = nil
            markUnsynced(Ids.boardPath(id))
            try saveIndex()
            options.log("Boards: a board was deleted.")
        }
    }

    /// Moves a board to `index` in the list.
    public func moveBoard(_ id: String, to position: Int) async throws {
        try await mutate { [self] in
            guard let at = index.boards.firstIndex(where: { $0.id == id }) else { throw missingBoard }
            let others = index.boards.filter { $0.id != id }.map(\.rank)
            index.boards[at].rank = rank(at: position, in: others)
            index.boards[at].updatedAt = stamp()
            index = index.normalized()
            try saveIndex()
        }
    }

    // MARK: - Columns

    @discardableResult
    public func addColumn(to board: String, title: String, role: Role? = nil, at position: Int? = nil) async throws -> String {
        try await change(board) { [self] file in
            let title = try required(title, "A column needs a name.")
            let id = Ids.make("c")
            let ranks = file.columns.map(\.rank)
            file.columns.append(ColumnRecord(id: id, title: title, role: role?.rawValue, rank: rank(at: position ?? ranks.count, in: ranks), updatedAt: stamp()))
            return id
        }
    }

    public func renameColumn(_ column: String, in board: String, to title: String) async throws {
        try await change(board) { [self] file in
            let title = try required(title, "A column needs a name.")
            try edit(&file.columns, column, missing: "That column no longer exists.") { $0.title = title }
        }
    }

    public func setColumnRole(_ column: String, in board: String, to role: Role?) async throws {
        try await change(board) { [self] file in
            try edit(&file.columns, column, missing: "That column no longer exists.") { $0.role = role?.rawValue }
        }
    }

    public func moveColumn(_ column: String, in board: String, to position: Int) async throws {
        try await change(board) { [self] file in
            let others = file.columns.filter { $0.id != column }.map(\.rank)
            let rank = rank(at: position, in: others)
            try edit(&file.columns, column, missing: "That column no longer exists.") { $0.rank = rank }
        }
    }

    /// Deletes a column; its tasks move to another column (at its end, in their order) or are deleted with their comments.
    public func deleteColumn(_ column: String, in board: String, tasks: ColumnTasks) async throws {
        try await change(board) { [self] file in
            guard file.columns.contains(where: { $0.id == column }) else { throw BoardError("That column no longer exists.") }
            let moving = file.tasks.filter { $0.column == column }.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
            switch tasks {
            case .moveTo(let target):
                guard target != column, file.columns.contains(where: { $0.id == target }) else { throw BoardError("Choose another column for its tasks.") }
                var last = file.tasks.filter { $0.column == target }.map(\.rank).max()
                let stamp = stamp()
                for task in moving {
                    let rank = Rank.between(last, nil)
                    last = rank
                    if let at = file.tasks.firstIndex(where: { $0.id == task.id }) {
                        file.tasks[at].column = target
                        file.tasks[at].rank = rank
                        file.tasks[at].updatedAt = stamp
                    }
                }
            case .delete:
                let gone = Set(moving.map(\.id))
                file.tasks.removeAll { gone.contains($0.id) }
                file.comments.removeAll { gone.contains($0.task) }
            }
            file.columns.removeAll { $0.id == column }
        }
    }

    // MARK: - Tasks

    /// Adds a task to a column: at its end, or at `position` among the tasks the column shows now (a filter may hide some).
    @discardableResult
    public func addTask(to board: String, column: String, title: String, description: String = "", tags: [String] = [], at position: Int? = nil) async throws -> String {
        try await change(board) { [self] file in
            let title = try required(title, "A task needs a title.")
            guard file.columns.contains(where: { $0.id == column }) else { throw BoardError("That column no longer exists.") }
            let known = Set(file.tags.map(\.id))
            let id = Ids.make("t")
            let rank = taskRank(in: file, board: board, column: column, position: position, excluding: nil)
            let stamp = stamp()
            file.tasks.append(TaskRecord(
                id: id, column: column, rank: rank, title: title, description: description, tags: unique(tags).filter(known.contains), createdAt: stamp,
                updatedAt: stamp))
            return id
        }
    }

    /// Changes a task's fields; nil leaves a field as it is.
    public func updateTask(_ task: String, in board: String, title: String? = nil, description: String? = nil, tags: [String]? = nil, done: Bool? = nil) async throws {
        try await change(board) { [self] file in
            let title = try title.map { try required($0, "A task needs a title.") }
            let known = Set(file.tags.map(\.id))
            try edit(&file.tasks, task, missing: "That task no longer exists.") { record in
                if let title { record.title = title }
                if let description { record.description = description }
                if let tags { record.tags = unique(tags).filter(known.contains) }
                if let done { record.done = done }
            }
        }
    }

    public func setDone(_ task: String, in board: String, _ done: Bool) async throws {
        try await updateTask(task, in: board, done: done)
    }

    /// Sets a task's tags by name (what a tag picker sends): names the board has no tag for become new tags.
    public func setTaskTags(_ task: String, in board: String, names: [String]) async throws {
        try await change(board) { [self] file in
            var ids: [String] = []
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if let tag = file.tags.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                    ids.append(tag.id)
                } else {
                    let id = Ids.make("g")
                    file.tags.append(TagRecord(id: id, name: name, role: nextTagRole(file).rawValue, rank: Rank.between(file.tags.map(\.rank).max(), nil), updatedAt: stamp()))
                    ids.append(id)
                }
            }
            let tags = unique(ids)
            try edit(&file.tasks, task, missing: "That task no longer exists.") { $0.tags = tags }
        }
    }

    /// Moves a task to `column` at `position` — counted among the tasks the column SHOWS (a filter or search may hide some, which
    /// keep their place), once the task is out of its old place: exactly the `index` of a block view's move event.
    public func moveTask(_ task: String, in board: String, to column: String, at position: Int) async throws {
        try await change(board) { [self] file in
            guard file.columns.contains(where: { $0.id == column }) else { throw BoardError("That column no longer exists.") }
            let rank = taskRank(in: file, board: board, column: column, position: position, excluding: task)
            try edit(&file.tasks, task, missing: "That task no longer exists.") { record in
                record.column = column
                record.rank = rank
            }
        }
    }

    /// Deletes tasks (one, or a whole selection) with their comments.
    public func deleteTasks(_ tasks: [String], in board: String) async throws {
        try await change(board) { file in
            let gone = Set(tasks)
            guard file.tasks.contains(where: { gone.contains($0.id) }) else { throw BoardError("That task no longer exists.") }
            file.tasks.removeAll { gone.contains($0.id) }
            file.comments.removeAll { gone.contains($0.task) }
        }
    }

    public func deleteTask(_ task: String, in board: String) async throws { try await deleteTasks([task], in: board) }

    // MARK: - Tags

    @discardableResult
    public func addTag(to board: String, name: String, role: Role? = nil) async throws -> String {
        try await change(board) { [self] file in
            let name = try uniqueTagName(name, in: file, except: nil)
            let id = Ids.make("g")
            file.tags.append(TagRecord(id: id, name: name, role: (role ?? nextTagRole(file)).rawValue, rank: Rank.between(file.tags.map(\.rank).max(), nil), updatedAt: stamp()))
            return id
        }
    }

    public func renameTag(_ tag: String, in board: String, to name: String) async throws {
        try await change(board) { [self] file in
            let name = try uniqueTagName(name, in: file, except: tag)
            try edit(&file.tags, tag, missing: "That tag no longer exists.") { $0.name = name }
        }
    }

    public func setTagRole(_ tag: String, in board: String, to role: Role?) async throws {
        try await change(board) { [self] file in
            try edit(&file.tags, tag, missing: "That tag no longer exists.") { $0.role = role?.rawValue }
        }
    }

    public func moveTag(_ tag: String, in board: String, to position: Int) async throws {
        try await change(board) { [self] file in
            let others = file.tags.filter { $0.id != tag }.map(\.rank)
            let rank = rank(at: position, in: others)
            try edit(&file.tags, tag, missing: "That tag no longer exists.") { $0.rank = rank }
        }
    }

    /// Deletes a tag and takes it off every task that had it.
    public func deleteTag(_ tag: String, in board: String) async throws {
        try await change(board) { [self] file in
            guard file.tags.contains(where: { $0.id == tag }) else { throw BoardError("That tag no longer exists.") }
            file.tags.removeAll { $0.id == tag }
            let stamp = stamp()
            for at in file.tasks.indices where file.tasks[at].tags.contains(tag) {
                file.tasks[at].tags.removeAll { $0 == tag }
                file.tasks[at].updatedAt = stamp
            }
            if var filter = filters[board], filter.tags.contains(tag) {
                filter.tags.removeAll { $0 == tag }
                filters[board] = filter
            }
        }
    }

    // MARK: - Comments

    /// Adds a comment by the macOS user (`options.author`), now.
    @discardableResult
    public func addComment(to task: String, in board: String, text: String) async throws -> String {
        try await change(board) { [self] file in
            let text = try required(text, "A comment needs some text.")
            guard file.tasks.contains(where: { $0.id == task }) else { throw BoardError("That task no longer exists.") }
            let id = Ids.make("m")
            let stamp = stamp()
            file.comments.append(CommentRecord(id: id, task: task, author: options.author, time: stamp, text: text, updatedAt: stamp))
            return id
        }
    }

    /// Whether the user may delete a comment: their own only.
    public func canDelete(comment: CommentRecord) -> Bool { comment.author == options.author }

    public func deleteComment(_ comment: String, in board: String) async throws {
        try await change(board) { [self] file in
            guard let record = file.comments.first(where: { $0.id == comment }) else { throw BoardError("That comment no longer exists.") }
            guard canDelete(comment: record) else { throw BoardError("Only its author can delete a comment.") }
            file.comments.removeAll { $0.id == comment }
        }
    }

    // MARK: - Sync

    /// Sends and receives (a place on a connection), or writes the folder (a folder on this Mac). Nil without a place. Never
    /// loses an unsynced change; the report's conflicts are in `status.conflicts` until answered.
    @discardableResult
    public func sync() async -> SyncReport? {
        await lock.run { await runSync() }
    }

    /// Answers a conflict of the last sync. When every question is answered the answers are applied with a sync.
    public func resolveConflict(_ id: String, _ choice: ConflictChoice) async throws {
        guard let item = status.conflicts.first(where: { $0.id == id }) else { throw BoardError("That question is no longer open: sync again.") }
        guard item.choices.contains(choice) else { throw BoardError("That answer does not apply here.") }
        resolutions[id] = ConflictResolution(choice: choice, mine: item.mineDigest, theirs: item.theirsDigest, copyID: choice == .keepBoth ? Ids.make("t") : nil)
        status.conflicts.removeAll { $0.id == id }
        onChange?(.sync)
        if status.conflicts.isEmpty { await sync() }
    }

    /// Waits until a running or wanted automatic sync (a folder on this Mac) is done.
    public func settle() async {
        while autoSyncRunning || autoSyncWanted { try? await Task.sleep(nanoseconds: 5_000_000) }
        await lock.run {}
    }

    private func runSync() async -> SyncReport? {
        guard let place, loadError == nil else { return nil }
        status.isSyncing = true
        status.error = nil
        status.progress = nil
        onChange?(.sync)
        let engine = SyncEngine(
            store: store, place: place, policy: options.policy, resolutions: resolutions, now: { [self] in stamp() }, log: options.log,
            progress: { [weak self] text in
                self?.status.progress = text
                self?.onChange?(.sync)
            })
        var report: SyncReport?
        do {
            let done = try await engine.run()
            report = done
            // Answers stay until the board they are about has been written (a board with other open questions is not).
            let open = Set(done.conflicts.map { $0.id.split(separator: "|").first.map(String.init) ?? "" })
            resolutions = resolutions.filter { open.contains(String($0.key.split(separator: "|").first ?? "")) }
            status.conflicts = done.conflicts
            reloadAfterSync()
        } catch {
            status.error = (error as? BoardError)?.message ?? (error as? PluginError)?.message ?? "The sync failed. Nothing was lost; try again."
            options.log("Sync: it stopped with an error; nothing was lost.")
            reloadAfterSync()
        }
        let state = store.state()
        status.lastSynced = state.lastSynced.flatMap(Stamp.date)
        status.unsynced = !state.unsynced.isEmpty || !status.conflicts.isEmpty
        status.isSyncing = false
        status.progress = nil
        onChange?(.sync)
        return report
    }

    private func reloadAfterSync() {
        let before = index
        do {
            index = try store.index(.working) ?? BoardIndexFile()
        } catch {
            status.error = (error as? BoardError)?.message
        }
        let previous = files
        files = [:]
        derived = [:]
        if before != index { onChange?(.boards) }
        for id in Set(previous.keys).union(index.boards.map(\.id)) where (try? store.board(id, .working)) != previous[id] {
            onChange?(.board(id))
        }
    }

    private func requestAutoSync() {
        autoSyncWanted = true
        guard !autoSyncRunning else { return }
        autoSyncRunning = true
        Task { @MainActor [weak self] in
            while let self, self.autoSyncWanted {
                self.autoSyncWanted = false
                await self.sync()
            }
            self?.autoSyncRunning = false
        }
    }

    // MARK: - Reading

    /// A board's data, or nil when it is not a board of the active workspace.
    public func file(_ board: String) -> BoardFile? { try? load(board) }

    // MARK: - Internals

    var missingBoard: BoardError { BoardError("That board is not in this workspace any more.") }

    private func stamp() -> String { Stamp.string(options.now()) }

    private func required(_ text: String, _ problem: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError(problem) }
        return trimmed
    }

    func load(_ board: String) throws -> BoardFile {
        if let file = files[board] { return file }
        guard index.boards.contains(where: { $0.id == board }) else { throw missingBoard }
        let file = try store.board(board, .working) ?? BoardFile(board: board)
        files[board] = file
        return file
    }

    /// Runs a change of the active workspace under the lock (after a running sync), refusing it while the boards could not be read.
    private func mutate<T>(_ body: () throws -> T) async throws -> T {
        try await lock.run {
            if let loadError { throw BoardError(loadError) }
            return try body()
        }
    }

    /// Changes one board's file: saved at once, `updatedAt` set on every record that changed.
    private func change<T>(_ board: String, _ body: (inout BoardFile) throws -> T) async throws -> T {
        try await mutate {
            var file = try load(board)
            let before = file
            let result = try body(&file)
            guard file != before else { return result }
            file = stamped(file, before: before)
            try save(file)
            return result
        }
    }

    /// Sets `updatedAt` on the records that changed.
    private func stamped(_ file: BoardFile, before: BoardFile) -> BoardFile {
        let now = stamp()
        func touch<R: BoardRecordType>(_ records: [R], _ old: [R]) -> [R] {
            let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return records.map { record in
                guard let was = previous[record.id], was.sameContent(as: record) else {
                    var changed = record
                    if previous[record.id] != nil || record.updatedAt.isEmpty { changed.updatedAt = now }
                    return changed
                }
                return record
            }
        }
        var file = file
        file.columns = touch(file.columns, before.columns)
        file.tasks = touch(file.tasks, before.tasks)
        file.tags = touch(file.tags, before.tags)
        file.comments = touch(file.comments, before.comments)
        return file.normalized()
    }

    private func save(_ file: BoardFile) throws {
        let file = file.normalized()
        try store.setBoard(file, id: file.board, .working)
        files[file.board] = file
        derived[file.board] = nil
        markUnsynced(Ids.boardPath(file.board))
        onChange?(.board(file.board))
        afterChange()
    }

    private func saveIndex() throws {
        index = index.normalized()
        try store.setIndex(index, .working)
        markUnsynced("index.json")
        onChange?(.boards)
        afterChange()
    }

    /// Recorded even without a place, so a place chosen (again) later knows what changed here meanwhile.
    private func markUnsynced(_ path: String) {
        var state = store.state()
        if !state.unsynced.contains(path) {
            state.unsynced.append(path)
            try? store.setState(state)
        }
        guard place != nil else { return }
        if !status.unsynced {
            status.unsynced = true
            onChange?(.sync)
        }
    }

    private func afterChange() {
        if case .folder = status.mode { requestAutoSync() }
    }

    private func edit<R: BoardRecordType>(_ records: inout [R], _ id: String, missing: String, _ body: (inout R) throws -> Void) throws {
        guard let at = records.firstIndex(where: { $0.id == id }) else { throw BoardError(missing) }
        try body(&records[at])
    }

    private func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// A rank for position `position` among `ranks` (sorted, without the record that moves).
    private func rank(at position: Int, in ranks: [String]) -> String {
        let sorted = ranks.sorted()
        let at = max(0, min(position, sorted.count))
        let low = at > 0 ? sorted[at - 1] : nil
        // Two records with the same rank (two Macs inserted at the same place) cannot have a third between them: it goes after both.
        let high = sorted[at...].first { low == nil || $0 > low! }
        return Rank.between(low, high)
    }

    /// The rank of a task put at `position` among the tasks `column` shows (the board's filter applies); past the end: last.
    private func taskRank(in file: BoardFile, board: String, column: String, position: Int?, excluding task: String?) -> String {
        let all = file.tasks.filter { $0.column == column && $0.id != task }.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
        let filter = filters[board] ?? BoardFilter()
        let tags = Dictionary(file.tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shown = filter.isActive ? all.filter { filter.matches($0, tags: tags) } : all
        guard let position, position >= 0, position < shown.count else { return Rank.between(all.last?.rank, nil) }
        // Right before the shown task now at `position`; hidden tasks keep their place.
        let next = shown[position]
        let at = all.firstIndex { $0.id == next.id }!
        return rank(at: at, in: all.map(\.rank))
    }

    private func uniqueTagName(_ name: String, in file: BoardFile, except: String?) throws -> String {
        let name = try required(name, "A tag needs a name.")
        if file.tags.contains(where: { $0.id != except && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            throw BoardError("This board already has a tag “\(name)”.")
        }
        return name
    }

    /// The label role the fewest tags use, so new tags differ.
    private func nextTagRole(_ file: BoardFile) -> Role {
        let labels: [Role] = [.label6, .label4, .label7, .label2, .label5, .label8, .label3, .label1]
        let used = Dictionary(grouping: file.tags.compactMap(\.role), by: { $0 }).mapValues(\.count)
        return labels.min { (used[$0.rawValue] ?? 0) < (used[$1.rawValue] ?? 0) } ?? .label6
    }

    // MARK: Filters and derived data (BoardQueries.swift)

    func filterValue(_ board: String) -> BoardFilter { filters[board] ?? BoardFilter() }
    func setFilterValue(_ filter: BoardFilter, _ board: String) { filters[board] = filter }
    func derivedValue(_ board: String) -> Derived? {
        if let cached = derived[board] { return cached }
        guard let file = try? load(board) else { return nil }
        let value = Derived(file)
        derived[board] = value
        return value
    }
}

/// A place the controller can no longer reach (the plugin is gone): every call fails in plain words.
@MainActor
final class UnavailablePlace: PlaceStore {
    let label: String
    let isRemote: Bool
    init(label: String, isRemote: Bool) {
        self.label = label
        self.isRemote = isRemote
    }
    private var gone: BoardError { BoardError("The place cannot be reached right now.") }
    func list(_ folder: String) async throws -> [StorageEntry] { throw gone }
    func read(_ path: String) async throws -> (data: Data, version: String)? { throw gone }
    func write(_ path: String, data: Data, ifVersion: IfVersion) async throws -> String { throw gone }
    func delete(_ path: String, ifVersion: String) async throws { throw gone }
    func createFolder(_ path: String) async throws { throw gone }
}

/// One change at a time: a command waits for a running sync, a sync for a running command. In order of arrival.
@MainActor
final class AsyncLock {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}
