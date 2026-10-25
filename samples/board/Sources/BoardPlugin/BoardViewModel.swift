import Foundation
import VektorPlugin

// What the user sees and does: the view's state (which board, which screen, the list's sort and selection), the dialogs the
// view asks, and the routing of every event of the view to a controller command. What the blocks look like is in
// BoardScreens.swift; this file never builds a block.
//
// How the view stays cheap (a board of thousands of tasks):
//   * The controller keeps one index per board (`Derived`), made once per change, so drawing is one pass over the tasks.
//   * A change asks for a redraw (`requestDraw`); several changes in a row (a sync writing ten boards, a column deleted with its
//     tasks) are drawn once, on the next turn of the main actor.
//   * A redraw is `view.show`: the SDK compares the new tree with the last one by id and sends a few `move`, `replace`,
//     `insert` or `remove` operations (a task dragged to another column is one `move`), never the whole board. Card ids are the
//     tasks' own ids, so a card is never rebuilt because something above it moved.
//   * An answer Vektor refused is handled by the SDK (`view/refused`): the whole description is sent again, and the events that
//     were made against what Vektor still showed are not dropped as stale.

/// Which of the view's screens is open on top of the board (or the list).
public enum BoardOverlay: Equatable, Sendable {
    case task(String)
    case settings
    case conflicts
}

/// The board view's two ways of showing the same tasks.
public enum BoardLayout: String, Sendable, CaseIterable {
    case board, list
}

/// The names of the view's blocks and actions: `board.cadd.<column>` is the "+" of a column. Every action is the prefix of the
/// ids of the blocks that send it, so an event's block says which column, task or tag it is about.
let names = LayoutNames("board")

@MainActor
public final class BoardViewModel {
    let plugin: Plugin
    let controller: BoardController
    let view: ViewState

    /// Asks a dialog. The plugin's own (`plugin.showDialog`) unless a test scripts the answers.
    public var ask: @MainActor (DialogShowParams) async throws -> DialogShowResult
    /// Asks "are you sure?". The plugin's own unless a test scripts the answers.
    public var confirm: @MainActor (ConfirmParams) async throws -> Bool

    /// The board the view was opened for or the user switched to; nil: the first board.
    var current: String?
    var layout = BoardLayout.board
    var overlay: BoardOverlay?
    var listSort = ListSort()
    var listSelected: [String] = []
    var settingsTab = "columns"
    /// A conflict's block-id digest → its id, rebuilt on every draw of the conflict screen.
    var conflictLookup: [String: String] = [:]
    /// Counts the comments added, so the composer's field is a new field (and empty) after each one.
    var composer = 0
    /// Counts "Clear Filters", so the search field is a new field after it: Vektor keeps a focused field's typed text over a
    /// new value from the plugin, and the click away that the button itself is committed that text again (seen in Vektor:
    /// the search came straight back).
    var searchField = 0
    /// Why the view could not be shown (Vektor refused it), until the user tries again.
    var failure: String?
    /// Called when the board shown changes (the sidebar marks it).
    var onCurrentChange: (() -> Void)?

    private var drawQueued = false
    /// The next draw is the whole description, even if nothing changed (a refused field must show the real value again).
    private var sendWhole = false
    private var knownConflicts = 0
    private var shownForSidebar: String?

    public init(plugin: Plugin, controller: BoardController, view: ViewState) {
        self.plugin = plugin
        self.controller = controller
        self.view = view
        ask = { [weak plugin] params in
            guard let plugin else { throw BoardError("The plugin is stopping.") }
            return try await plugin.showDialog(params)
        }
        confirm = { [weak plugin] params in
            guard let plugin else { return false }
            return try await plugin.confirm(params)
        }
        view.onOpen { [weak self] opened in self?.opened(item: opened.item) }
        view.onRefused { [weak self] refusal in self?.refused(refusal) }
        view.onAnyEvent { [weak self] event in await self?.route(event) }
    }

    // MARK: - Which board

