import Foundation
import VektorPlugin

// The blocks of every screen of the view: the board (columns of cards), the list (a table), one task with its comments, Board
// settings, the questions after a sync, and the states in between (loading, nothing yet, an error). Built only from the
// controller's queries and the view's own state (BoardViewModel.swift); no command is called here.
//
// Ids: a card is its task's own id (never its position), so Vektor and the SDK follow it when it moves; everything else is
// `board.<kind>.<id>`. A block's id is also how an event says what it is about: the action is `board.<kind>`.

/// Everything is in English words and numbers a person reads: a colour is never the only thing that says something.
private let english = Locale(identifier: "en_US")

extension BoardViewModel {
    // MARK: - The screens

    func describe() -> ViewDescription {
        if let failure { return failureScreen(failure) }
        if !controller.isLoaded { return plain("Board", [.spinner(id: "board.loading", text: "Loading your boards…")]) }
        if let error = controller.loadError {
            return plain("Board", [.banner(error, id: "board.loaderror", title: "The boards could not be read", symbol: "exclamationmark.triangle", role: .danger)])
        }
        if overlay == .conflicts { return conflictsScreen() }
        guard let board = boardID else { return noBoardScreen() }
        switch overlay {
        case .task(let id)?: return taskScreen(board, task: id)
        case .settings?: return settingsScreen(board)
        default: break
        }
        return layout == .board ? boardScreen(board) : listScreen(board)
    }

    private func plain(_ title: String, _ children: [Block]) -> ViewDescription {
        ViewDescription(header: Header(title: title), root: .vstack(children, id: "board.root", spacing: 12))
    }

    /// Vektor refused the view, or the SDK found something it would refuse: the reason, in words, and a way to try again.
    private func failureScreen(_ problem: String) -> ViewDescription {
        plain("Board", [
            .banner(problem, id: "board.failure", title: "The board could not be shown", symbol: "exclamationmark.triangle", role: .danger),
            .button(id: "board.retry", title: "Try Again", symbol: "arrow.clockwise", action: names.id("retry"), style: .primary),
        ])
    }

    /// No board to show: none yet, still reading, or the one asked for belongs to another workspace.
    private func noBoardScreen() -> ViewDescription {
        var buttons: [Block] = []
        if isForeign, let first = controller.boards.first {
            buttons.append(.button(id: "board.first", title: "Show “\(first.name)”", action: names.id("first"), style: .primary))
        }
        buttons.append(.button(id: "board.newboard", title: "New Board…", symbol: "plus", action: names.id("m", "new"), style: isForeign ? nil : .primary))
        if controller.status.showsSyncButton { buttons.append(syncControls()) }
        let row = Block.hstack(buttons, id: "board.nobuttons", spacing: 8)
        // The buttons are the empty state's own blocks: Vektor draws them centred under its text, and the empty state in the
        // middle of the view (they were a row of their own at the top left).
        var state: Block
        if controller.status.isSyncing, controller.boards.isEmpty {
            state = .empty(controller.status.progress ?? "Getting the boards from the place…", id: "board.syncing", title: "Syncing", symbol: "arrow.triangle.2.circlepath")
        } else if isForeign {
            state = .empty("Open another board from the sidebar, or show the first one here.", id: "board.foreign", title: "This board belongs to another workspace", symbol: "rectangle.split.3x1")
        } else {
            state = .empty("A board has columns, tasks and tags. Create the first one for this workspace.", id: "board.none", title: "No boards yet", symbol: "rectangle.split.3x1")
        }
        state.children = [row]
        var children: [Block] = []
        if let notice = syncNotices() { children.append(notice) }
        children.append(state)
        return plain("Board", children)
    }

    // MARK: - The board

    private func header(_ board: String) -> Header {
        Header(title: controller.boardName(board) ?? "Board", primary: (title: "Add task", symbol: "plus", action: names.id("add")))
    }

    private func boardScreen(_ board: String) -> ViewDescription {
        let filter = controller.filter(of: board)
        let columns = controller.columns(of: board)
        var body: [Block] = [topBar(board, filter: filter), notices(filter: filter, columns: columns)]
        if columns.isEmpty {
            var empty = Block.empty("Add a column to start putting tasks on the board.", id: "board.nocolumns", title: "This board has no columns", symbol: "rectangle.split.3x1")
            empty.children = [.button(id: "board.newcolumn", title: "New Column…", symbol: "plus", action: names.id("m", "column"), style: .primary)]
            body.append(empty)
        } else {
            body.append(Block.scroll(
                columns.enumerated().map {
                    columnBlock($1, index: $0, count: columns.count, filtered: filter.isActive)
                }, id: names.id("columns"), axis: .horizontal,
                spacing: 12))
        }
        return ViewDescription(header: header(board), root: .vstack(body, id: "board.root", spacing: 10))
    }

    /// The board's name is the header. Under it two rows, as in the mock-up: the switcher with Sync, the board/list toggle and
    /// "…"; then All tasks / Tags and the search, which takes the rest of the row (a pane half a window wide squeezed one row
    /// of everything down to a search field 62 points wide — measured in Vektor).
    private func topBar(_ board: String, filter: BoardFilter) -> Block {
        var first: [Block] = [
            .picker(names.id("switch"), action: names.id("switch"), options: controller.boards.map { Option(value: $0.id, title: $0.name) }, value: board)
                .label("Board").tooltip("Switch to another board of this workspace"),
            .spacer(id: "board.barspace"),
        ]
        if controller.status.showsSyncButton { first.append(syncControls()) }
        first.append(
            .picker(
                names.id("layout"), action: names.id("layout"),
                options: [Option(value: "board", title: "Board", symbol: "rectangle.split.3x1"), Option(value: "list", title: "List", symbol: "list.bullet")],
                value: layout.rawValue, segmented: true)
                .label("View as").tooltip("Show the tasks as a board or as a list"))
        first.append(moreMenu())
        var second: [Block] = [
            .picker(
                names.id("status"), action: names.id("status"),
                options: BoardFilter.Status.allCases.map { Option(value: $0.rawValue, title: $0.title, symbol: $0 == .all ? "checklist" : nil) },
                value: filter.status.rawValue)
                .label("Show tasks").tooltip("All tasks, only the open ones, or only the done ones"),
            tagsMenu(board, filter: filter),
            .searchField(searchFieldID, action: names.id("search"), value: filter.search, placeholder: "Search tasks").grow(),
        ]
        if layout == .list {
            second.append(.button(
                id: names.id("deletesel"), title: listSelected.isEmpty ? "Delete" : "Delete \(listSelected.count)", symbol: "trash", action: names.id("deletesel"),
                style: .destructive, tooltip: "Delete the selected tasks", enabled: !listSelected.isEmpty))
        }
        return .vstack([
            .hstack(first, id: names.id("bar1"), spacing: 8),
            .hstack(second, id: names.id("bar2"), spacing: 8),
        ], id: names.id("bar"), spacing: 8)
    }

    /// The search field's id: a new one after each "Clear Filters" (see `searchField`).
    var searchFieldID: String { searchField == 0 ? names.id("search") : names.id("search", String(searchField)) }

    private func tagsMenu(_ board: String, filter: BoardFilter) -> Block {
        let tags = controller.tags(of: board)
        var entries: [MenuEntry] = tags.map {
            .item(title: $0.name, action: names.id("ftag", $0.id), symbol: filter.tags.contains($0.id) ? "checkmark.circle.fill" : "circle")
        }
        if tags.isEmpty { entries.append(.item(title: "This board has no tags yet", action: names.id("tagsedit"), symbol: "tag")) }
        entries.append(.separator)
        if !filter.tags.isEmpty { entries.append(.item(title: "Show Every Tag", action: names.id("tagsclear"), symbol: "xmark.circle")) }
        entries.append(.item(title: "Edit Tags…", action: names.id("tagsedit"), symbol: "slider.horizontal.3"))
        let title = filter.tags.isEmpty ? "Tags" : "Tags (\(filter.tags.count))"
        return Block.menu(entries, id: names.id("tags"), title: title, symbol: "tag").tooltip("Show only the tasks with a tag")
    }