    /// The board the view shows: the chosen one, else the first. Nil when there is none or the chosen one belongs to another
    /// workspace (`isForeign`).
    var boardID: String? {
        if let current { return controller.contains(current) ? current : nil }
        return controller.boards.first?.id
    }

    /// The view was opened for a board that is not in this workspace.
    var isForeign: Bool { current.map { !controller.contains($0) } ?? false }

    func opened(item: String?) {
        if let item, item != current {
            overlay = nil
            listSelected = []
        }
        if let item {
            current = item
        } else if let shown = current, !controller.contains(shown) {
            // The entry itself (no item) opens this workspace's boards: a board remembered from another workspace is not
            // "this board belongs to another workspace" here (seen in Vektor: the Board entry, clicked after a switch).
            current = nil
            overlay = nil
        }
        failure = nil
        drawNow()
        noteCurrent()
        startClock()
    }

    /// "Last synced 3 minutes ago" ages while nothing else changes: draw again once a minute while the view is open and has a
    /// Sync button (the redraw is a one-word patch).
    private var clock: Task<Void, Never>?
    private func startClock() {
        clock?.cancel()
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.view.isOpen else { return }
                if self.controller.status.showsSyncButton, self.controller.status.lastSynced != nil { self.requestDraw() }
            }
        }
    }

    /// Shows another board (the switcher, a new board).
    func show(board: String) {
        guard board != current else { return }
        current = board
        overlay = nil
        listSelected = []
        requestDraw()
        noteCurrent()
    }

    private func noteCurrent() {
        guard shownForSidebar != boardID else { return }
        shownForSidebar = boardID
        onCurrentChange?()
    }

    // MARK: - Drawing

    /// The controller changed something: draws what the open view shows, once for any number of changes in a row.
    func changed(_ change: BoardChange) {
        switch change {
        case .workspace:
            overlay = nil
            listSelected = []
            knownConflicts = 0
        case .boards:
            if let current, !controller.contains(current), isOpenOverlayOnBoard { overlay = nil }
        case .sync:
            // A sync that ends with questions takes the user to them: nothing resolves silently.
            let open = controller.status.conflicts.count
            if open > 0, knownConflicts == 0, !controller.status.isSyncing { overlay = .conflicts }
            if open == 0, overlay == .conflicts { overlay = nil }
            if !controller.status.isSyncing || open == 0 { knownConflicts = open }
        case .board(let id):
            guard id == boardID else { return }
            // A task opened in detail that is gone (deleted here, or by a sync): back to the board.
            if case .task(let task)? = overlay, controller.task(task, in: id) == nil { overlay = nil }
        }
        requestDraw()
        noteCurrent()
    }

    private var isOpenOverlayOnBoard: Bool {
        switch overlay {
        case .task, .settings: return true
        default: return false
        }
    }

    /// Waits until a draw that was asked for has been made (for the tests, and for a caller that must see the view as sent).
    public func settle() async {
        while drawQueued { await Task.yield() }
    }

    func requestDraw() {
        guard view.isOpen, !drawQueued else { return }
        drawQueued = true
        Task { @MainActor [weak self] in
            self?.drawQueued = false
            self?.drawNow()
        }
    }

    func drawNow() {
        guard view.isOpen else { return }
        do {
            try present(describe())
        } catch {
            // Vektor would refuse it (the SDK checked): say so instead of leaving the view as it was.
            let problem = (error as? PluginError)?.message ?? "The board could not be drawn."
            plugin.log("Board: the view could not be shown: \(problem)")
            failure = problem
            try? view.update(describe())
        }
    }

    /// Sends `description` as the smallest thing that says it: nothing, a patch (the SDK compares the two trees by id, in time
    /// linear in their size: a card dragged to another column is one `move` and the two counts' `replace`s), or the whole
    /// description when a patch cannot say it or would not be smaller.
    func present(_ description: ViewDescription) throws {
        // The sidebar marks the board shown, also after a switch inside the view (`item`, plugin API 2).
        var description = description
        description.other["item"] = boardID.map(JSONValue.string) ?? .null
        if sendWhole {
            sendWhole = false
            return try view.update(description)
        }
        try view.show(description)
    }

    func refused(_ refusal: ViewRefusal) {
        plugin.log("Board: Vektor could not show the view (\(refusal.kind?.rawValue ?? "view")): \(refusal.problem)")
        // A refused patch is answered by the SDK with the whole description. A refused whole description would be refused again:
        // show why instead (and a way to try again).
        guard refusal.kind == .description, failure == nil else { return }
        failure = refusal.problem
        try? view.update(describe())
    }

    // MARK: - Events

    /// Runs what a control asked for; a refusal (`BoardError`) is an alert in plain words and the controls snap back.
    func act(_ work: () async throws -> Void) async {
        do { try await work() } catch {
            let message = (error as? BoardError)?.message ?? (error as? PluginError)?.message ?? "That did not work. Nothing was changed."
            plugin.alert(title: "Board", message: message)
            // A text field that was refused keeps what the user typed: describing it again puts the real value back.
            view.invalidate()
            sendWhole = true
            requestDraw()
        }
    }

    func route(_ event: ViewEvent) async {
        await act { try await self.handle(event) }
    }

    private func handle(_ event: ViewEvent) async throws {
        let action = event.action
        let block = event.block
        func rest(_ kind: String) -> String? { names.rest(kind, of: block) }
        let board = boardID

        switch action {
        // The bar, the header, the "…" menu.
        case names.id("switch"):
            if let id = event.text, controller.contains(id) { show(board: id) }
        case names.id("layout"):
            layout = BoardLayout(rawValue: event.text ?? "") ?? .board
            listSelected = []
            requestDraw()
        case names.id("status"):
            guard let board else { return }
            var filter = controller.filter(of: board)
            filter.status = BoardFilter.Status(rawValue: event.text ?? "") ?? .all
            controller.setFilter(filter, for: board)
        case names.id("search"):
            // The text of a search field that "Clear Filters" has replaced is not a search any more.
            guard let board, event.block == nil || event.block == searchFieldID else { return }
            var filter = controller.filter(of: board)
            filter.search = event.text ?? ""
            controller.setFilter(filter, for: board)
        case names.id("clear"):
            searchField += 1
            if let board { controller.setFilter(BoardFilter(), for: board) }
        case names.id("tagsclear"):
            guard let board else { return }
            var filter = controller.filter(of: board)
            filter.tags = []
            controller.setFilter(filter, for: board)
        case names.id("tagsedit"):
            settingsTab = "tags"
            overlay = .settings
            requestDraw()
        case names.id("sync"):
            try await sync()
        case names.id("add"):
            if let board { try await askNewTask(board: board, column: nil) }
        case names.id("m", "settings"):
            overlay = .settings
            requestDraw()
        case names.id("m", "column"):
            if let board { try await askNewColumn(board: board) }
        case names.id("m", "rename"):
            if let board { try await askRenameBoard(board) }
        case names.id("m", "delete"):
            if let board { try await askDeleteBoard(board) }
        case names.id("m", "new"):
            try await askNewBoard()
        case names.id("m", "conflicts"), names.id("review"):
            overlay = .conflicts
            requestDraw()
        case names.id("back"):
            overlay = nil
            requestDraw()
        case names.id("first"):
            current = nil
            overlay = nil
            requestDraw()
            noteCurrent()
        case names.id("retry"):
            failure = nil
            view.invalidate()
            drawNow()

        // Columns.
        case names.id("cadd"):
            if let board, let column = rest("cadd") { try await askNewTask(board: board, column: column) }
        case names.id("c", "add"):
            if let board, let column = rest("colmenu") { try await askNewTask(board: board, column: column) }
        case names.id("c", "rename"):
            if let board, let column = rest("colmenu") { try await askRenameColumn(column, in: board) }
        case names.id("c", "colour"):
            if let board, let column = rest("colmenu") { try await askColumnColour(column, in: board) }
        case names.id("c", "left"), names.id("c", "right"):
            guard let board, let column = rest("colmenu"), let at = controller.columns(of: board).firstIndex(where: { $0.column.id == column }) else { return }
            try await controller.moveColumn(column, in: board, to: action == names.id("c", "left") ? at - 1 : at + 1)
        case names.id("c", "delete"):
            if let board, let column = rest("colmenu") { try await askDeleteColumn(column, in: board) }

        // Cards and rows.
        case names.id("done"):
            if let board, let task = block { try await controller.setDone(task, in: board, event.value?.boolValue ?? false) }
        case names.id("tick"):
            // The card's own done circle: a button, so it toggles. Its id is the task's id and `.tick`.
            guard let board, let block, block.hasSuffix(".tick") else { return }
            let task = String(block.dropLast(5))
            guard let item = controller.task(task, in: board) else { return }
            try await controller.setDone(task, in: board, !item.task.done)
        case names.id("rename"):
            if let board, let task = block { try await controller.updateTask(task, in: board, title: event.text ?? "") }
        case names.id("remove"), names.id("rdelete"):
            guard let board else { return }
            let ids = event.selected ?? block.map { [$0] } ?? []
            try await askDeleteTasks(ids, in: board)
        case names.id("deletesel"):
            if let board { try await askDeleteTasks(listSelected, in: board) }
        case names.id("open"), names.id("k", "open"):
            if let block, let board, controller.task(block, in: board) != nil {
                overlay = .task(block)
                requestDraw()
            }
        case names.id("k", "done"):
            guard let board, let block, let task = controller.task(block, in: board) else { return }
            try await controller.setDone(block, in: board, !task.task.done)
        case names.id("k", "delete"):
            if let board, let block { try await askDeleteTasks([block], in: board) }
        case names.id("move"):
            guard let board, let task = event.item, let column = names.rest("list", of: event.target) else { return }
            try await controller.moveTask(task, in: board, to: column, at: event.index ?? 0)
        case names.id("sort"):
            guard let key = event.column.flatMap(ListSort.Key.init(rawValue:)) else { return }
            listSort = ListSort(key, ascending: event.ascending ?? true)
            requestDraw()
        case names.id("select"):
            listSelected = event.selected ?? []
            requestDraw()

        // One task.
        case names.id("t", "title"):
            if let board, case .task(let task)? = overlay { try await controller.updateTask(task, in: board, title: event.text ?? "") }
        case names.id("t", "done"):
            if let board, case .task(let task)? = overlay { try await controller.setDone(task, in: board, event.value?.boolValue ?? false) }
        case names.id("t", "column"):
            guard let board, case .task(let task)? = overlay, let column = event.text else { return }
            // At the end of the column it goes to.
            let total = controller.columns(of: board).first { $0.column.id == column }?.total ?? 0
            try await controller.moveTask(task, in: board, to: column, at: total)
        case names.id("t", "tags"):
            if let board, case .task(let task)? = overlay {
                try await controller.setTaskTags(task, in: board, names: event.value?.arrayValue?.compactMap(\.stringValue) ?? [])
            }
        case names.id("t", "desc"):
            if let board, case .task(let task)? = overlay { try await controller.updateTask(task, in: board, description: event.text ?? "") }
        case names.id("t", "delete"):
            if let board, case .task(let task)? = overlay { try await askDeleteTasks([task], in: board) }
        case names.id("cm", "add"):
            guard let board, case .task(let task)? = overlay else { return }
            let text = event.text ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            composer += 1
            try await controller.addComment(to: task, in: board, text: text)
        case names.id("cm", "send"):
            // Send: the click takes the keyboard out of the comment box, and leaving it commits the text (`cm.add`).
            break
        case names.id("cmdel"):
            guard let board, let comment = rest("cmdel") else { return }
            try await controller.deleteComment(comment, in: board)

        // Board settings.
        case names.id("stab"):
            settingsTab = event.text ?? "columns"
            requestDraw()
        case names.id("scname"):
            if let board, let column = rest("scname") { try await controller.renameColumn(column, in: board, to: event.text ?? "") }
        case names.id("scrole"):
            if let board, let column = rest("scrole") { try await controller.setColumnRole(column, in: board, to: Role(rawValue: event.text ?? "")) }
        case names.id("scup"), names.id("scdown"):
            let kind = action == names.id("scup") ? "scup" : "scdown"
            guard let board, let column = rest(kind), let at = controller.columns(of: board).firstIndex(where: { $0.column.id == column }) else { return }
            try await controller.moveColumn(column, in: board, to: kind == "scup" ? at - 1 : at + 1)
        case names.id("scdel"):
            if let board, let column = rest("scdel") { try await askDeleteColumn(column, in: board) }
        case names.id("scadd"):
            if let board { try await askNewColumn(board: board) }
        case names.id("stname"):
            if let board, let tag = rest("stname") { try await controller.renameTag(tag, in: board, to: event.text ?? "") }
        case names.id("strole"):
            if let board, let tag = rest("strole") { try await controller.setTagRole(tag, in: board, to: Role(rawValue: event.text ?? "")) }
        case names.id("stup"), names.id("stdown"):
            let kind = action == names.id("stup") ? "stup" : "stdown"
            guard let board, let tag = rest(kind), let at = controller.tags(of: board).firstIndex(where: { $0.id == tag }) else { return }
            try await controller.moveTag(tag, in: board, to: kind == "stup" ? at - 1 : at + 1)
        case names.id("stdel"):
            guard let board, let tag = rest("stdel") else { return }
            let name = controller.tags(of: board).first { $0.id == tag }?.name ?? "this tag"
            let sure = try await confirm(ConfirmParams(
                title: "Delete the tag “\(name)”?", message: "It is taken off every task that has it. The tasks stay.", confirmTitle: "Delete"))
            if sure { try await controller.deleteTag(tag, in: board) }
        case names.id("stadd"):
            if let board { try await askNewTag(board: board) }
        case names.id("gname"):
            if let board { try await controller.renameBoard(board, to: event.text ?? "") }
        case names.id("gdelete"):
            if let board { try await askDeleteBoard(board) }

        // Questions after a sync.
        case names.id("resolve"):
            try await resolve(block: block)

        default:
            // A tag of the Tags filter: the action names the tag (a menu item's event names only the menu).
            if let tag = names.rest("ftag", of: action), let board {
                var filter = controller.filter(of: board)
                if filter.tags.contains(tag) { filter.tags.removeAll { $0 == tag } } else { filter.tags.append(tag) }
                controller.setFilter(filter, for: board)
            }
        }
    }

    // MARK: - Sync and questions

    func sync() async throws {
        guard controller.status.showsSyncButton, !controller.status.isSyncing else { return }
        guard let report = await controller.sync() else { return }
        if !report.conflicts.isEmpty {
            plugin.toast("Synced, with \(report.conflicts.count) thing\(report.conflicts.count == 1 ? "" : "s") to decide.")
        } else if controller.status.error != nil {
            // The view says why; nothing was lost.
        } else if report.sent + report.received + report.deleted == 0 {
            plugin.toast("Already up to date.")
        } else {
            plugin.toast("Synced. Sent \(report.sent), received \(report.received).")
        }
    }

    private func resolve(block: String?) async throws {
        // `board.cf.<digest>.<choice>`
        guard let rest = names.rest("cf", of: block), let dot = rest.lastIndex(of: ".") else { return }
        let digest = String(rest[..<dot])
        guard let choice = ConflictChoice(rawValue: String(rest[rest.index(after: dot)...])), let id = conflictLookup[digest] else {
            throw BoardError("That question is no longer open: sync again.")
        }
        try await controller.resolveConflict(id, choice)
        if controller.status.conflicts.isEmpty {
            overlay = nil
            plugin.toast(controller.status.error == nil ? "Your answers were applied." : "Your answers were saved; the sync did not finish.")
        }
    }

    // MARK: - Dialogs

    /// The roles a column or tag may have, as a dialog's choices (the colour is never the only thing that says which).
    static let tagRoleChoices: [DialogField.Choice] = Role.allCases.map { DialogField.Choice(value: $0.rawValue, title: $0.title) }
    static let roleChoices: [DialogField.Choice] = [DialogField.Choice(value: "none", title: "No colour")] + tagRoleChoices

    func askNewBoard() async throws {
        let answer = try await ask(DialogShowParams(
            title: "New Board", primary: "Create",
            fields: [DialogField(key: "name", kind: .text, label: "Name", required: true, placeholder: "Roadmap")]))
        guard answer.submitted else { return }
        let id = try await controller.createBoard(name: answer.values["name"]?.stringValue ?? "")
        show(board: id)
    }

    func askRenameBoard(_ id: String) async throws {
        guard let name = controller.boardName(id) else { throw controller.missingBoard }
        let answer = try await ask(DialogShowParams(
            title: "Rename Board", primary: "Rename",
            fields: [DialogField(key: "name", kind: .text, label: "Name", default: .string(name), required: true)]))
        guard answer.submitted else { return }
        try await controller.renameBoard(id, to: answer.values["name"]?.stringValue ?? "")
    }

    func askDeleteBoard(_ id: String) async throws {
        guard let name = controller.boardName(id) else { throw controller.missingBoard }
        let remote = controller.status.mode != .thisMac
        let confirmed = try await confirm(ConfirmParams(
            title: "Delete “\(name)”?",
            message: remote
                ? "Its columns, tasks, tags and comments are deleted on this Mac now, and in the place at the next sync. Other boards are not touched."
                : "Its columns, tasks, tags and comments are deleted. Other boards are not touched.",
            confirmTitle: "Delete"))
        guard confirmed else { return }
        try await controller.deleteBoard(id)
        if current == id { current = nil }
        overlay = nil
        requestDraw()
        noteCurrent()
    }

    /// A new task: a title, a description and — from the "Add task" button — the column; the "+" of a column gives that one.
    func askNewTask(board: String, column: String?) async throws {
        let columns = controller.columns(of: board).map(\.column)
        guard !columns.isEmpty else { throw BoardError("This board has no columns yet. Add a column first (… ▸ New Column).") }
        var fields = [
            DialogField(key: "title", kind: .text, label: "Title", required: true),
            DialogField(key: "description", kind: .text, label: "Description", help: "Markdown. You can add tags and comments afterwards.", multiline: true),
        ]
        if column == nil || columns.count > 1 {
            fields.append(DialogField(
                key: "column", kind: .choice, label: "Column", default: .string(column ?? columns[0].id),
                options: columns.map { DialogField.Choice(value: $0.id, title: $0.title) }))
        }
        let answer = try await ask(DialogShowParams(title: "New Task", primary: "Add Task", fields: fields))
        guard answer.submitted else { return }
        let target = answer.values["column"]?.stringValue ?? column ?? columns[0].id
        try await controller.addTask(
            to: board, column: target, title: answer.values["title"]?.stringValue ?? "", description: answer.values["description"]?.stringValue ?? "")
    }

    func askNewColumn(board: String) async throws {
        let answer = try await ask(DialogShowParams(
            title: "New Column", primary: "Add Column",
            fields: [
                DialogField(key: "title", kind: .text, label: "Name", required: true, placeholder: "Blocked"),
                DialogField(key: "role", kind: .choice, label: "Colour", default: "none", options: Self.roleChoices),
            ]))
        guard answer.submitted else { return }
        try await controller.addColumn(to: board, title: answer.values["title"]?.stringValue ?? "", role: Role(rawValue: answer.values["role"]?.stringValue ?? ""))
    }

    func askRenameColumn(_ column: String, in board: String) async throws {
        guard let title = controller.columns(of: board).first(where: { $0.column.id == column })?.column.title else { return }
        let answer = try await ask(DialogShowParams(
            title: "Rename Column", primary: "Rename", fields: [DialogField(key: "title", kind: .text, label: "Name", default: .string(title), required: true)]))
        guard answer.submitted else { return }
        try await controller.renameColumn(column, in: board, to: answer.values["title"]?.stringValue ?? "")
    }

    func askColumnColour(_ column: String, in board: String) async throws {
        guard let record = controller.columns(of: board).first(where: { $0.column.id == column })?.column else { return }
        let answer = try await ask(DialogShowParams(
            title: "Colour of “\(record.title)”", primary: "Set",
            fields: [DialogField(key: "role", kind: .choice, label: "Colour", default: .string(record.role ?? "none"), options: Self.roleChoices)]))
        guard answer.submitted else { return }
        try await controller.setColumnRole(column, in: board, to: Role(rawValue: answer.values["role"]?.stringValue ?? ""))
    }

    /// What to do with a column's tasks when it goes: move them to another column or delete them too.
    func askDeleteColumn(_ column: String, in board: String) async throws {
        let columns = controller.columns(of: board)
        guard let target = columns.first(where: { $0.column.id == column }) else { return }
        let count = target.total
        guard count > 0 else {
            let sure = try await confirm(ConfirmParams(title: "Delete the column “\(target.column.title)”?", message: "It has no tasks.", confirmTitle: "Delete"))
            if sure { try await controller.deleteColumn(column, in: board, tasks: .delete) }
            return
        }
        var options = columns.filter { $0.column.id != column }.map { DialogField.Choice(value: "move:\($0.column.id)", title: "Move them to “\($0.column.title)”") }
        options.append(DialogField.Choice(value: "delete", title: "Delete the \(count == 1 ? "task" : "\(count) tasks") and their comments"))
        let answer = try await ask(DialogShowParams(
            title: "Delete the column “\(target.column.title)”?",
            subtitle: "It has \(count) task\(count == 1 ? "" : "s"). Choose what happens to \(count == 1 ? "it" : "them").",
            primary: "Delete Column",
            fields: [DialogField(key: "tasks", kind: .choice, label: "Its tasks", default: .string(options[0].value), options: options)]))
        guard answer.submitted else { return }
        let choice = answer.values["tasks"]?.stringValue ?? ""
        if choice.hasPrefix("move:") {
            try await controller.deleteColumn(column, in: board, tasks: .moveTo(String(choice.dropFirst(5))))
        } else {
            try await controller.deleteColumn(column, in: board, tasks: .delete)
        }
    }

    func askNewTag(board: String) async throws {
        let answer = try await ask(DialogShowParams(
            title: "New Tag", primary: "Add Tag",
            fields: [
                DialogField(key: "name", kind: .text, label: "Name", required: true, placeholder: "urgent"),
                DialogField(key: "role", kind: .choice, label: "Colour", default: "label6", options: Self.tagRoleChoices),
            ]))
        guard answer.submitted else { return }
        let role = Role(rawValue: answer.values["role"]?.stringValue ?? "")
        try await controller.addTag(to: board, name: answer.values["name"]?.stringValue ?? "", role: role)
    }

    /// Deleting a task also deletes its comments: always asked.
    func askDeleteTasks(_ ids: [String], in board: String) async throws {
        guard !ids.isEmpty else { return }
        let title: String
        if ids.count == 1 {
            let name = controller.task(ids[0], in: board)?.task.title ?? "this task"
            title = "Delete “\(name)”?"
        } else {
            title = "Delete \(ids.count) tasks?"
        }
        let sure = try await confirm(ConfirmParams(
            title: title, message: ids.count == 1 ? "Its comments are deleted with it." : "Their comments are deleted with them.", confirmTitle: "Delete"))
        guard sure else { return }
        try await controller.deleteTasks(ids, in: board)
        listSelected.removeAll { ids.contains($0) }
    }
}