    private func moreMenu() -> Block {
        var entries: [MenuEntry] = [
            .item(title: "Board Settings…", action: names.id("m", "settings"), symbol: "gearshape"),
            .item(title: "New Column…", action: names.id("m", "column"), symbol: "rectangle.badge.plus"),
            .separator,
            .item(title: "New Board…", action: names.id("m", "new"), symbol: "plus"),
            .item(title: "Rename Board…", action: names.id("m", "rename"), symbol: "pencil"),
            .item(title: "Delete Board…", action: names.id("m", "delete"), symbol: "trash", destructive: true),
        ]
        if !controller.status.conflicts.isEmpty {
            entries.insert(.item(title: "Review Sync Questions…", action: names.id("m", "conflicts"), symbol: "exclamationmark.triangle"), at: 0)
        }
        return Block.menu(entries, id: names.id("more")).label("Board actions").tooltip("More")
    }

    // MARK: Sync

    /// The Sync button with its words: running, "Last synced …", or why it failed. Only for a place on a connection.
    private func syncControls() -> Block {
        let status = controller.status
        var line: String
        var role: Role?
        if status.isSyncing {
            line = status.progress ?? "Syncing…"
        } else if status.error != nil {
            line = "The last sync failed"
            role = .danger
        } else if let last = status.lastSynced {
            line = "Last synced \(relative(last))"
        } else {
            line = "Not synced yet"
        }
        if status.unsynced, !status.isSyncing { line += status.error == nil ? " · changes not sent yet" : "" }
        return .hstack([
            .button(
                id: names.id("syncbutton"), title: "Sync", symbol: "arrow.triangle.2.circlepath", action: names.id("sync"), tooltip: "Send this Mac's changes and receive the place's",
                busy: status.isSyncing, enabled: !status.isSyncing),
            .text(line, id: names.id("syncinfo"), style: .caption, role: role, lineLimit: 1),
        ], id: names.id("sync"), spacing: 6)
    }

    func relative(_ date: Date) -> String {
        let now = controller.options.now()
        if now.timeIntervalSince(date) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = english
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Oct 24, 7:03 PM": the list's Updated column (the template's "Oct 24 at 7:03 PM" did not fit its 120 points).
    func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = english
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    func time(_ text: String) -> String {
        guard let date = Stamp.date(text) else { return text }
        let formatter = DateFormatter()
        formatter.locale = english
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Errors and questions of the last sync, wherever the user is.
    private func syncNotices() -> Block? {
        let status = controller.status
        var items: [Block] = []
        if let error = status.error {
            items.append(.banner(
                "\(error) Nothing was lost: your changes are still on this Mac. Sync again when you can.", id: names.id("syncerror"), title: "The last sync did not finish",
                symbol: "exclamationmark.triangle", role: .danger))
        }
        if !status.conflicts.isEmpty {
            let count = status.conflicts.count
            items.append(.hstack([
                .banner(
                    "This Mac and the place both changed \(count == 1 ? "something" : "\(count) things"). Nothing is overwritten until you decide.", id: names.id("conflictbanner"),
                    title: "\(count) thing\(count == 1 ? "" : "s") to decide", symbol: "arrow.triangle.merge", role: .warning).grow(),
                .button(id: names.id("review"), title: "Review…", action: names.id("review"), style: .primary),
            ], id: names.id("conflictrow"), spacing: 8))
        }
        return items.isEmpty ? nil : .vstack(items, id: names.id("syncnotices"), spacing: 6)
    }

    /// Under the bar: what the last sync said, what the filter hides, and what an empty board needs.
    private func notices(filter: BoardFilter, columns: [ColumnView]) -> Block {
        var items: [Block] = []
        if let sync = syncNotices() { items.append(sync) }
        let total = columns.reduce(0) { $0 + $1.total }
        let shown = columns.reduce(0) { $0 + $1.tasks.count }
        if filter.isActive {
            let text = shown == 0 ? "No task matches. \(total) task\(total == 1 ? " is" : "s are") hidden." : "Showing \(shown) of \(total) task\(total == 1 ? "" : "s")."
            items.append(.hstack([
                .status(text, id: names.id("filtered"), symbol: "line.3.horizontal.decrease.circle").grow(),
                .button(id: names.id("clear"), title: "Clear Filters", action: names.id("clear"), style: .plain),
            ], id: names.id("filterrow"), spacing: 8))
        }
        // An empty board says so inside its columns (the first one says how to add a task), not in a line of its own above
        // them, which sat at the left of the bar looking misplaced.
        return .vstack(items, id: names.id("notices"), spacing: 6)
    }

    // MARK: Columns and cards

    private func columnBlock(_ column: ColumnView, index: Int, count: Int, filtered: Bool) -> Block {
        let id = column.column.id
        let shown = column.tasks.count
        let entries: [MenuEntry] = [
            .item(title: "Add Task…", action: names.id("c", "add"), symbol: "plus"),
            .item(title: "Rename Column…", action: names.id("c", "rename"), symbol: "pencil"),
            .item(title: "Change Colour…", action: names.id("c", "colour"), symbol: "paintpalette"),
            .separator,
            .item(title: "Move Left", action: names.id("c", "left"), symbol: "arrow.left", enabled: index > 0 ? nil : false),
            .item(title: "Move Right", action: names.id("c", "right"), symbol: "arrow.right", enabled: index < count - 1 ? nil : false),
            .separator,
            .item(title: "Delete Column…", action: names.id("c", "delete"), symbol: "trash", destructive: true),
        ]
        // The count is a block of its own (not the panel's badge): a task that moves changes two counts, and a change in the
        // panel's own fields would replace the whole column and all its cards instead of sending one small `move`.
        let head: [Block] = [
            .symbol("circle.fill", id: names.id("cdot", id), role: Role(rawValue: column.column.role ?? "") ?? .neutral, label: "Colour"),
            .text(column.column.title, id: names.id("ctitle", id), style: .heading, lineLimit: 1),
            shown == column.total
                ? .count(shown, id: names.id("count", id), label: "\(shown) task\(shown == 1 ? "" : "s")")
                : .badge("\(shown) of \(column.total)", id: names.id("count", id), label: "\(shown) of \(column.total) tasks shown"),
            .spacer(id: names.id("headspace", id)),
            Block.menu(entries, id: names.id("colmenu", id)).label("\(column.column.title) actions"),
            .button(id: names.id("cadd", id), symbol: "plus", action: names.id("cadd"), style: .icon, tooltip: "Add a task to \(column.column.title)"),
        ]
        let list = Block.list(
            names.id("list", id), column.tasks.map(cardBlock), group: "cards", move: names.id("move"),
            // The first column's empty text says how to add a task. It does not depend on the other columns, so a list's own
            // fields stay the same when a task is added elsewhere and the change stays one small `insert`.
            placeholder: filtered ? "None match" : (index == 0 ? "No tasks yet. Add one with + or Add task." : "No tasks"))
        // The name and the colour are in the head's row (the mock-up's dot), not the panel's own title line: one row, and a
        // rename or a new colour is one small `replace`.
        return Block.panel([.hstack(head, id: names.id("head", id), spacing: 6), list], id: names.id("col", id))
            .grow().minWidth(260)
    }

    /// A card: the done circle, the title (renamed in place), the description's first lines (Markdown), the tags, the comment
    /// count and the drag handle. Nine blocks and a block per tag at most, so a view can hold some ten thousand cards.
    private func cardBlock(_ item: TaskView) -> Block {
        let task = item.task
        var children: [Block] = []
        let text = Self.preview(task.description)
        if !text.isEmpty { children.append(.markdown(text, id: "\(task.id).desc")) }
        // The done circle. Vektor draws a card's title and its tags but not a card's `check` (only a row's), so the circle is a
        // button of the card's own; `check` stays on the card for Space, which toggles the focused card.
        var meta: [Block] = [
            .button(
                id: "\(task.id).tick", symbol: task.done ? "checkmark.circle.fill" : "circle", action: names.id("tick"), style: .icon,
                tooltip: task.done ? "Mark as not done" : "Mark as done").with("style", "borderless")
        ]
        meta += item.tags.map { .badge($0.name, id: "\(task.id).tag.\($0.id)", role: Role(rawValue: $0.role ?? "")) }
        meta.append(.spacer(id: "\(task.id).space"))
        meta.append(.symbol("text.bubble", id: "\(task.id).bubble", label: "Comments"))
        meta.append(.count(item.comments, id: "\(task.id).comments", label: "\(item.comments) comment\(item.comments == 1 ? "" : "s")"))
        meta.append(.symbol("line.3.horizontal", id: "\(task.id).grip", label: "Drag to move"))
        children.append(.hstack(meta, id: "\(task.id).meta", spacing: 6))
        return Block.card(
            children, id: task.id, title: task.title, action: names.id("open"), edit: names.id("rename"), delete: names.id("remove"),
            check: names.id("done"), checked: task.done, dimmed: task.done ? true : nil)
            .menu(taskMenu(done: task.done))
    }

    private func taskMenu(done: Bool) -> [MenuEntry] {
        [
            .item(title: "Open Task", action: names.id("k", "open"), symbol: "doc.text.magnifyingglass"),
            .item(title: done ? "Mark as Not Done" : "Mark as Done", action: names.id("k", "done"), symbol: done ? "circle" : "checkmark.circle"),
            .separator,
            .item(title: "Delete Task…", action: names.id("k", "delete"), symbol: "trash", destructive: true),
        ]
    }

    /// The description's first lines: a card is a summary, the whole text is in the task.
    static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lines = trimmed.split(separator: "\n", maxSplits: 6, omittingEmptySubsequences: false)
        var out = lines.prefix(6).joined(separator: "\n")
        var cut = lines.count > 6
        if out.count > 280 {
            out = String(out.prefix(280))
            cut = true
        }
        return cut ? out + " …" : out
    }

    // MARK: - The list

    private func listScreen(_ board: String) -> ViewDescription {
        let filter = controller.filter(of: board)
        let rows = controller.listRows(of: board, sort: listSort)
        let columns = controller.columns(of: board)
        let shownIDs = Set(rows.map(\.task.id))
        let selected = listSelected.filter(shownIDs.contains)
        var body: [Block] = [topBar(board, filter: filter), notices(filter: filter, columns: columns)]
        if rows.isEmpty {
            body.append(.empty(
                filter.isActive ? "Nothing matches the filter or the search." : "Add a task with Add task.", id: names.id("norows"),
                title: filter.isActive ? "No matching tasks" : "No tasks yet", symbol: "list.bullet"))
        } else {
            let tableColumns = [
                // Narrow enough that the title keeps room in a pane half a window wide (measured: 560 pt in Vektor's test Mac).
                Column(id: "title", title: "Title", sortable: true), Column(id: "column", title: "Column", width: 100, sortable: true),
                Column(id: "tags", title: "Tags", width: 110, sortable: true), Column(id: "done", title: "Done", width: 56, sortable: true),
                Column(id: "comments", title: "Comments", width: 84, sortable: true), Column(id: "updated", title: "Updated", width: 120, sortable: true),
            ]
            let tableRows = rows.map { row in
                Block.row(
                    row.task.id,
                    cells: [
                        .string(row.task.title), .string(row.column?.title ?? ""), .string(row.tags.map(\.name).joined(separator: ", ")),
                        .string(row.task.done ? "Done" : "Open"), .int(row.comments), .string(row.updated.map { shortTime($0) } ?? ""),
                    ],
                    action: names.id("open"), delete: names.id("rdelete"), dimmed: row.task.done ? true : nil)
                    .menu(taskMenu(done: row.task.done))
            }
            body.append(Block.table(
                names.id("table"), columns: tableColumns, rows: tableRows,
                sorted: listSort.key == .board ? nil : (column: listSort.key.rawValue, ascending: listSort.ascending), sort: names.id("sort"), selection: .multiple,
                select: names.id("select"), selected: selected.isEmpty ? nil : selected))
        }
        return ViewDescription(header: header(board), root: .vstack(body, id: "board.root", spacing: 10))
    }

    // MARK: - One task

    private func taskScreen(_ board: String, task id: String) -> ViewDescription {
        guard let item = controller.task(id, in: board) else {
            return ViewDescription(header: Header(title: "Task"), root: .vstack([
                .empty("It was deleted, here or by a sync.", id: "board.gone", title: "This task no longer exists", symbol: "doc"),
                .button(id: names.id("backbutton"), title: "Back to the Board", symbol: "chevron.left", action: names.id("back"), style: .primary),
            ], id: "board.root", spacing: 12))
        }
        let task = item.task
        let columns = controller.columns(of: board)
        let comments = controller.comments(of: id, in: board)
        let bar = Block.hstack([
            .button(id: names.id("backbutton"), title: "Back to the Board", symbol: "chevron.left", action: names.id("back"), style: .plain),
            .spacer(id: "board.taskspace"),
            .button(id: names.id("t", "delete"), title: "Delete", symbol: "trash", action: names.id("t", "delete"), style: .destructive),
        ], id: "board.taskbar")
        var body: [Block] = [
            .textField(names.id("t", "title"), action: names.id("t", "title"), value: task.title, placeholder: "Title"),
            .hstack([
                .checkbox(names.id("t", "done"), action: names.id("t", "done"), value: task.done, title: "Done"),
                .spacer(id: "board.taskspace2"),
                .text("Column", id: "board.columnlabel", style: .caption),
                .picker(
                    names.id("t", "column"), action: names.id("t", "column"), options: columns.map { Option(value: $0.column.id, title: $0.column.title) },
                    value: task.column),
            ], id: "board.taskrow", spacing: 8),
            .text("Tags", id: "board.tagslabel", style: .caption),
            .tagPicker(
                names.id("t", "tags"), action: names.id("t", "tags"), tags: item.tags.map(\.name), suggestions: controller.tags(of: board).map(\.name)),
            .text("Description", id: "board.desclabel", style: .caption),
            .textArea(names.id("t", "desc"), action: names.id("t", "desc"), value: task.description, placeholder: "Describe the task. Markdown works; ⌘Return saves."),
        ]
        if !task.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append(.markdown(task.description, id: "board.descpreview"))
        }
        body.append(.text(
            "Created \(time(task.createdAt)) · changed \(time(task.updatedAt))", id: "board.taskdates", style: .caption))
        body.append(.divider(id: "board.commentsdivider"))
        body.append(.text("Comments (\(comments.count))", id: "board.commentshead", style: .heading))
        if comments.isEmpty { body.append(.text("No comments yet. Write the first one below.", id: "board.nocomments", style: .caption)) }
        for comment in comments { body.append(commentBlock(comment)) }
        // A conversation: the task and its comments scroll, newest last, and open at the newest (`anchor: end`, a proposed
        // API 2 addition); the composer stays at the bottom of the view, outside the scroll.
        let conversation = Block.scroll(body, id: "board.taskscroll", axis: .vertical, spacing: 10).with("anchor", "end")
        let composerRow = Block.hstack([
            .textArea(
                names.id("cm", "new", String(composer)), action: names.id("cm", "add"),
                placeholder: "Write a comment as \(controller.options.author). ⌘Return sends.").with("lineLimit", 2).grow(),
            .button(id: names.id("cm", "send"), title: "Send", symbol: "paperplane", action: names.id("cm", "send"), style: .primary,
                tooltip: "Add the comment (⌘Return)"),
        ], id: "board.composer", spacing: 8)
        return ViewDescription(header: Header(title: task.title), root: .vstack([bar, conversation, composerRow], id: "board.root", spacing: 10))
    }

    /// One comment as a chat bubble: the author and how long ago above it; your own on the trailing side in the accent's
    /// fill, the others' on the leading side in the neutral fill (the theme's role fills, graded with the text on them).
    private func commentBlock(_ comment: CommentRecord) -> Block {
        let own = controller.canDelete(comment: comment)
        var meta: [Block] = [
            .text(comment.author, id: names.id("cmauthor", comment.id), style: .caption),
            .text(Stamp.date(comment.time).map(relative) ?? time(comment.time), id: names.id("cmtime", comment.id), style: .caption),
        ]
        if own {
            meta.append(.button(id: names.id("cmdel", comment.id), symbol: "trash", action: names.id("cmdel"), style: .icon, tooltip: "Delete your comment"))
        }
        let bubble = Block.panel([.text(comment.text, id: names.id("cmtext", comment.id), selectable: true)], id: names.id("cmbubble", comment.id), role: own ? .accent : .neutral)
            .with("filled", true).maxWidth(460)
        let spacer = Block.spacer(id: names.id("cmspace", comment.id))
        let metaSpacer = Block.spacer(id: names.id("cmmetaspace", comment.id))
        return .vstack([
            .hstack(own ? [metaSpacer] + meta : meta + [metaSpacer], id: names.id("cmhead", comment.id), spacing: 6),
            .hstack(own ? [spacer, bubble] : [bubble, spacer], id: names.id("cmline", comment.id)),
        ], id: names.id("cm", comment.id), spacing: 4)
    }

    // MARK: - Board settings

    private func settingsScreen(_ board: String) -> ViewDescription {
        var body: [Block] = [
            .hstack([
                .button(id: names.id("backbutton"), title: "Back to the Board", symbol: "chevron.left", action: names.id("back"), style: .plain),
                .spacer(id: "board.setspace"),
            ], id: "board.setbar"),
            .picker(
                names.id("stab"), action: names.id("stab"),
                options: [
                    Option(value: "columns", title: "Columns", symbol: "rectangle.split.3x1"), Option(value: "tags", title: "Tags", symbol: "tag"),
                    Option(value: "general", title: "General", symbol: "gearshape"),
                ], value: settingsTab, segmented: true),
        ]
        switch settingsTab {
        case "tags": body += tagsSettings(board)
        case "general": body += generalSettings(board)
        default: body += columnsSettings(board)
        }
        return ViewDescription(header: Header(title: "Board settings"), root: .scroll(body, id: "board.root", axis: .vertical, spacing: 12))
    }

    private func reorderButtons(_ kind: String, _ id: String, first: Bool, last: Bool) -> [Block] {
        [
            .button(id: names.id(kind + "up", id), symbol: "chevron.up", action: names.id(kind + "up"), style: .icon, tooltip: "Move up", enabled: !first),
            .button(id: names.id(kind + "down", id), symbol: "chevron.down", action: names.id(kind + "down"), style: .icon, tooltip: "Move down", enabled: !last),
        ]
    }

    private func columnsSettings(_ board: String) -> [Block] {
        let columns = controller.columns(of: board)
        var out: [Block] = [
            .text("Columns", id: "board.scheading", style: .heading),
            .text("Rename, recolour and reorder the columns. Deleting a column asks what happens to its tasks.", id: "board.scnote", style: .caption),
        ]
        for (index, column) in columns.enumerated() {
            let id = column.column.id
            // Two lines: the 13 colours beside the name squeezed it to five letters in a half-window pane.
            out.append(.vstack([
                .hstack(
                    reorderButtons("sc", id, first: index == 0, last: index == columns.count - 1) + [
                        .textField(names.id("scname", id), action: names.id("scname"), value: column.column.title, placeholder: "Name").grow(),
                        .text("\(column.total) task\(column.total == 1 ? "" : "s")", id: names.id("sccount", id), style: .caption),
                        .button(id: names.id("scdel", id), symbol: "trash", action: names.id("scdel"), style: .icon, tooltip: "Delete this column"),
                    ], id: names.id("scline", id), spacing: 8),
                .rolePicker(names.id("scrole", id), action: names.id("scrole"), value: Role(rawValue: column.column.role ?? "")).label("Colour of \(column.column.title)"),
            ], id: names.id("scrow", id), spacing: 4))
        }
        if columns.isEmpty { out.append(.text("No columns yet.", id: "board.scnone", style: .caption)) }
        out.append(.button(id: names.id("scadd"), title: "Add Column", symbol: "plus", action: names.id("scadd")))
        return out
    }

    private func tagsSettings(_ board: String) -> [Block] {
        let tags = controller.tags(of: board)
        var out: [Block] = [
            .text("Tags", id: "board.stheading", style: .heading),
            .text("A task can have several tags. Deleting a tag takes it off every task.", id: "board.stnote", style: .caption),
        ]
        for (index, tag) in tags.enumerated() {
            out.append(.vstack([
                .hstack(
                    reorderButtons("st", tag.id, first: index == 0, last: index == tags.count - 1) + [
                        .textField(names.id("stname", tag.id), action: names.id("stname"), value: tag.name, placeholder: "Name").grow(),
                        .button(id: names.id("stdel", tag.id), symbol: "trash", action: names.id("stdel"), style: .icon, tooltip: "Delete this tag"),
                    ], id: names.id("stline", tag.id), spacing: 8),
                .rolePicker(names.id("strole", tag.id), action: names.id("strole"), value: Role(rawValue: tag.role ?? "")).label("Colour of \(tag.name)"),
            ], id: names.id("strow", tag.id), spacing: 4))
        }
        if tags.isEmpty { out.append(.text("No tags yet. Add one here, or type a new tag on a task.", id: "board.stnone", style: .caption)) }
        out.append(.button(id: names.id("stadd"), title: "Add Tag", symbol: "plus", action: names.id("stadd")))
        return out
    }

    private func generalSettings(_ board: String) -> [Block] {
        let place: String
        switch controller.status.mode {
        case .thisMac: place = "This Mac, in the plugin's own folder. Every change is saved at once."
        case .folder(let label): place = "A folder on this Mac: \(label). Every change is saved there at once."
        case .remote(let label): place = "A folder on a connection: \(label). Changes are saved on this Mac at once; Sync sends and receives."
        }
        return [
            .text("General", id: "board.sgheading", style: .heading),
            .text("Name", id: "board.sgnamelabel", style: .caption),
            .textField(names.id("gname"), action: names.id("gname"), value: controller.boardName(board) ?? "", placeholder: "Board name"),
            .text("Where this workspace's boards are kept", id: "board.sgplacelabel", style: .caption),
            .text(place, id: "board.sgplace", selectable: true),
            .text(
                "The place is the same for all boards of a workspace. Choose it per workspace in Vektor's Settings ▸ Plugins ▸ Board ▸ Boards folder.",
                id: "board.sgplacehelp", style: .caption),
            .divider(id: "board.sgdivider"),
            .button(id: names.id("gdelete"), title: "Delete This Board…", symbol: "trash", action: names.id("gdelete"), style: .destructive),
        ]
    }

    // MARK: - Questions after a sync

    private func conflictsScreen() -> ViewDescription {
        let items = controller.status.conflicts
        conflictLookup = [:]
        var body: [Block] = [
            .hstack([
                .button(id: names.id("backbutton"), title: "Back to the Board", symbol: "chevron.left", action: names.id("back"), style: .plain),
                .spacer(id: "board.cfspace"),
            ], id: "board.cfbar"),
        ]
        if items.isEmpty {
            body.append(.empty("Everything from the last sync is settled.", id: "board.cfnone", title: "Nothing to decide", symbol: "checkmark.circle"))
        } else {
            body.append(.text(
                "This Mac and the place both changed these. Each is shown with both versions; nothing is overwritten until you choose.", id: "board.cfintro", style: .caption))
        }
        for item in items {
            let digest = Self.digest(item.id)
            conflictLookup[digest] = item.id
            body.append(conflictBlock(item, digest: digest))
        }
        let count = items.count
        return ViewDescription(
            header: Header(title: count == 0 ? "Sync" : "\(count) thing\(count == 1 ? "" : "s") to decide"), root: .scroll(body, id: "board.root", axis: .vertical, spacing: 14))
    }

    private func conflictBlock(_ item: SyncConflictItem, digest: String) -> Block {
        let reason: String
        switch item.reason {
        case .bothChanged: reason = "Changed on this Mac and in the place, differently."
        case .bothAdded: reason = "Both this Mac and the place have it, and they differ."
        case .deletedHere: reason = "Deleted on this Mac, but changed in the place."
        case .deletedThere: reason = "Deleted in the place, but changed on this Mac."
        }
        func title(_ choice: ConflictChoice) -> String {
            switch choice {
            case .keepMine: return item.mine == nil ? "Keep It Deleted" : "Keep This Mac's Version"
            case .keepTheirs: return item.theirs == nil ? "Delete It, as in the Place" : "Keep the Place's Version"
            case .keepBoth: return "Keep Both"
            }
        }
        let buttons = item.choices.map { choice in
            Block.button(
                id: names.id("cf", digest, choice.rawValue), title: title(choice), action: names.id("resolve"), style: choice == .keepBoth ? .plain : nil,
                tooltip: choice == .keepBoth ? "The place's version stays and this Mac's becomes a second task beside it" : nil)
        }
        return Block.section(
            names.id("cfs", digest),
            [
                .text("In the board “\(item.boardName)”", id: names.id("cfboard", digest), style: .caption),
                .text(reason, id: names.id("cfreason", digest)),
                .diff(
                    left: item.mine ?? "(deleted on this Mac)", right: item.theirs ?? "(deleted in the place)", id: names.id("cfdiff", digest), leftTitle: "This Mac",
                    rightTitle: "In the place"),
                .hstack(buttons, id: names.id("cfbuttons", digest), spacing: 8),
            ], title: item.title)
    }

    /// A short, stable name for a conflict's id in block ids (the id has `|` and more in it).
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
