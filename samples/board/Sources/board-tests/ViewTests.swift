import BoardPlugin
import Foundation
import VektorPlugin
import VektorPluginTestKit

// What the user sees and does: the blocks each screen describes, what each control's event does to the board, the filters, the
// list's sort, the questions after a sync, the empty and error states, and a refused patch followed by a move. Everything runs
// the plugin as Vektor runs it (`setup`) on the SDK's test kit: events go in as `view/event`, descriptions and patches come out.

// MARK: - Helpers

extension JSONValue: @retroactive ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) { self = .string(String(stringInterpolation: stringInterpolation)) }
}

/// The view's last description as a tree of blocks, with the lookups the tests need.
@MainActor
struct Tree {
    let root: Block
    init(_ world: World) throws {
        guard let blocks = world.plugin.view(BoardIDs.view).description?.blocks, let first = blocks.first else {
            throw Failure(description: "the view has not been described")
        }
        root = first
    }

    func find(_ id: String) -> Block? { walk(root).first { $0.id == id } }
    func all(_ type: String) -> [Block] { walk(root).filter { $0.type == type } }
    func has(_ id: String) -> Bool { find(id) != nil }
    func text(_ id: String) -> String? { find(id)?.fields["text"]?.stringValue }
    /// Every piece of text in the tree: what a person could read.
    var words: String {
        walk(root).flatMap { block -> [String] in
            ["text", "title", "label", "markdown", "placeholder", "left", "right"].compactMap { block.fields[$0]?.stringValue }
        }.joined(separator: "\n")
    }
    func children(_ id: String) -> [Block] { find(id)?.children ?? [] }
    func ids(_ id: String) -> [String] { children(id).compactMap(\.id) }
    private func walk(_ block: Block) -> [Block] { [block] + (block.children ?? []).flatMap(walk) }
}

extension World {
    var tree: Tree { get throws { try Tree(self) } }
    var viewState: ViewState { plugin.view(BoardIDs.view) }
    var headerTitle: String? { viewState.description?.header?.title }

    /// A sent view message and what it said, newest first.
    var viewMessages: [Envelope] {
        host.received.filter { $0.kind == .notification && ($0.method == "view/update" || $0.method == "view/patch") }
    }
    var patches: [Envelope] { host.received.filter { $0.kind == .notification && $0.method == "view/patch" } }
    var alerts: [String] { host.received.filter { $0.kind == .notification && $0.method == "alert" }.compactMap { $0.params["message"]?.stringValue } }
    var toasts: [String] { host.received.filter { $0.kind == .notification && $0.method == "toast" }.compactMap { $0.params["message"]?.stringValue } }

    /// Waits until nothing more is being sent: the events were handled and the view drawn.
    func quiet() async throws {
        var last = -1
        var stable = 0
        let deadline = Date().addingTimeInterval(20)
        while stable < 3 {
            try await Task.sleep(nanoseconds: 8_000_000)
            await model?.settle()
            let now = host.received.count + (controller?.status.isSyncing == true ? 1_000_000 : 0)
            if now == last { stable += 1 } else { stable = 0; last = now }
            if Date() > deadline { throw Failure(description: "the plugin never went quiet") }
        }
    }

    /// Opens the board view for `item` and waits for it to be drawn.
    func open(_ item: String? = nil) async throws {
        host.openView(BoardIDs.view, item: item)
        try await quiet()
    }

    /// A user's action: a `view/event` made against the description on screen.
    func event(_ action: String, _ fields: [String: JSONValue] = [:]) async throws {
        host.viewEvent(BoardIDs.view, action, fields)
        try await quiet()
    }

    /// The answers the next dialogs get (nil: the user cancels); the dialogs asked are in `asked`.
    func script(_ answers: [[String: JSONValue]?], confirm: Bool = true) {
        var queue = answers
        asked = []
        confirms = []
        model?.ask = { [weak self] params in
            self?.asked.append(params)
            guard !queue.isEmpty else { throw BoardError("A dialog nobody scripted: \(params.title)") }
            let values = queue.removeFirst()
            // A cancel as an older Vektor sent it, without `values` (the SDK must read it as empty).
            guard let values else { return try JSONValue.object(["result": .string("cancel")]).decode(DialogShowResult.self) }
            return try JSONValue.object(["result": .string("submit"), "values": .object(values)]).decode(DialogShowResult.self)
        }
        model?.confirm = { [weak self] params in
            self?.confirms.append(params)
            return confirm
        }
    }
}

/// Dialogs and confirmations a test saw (kept on the side because `World` is a class from the harness).
@MainActor private var askedByWorld: [ObjectIdentifier: [DialogShowParams]] = [:]
@MainActor private var confirmsByWorld: [ObjectIdentifier: [ConfirmParams]] = [:]
extension World {
    var asked: [DialogShowParams] {
        get { askedByWorld[ObjectIdentifier(self)] ?? [] }
        set { askedByWorld[ObjectIdentifier(self)] = newValue }
    }
    var confirms: [ConfirmParams] {
        get { confirmsByWorld[ObjectIdentifier(self)] ?? [] }
        set { confirmsByWorld[ObjectIdentifier(self)] = newValue }
    }

    /// Makes a board with tasks through the controller (the way the sidebar and the dialogs do) and returns what a test names.
    func seedBoard() async throws -> Seed {
        let controller = self.controller!
        let board = try await controller.createBoard(name: "Roadmap")
        let backlog = controller.columnID("Backlog", in: board)!
        let progress = controller.columnID("In Progress", in: board)!
        let done = controller.columnID("Done", in: board)!
        let docs = try await controller.addTag(to: board, name: "docs", role: .label6)
        let urgent = try await controller.addTag(to: board, name: "urgent", role: .label1)
        let spec = try await controller.addTask(to: board, column: backlog, title: "Write the spec", description: "First **draft** of the spec.\nSecond line.", tags: [docs])
        let plugin = try await controller.addTask(to: board, column: backlog, title: "Build the plugin", tags: [docs, urgent])
        let tests = try await controller.addTask(to: board, column: progress, title: "Write tests")
        let ship = try await controller.addTask(to: board, column: done, title: "Ship it")
        try await controller.setDone(ship, in: board, true)
        try await controller.addComment(to: spec, in: board, text: "Looks good.")
        try await controller.addComment(to: spec, in: board, text: "One more thing.")
        return Seed(board: board, backlog: backlog, progress: progress, done: done, docs: docs, urgent: urgent, spec: spec, plugin: plugin, tests: tests, ship: ship)
    }

    struct Seed {
        var board, backlog, progress, done, docs, urgent, spec, plugin, tests, ship: String
    }
}

private func installed(remote: Bool = false, place: Bool = false, author: String = "Ada") async throws -> World {
    try await World(remote: remote, install: true, author: author, place: place)
}

private func role(_ block: Block?) -> String? { block?.fields["role"]?.stringValue }


/// A block id's JSON field as text.
private func field(_ block: Block?, _ key: String) -> String? { block?.fields[key]?.stringValue }

/// The ids of the cards (task ids) in a column, in order.
@MainActor
private func cards(_ world: World, _ column: String) throws -> [String] { try world.tree.ids("board.list.\(column)") }

/// The titles of the cards in a column, in order.
@MainActor
private func titles(_ world: World, _ column: String) throws -> [String] {
    let tree = try world.tree
    return tree.children("board.list.\(column)").compactMap { field($0, "title") }
}

/// The ids of all the sync-question buttons on screen.
@MainActor
private func answerButtons(_ world: World) throws -> [String] {
    try world.tree.all("button").compactMap(\.id).filter { $0.hasPrefix("board.cf.") }
}

@MainActor
func viewTests() async {
    await test("board view: the mock-up's controls, built from blocks, drawn from the controller") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        let tree = try world.tree
        try checkEqual(world.headerTitle, "Roadmap")
        try checkEqual(world.viewState.description?.header?.primary?.title, "Add task")
        // The bar: switcher, All tasks, Tags, search, board/list toggle, "…" — and no Sync for a local place.
        try checkEqual(tree.find("board.switch")?.type, "picker")
        try checkEqual(tree.find("board.status")?.fields["options"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["All tasks", "Open tasks", "Done tasks"])
        try checkEqual(field(tree.find("board.tags"), "title"), "Tags")
        try checkEqual(tree.find("board.tags")?.fields["menu"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["docs", "urgent", "Edit Tags…"])
        try checkEqual(tree.find("board.search")?.type, "searchField")
        try checkEqual(field(tree.find("board.layout"), "style"), "segmented")
        try check(tree.has("board.more") && !tree.has("board.sync") && !tree.has("board.syncbutton"), "no Sync button without a connection")
        // Columns side by side in a horizontal scroll, each growing with a minimum width, in the board's order, with their role.
        let scroll = tree.find("board.columns")
        try checkEqual(field(scroll, "axis"), "horizontal")
        let panels = scroll?.children ?? []
        let columnIDs = panels.map { String(($0.id ?? "").dropFirst("board.col.".count)) }
        try checkEqual(columnIDs.compactMap { field(tree.find("board.ctitle.\($0)"), "text") }, ["Backlog", "In Progress", "Review", "Done"])
        try checkEqual(columnIDs.map { role(tree.find("board.cdot.\($0)")) }, ["neutral", "label6", "label7", "label4"])
        try check(panels.allSatisfy { $0.fields["grow"]?.boolValue == true && $0.fields["minWidth"]?.numberValue == 260 }, "columns grow, with a minimum width")
        try checkEqual(tree.find("board.count.\(seed.backlog)")?.fields["count"]?.intValue, 2)
        // A card: done circle, title edited in place, ⌫, description, tags, comment count, drag handle; dragged within its group.
        let list = tree.find("board.list.\(seed.backlog)")
        try checkEqual(field(list, "group"), "cards")
        try checkEqual(field(list, "move"), "board.move")
        let card = tree.find(seed.spec)
        try checkEqual(field(card, "check"), "board.done")
        try checkEqual(card?.fields["checked"]?.boolValue, false)
        try checkEqual(field(card, "edit"), "board.rename")
        try checkEqual(field(card, "delete"), "board.remove")
        try checkEqual(tree.find("\(seed.spec).desc")?.fields["markdown"]?.stringValue, "First **draft** of the spec.\nSecond line.")
        try checkEqual(role(tree.find("\(seed.spec).tag.\(seed.docs)")), "label6")
        try checkEqual(tree.find("\(seed.spec).comments")?.fields["count"]?.intValue, 2)
        try check(tree.has("\(seed.spec).grip"), "a drag handle")
        try checkEqual(tree.find("\(seed.ship).tick")?.fields["symbol"]?.stringValue, "checkmark.circle.fill")
        try check(tree.find(seed.spec)?.fields["menu"]?.arrayValue?.contains { $0["title"]?.stringValue == "Delete Task…" } == true)
        try checkEqual(tree.find(seed.ship)?.fields["checked"]?.boolValue, true)
        try checkEqual(tree.find(seed.ship)?.fields["dimmed"]?.boolValue, true)
        // Colours are roles, never values.
        try check(validateBlocks(tree.root).warnings.isEmpty, "\(validateBlocks(tree.root).warnings)")
        // The sidebar marks the board shown.
        let items = world.host.notifications("sidebar/items").last?.params["items"]?.arrayValue ?? []
        try checkEqual(items.first?["symbol"]?.stringValue, "rectangle.split.3x1.fill")
    }

    await test("bar: switcher, All tasks, Tags, search and the board/list toggle change what is shown, and say so in words") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        let second = try await world.controller!.createBoard(name: "Bugs")
        try await world.open(seed.board)
        try await world.event("board.switch", ["block": "board.switch", "value": .string(second)])
        try checkEqual(world.headerTitle, "Bugs")
        try await world.event("board.switch", ["block": "board.switch", "value": .string(seed.board)])
        try checkEqual(world.headerTitle, "Roadmap")

        try await world.event("board.status", ["block": "board.status", "value": "done"])
        try checkEqual(try titles(world, seed.done), ["Ship it"])
        try checkEqual(try cards(world, seed.backlog), [])
        let tree = try world.tree
        try checkEqual(field(tree.find("board.count.\(seed.backlog)"), "text"), "0 of 2")
        try checkEqual(tree.text("board.filtered"), "Showing 1 of 4 tasks.")
        try await world.event("board.clear", ["block": "board.clear"])
        try checkEqual(try cards(world, seed.backlog).count, 2)
        try check(!(try world.tree.has("board.filtered")))

        // After Clear Filters the search is a new field: the old one's text, committed late by the click away, is ignored.
        try check(try world.tree.has("board.search.1") && !(try world.tree.has("board.search")), "a new search field after Clear Filters")
        try await world.event("board.search", ["block": "board.search", "value": "spec"])
        try checkEqual(try cards(world, seed.backlog).count, 2)
        try await world.event("board.search", ["block": "board.search.1", "value": "spec"])
        try checkEqual(try titles(world, seed.backlog), ["Write the spec"])
        try await world.event("board.search", ["block": "board.search.1", "value": ""])

        // Tags: a menu of the board's tags; the action names the tag.
        try await world.event("board.ftag.\(seed.urgent)", ["block": "board.tags"])
        try checkEqual(try titles(world, seed.backlog), ["Build the plugin"])
        try checkEqual(field(try world.tree.find("board.tags"), "title"), "Tags (1)")
        try await world.event("board.ftag.\(seed.docs)", ["block": "board.tags"])
        try checkEqual(try titles(world, seed.backlog), ["Write the spec", "Build the plugin"], "any of the chosen tags")
        let entry = try world.tree.find("board.tags")?.fields["menu"]?.arrayValue?.first
        try checkEqual(entry?["symbol"]?.stringValue, "checkmark.circle.fill")
        try await world.event("board.ftag.\(seed.docs)", ["block": "board.tags"])
        try await world.event("board.tagsclear", ["block": "board.tags"])
        try checkEqual(try cards(world, seed.backlog).count, 2)

        // Board/list toggle.
        try await world.event("board.layout", ["block": "board.layout", "value": "list"])
        try check(try world.tree.has("board.table") && !(try world.tree.has("board.columns")))
        try await world.event("board.layout", ["block": "board.layout", "value": "board"])
        try check(try world.tree.has("board.columns"))
    }

    await test("cards: add (header and +), done circle, rename in place, ⌫ asks first, empty names refused in words") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        let controller = world.controller!

        // "Add task" in the header: title, description and the column to put it in.
        world.script([["title": "Ask legal", "description": "Before **Friday**", "column": .string(seed.progress)]])
        try await world.event("board.add")
        try checkEqual(world.asked.first?.title, "New Task")
        try checkEqual(world.asked.first?.fields?.map(\.key), ["title", "description", "column"])
        try checkEqual(world.asked.first?.fields?.last?.options?.map(\.title), ["Backlog", "In Progress", "Review", "Done"])
        try checkEqual(try titles(world, seed.progress), ["Write tests", "Ask legal"])
        try checkEqual(controller.file(seed.board)?.tasks.first { $0.title == "Ask legal" }?.description, "Before **Friday**")

        // The + of a column: that column is the dialog's default.
        world.script([["title": "Plan v2", "description": "", "column": .string(seed.done)]])
        try await world.event("board.cadd", ["block": "board.cadd.\(seed.done)"])
        try checkEqual(world.asked.first?.fields?.last?.default, .string(seed.done))
        try checkEqual(try titles(world, seed.done), ["Ship it", "Plan v2"])
        world.script([nil])
        try await world.event("board.cadd", ["block": "board.cadd.\(seed.done)"])
        try checkEqual(try titles(world, seed.done), ["Ship it", "Plan v2"], "cancelling adds nothing")
        // New Board cancelled (Esc, Cancel, the backdrop): nothing made, and no alert about the answer's shape.
        let boardsBefore = controller.boards.count
        let alertsBefore = world.alerts.count
        world.script([nil])
        try await world.event("board.m.new", ["block": "board.more"])
        try checkEqual(controller.boards.count, boardsBefore)
        try checkEqual(world.alerts.count, alertsBefore, "\(world.alerts)")

        // The done circle: a button of the card's own (Vektor draws `check` on rows only); Space sends `done` for the focused card.
        try await world.event("board.tick", ["block": "\(seed.spec).tick"])
        try checkEqual(try world.tree.find("\(seed.spec).tick")?.fields["symbol"]?.stringValue, "checkmark.circle.fill")
        try await world.event("board.tick", ["block": "\(seed.spec).tick"])
        try checkEqual(try world.tree.find("\(seed.spec).tick")?.fields["symbol"]?.stringValue, "circle")
        try await world.event("board.done", ["block": .string(seed.spec), "value": true])
        try checkEqual(try world.tree.find(seed.spec)?.fields["checked"]?.boolValue, true)
        try await world.event("board.done", ["block": .string(seed.spec), "value": false])
        try checkEqual(try world.tree.find(seed.spec)?.fields["checked"]?.boolValue, false)

        // Rename in place; an empty title is refused in plain words and the card keeps its name.
        try await world.event("board.rename", ["block": .string(seed.ship), "value": "Shipped"])
        try checkEqual(try world.tree.find(seed.ship)?.fields["title"]?.stringValue, "Shipped")
        try await world.event("board.rename", ["block": .string(seed.ship), "value": "  "])
        try checkEqual(world.alerts.last, "A task needs a title.")
        try checkEqual(try world.tree.find(seed.ship)?.fields["title"]?.stringValue, "Shipped")

        // ⌫ asks; "No" keeps it, "Yes" deletes it and its comments.
        world.script([], confirm: false)
        try await world.event("board.remove", ["block": .string(seed.spec)])
        try checkEqual(world.confirms.first?.title, "Delete “Write the spec”?")
        try check(controller.file(seed.board)?.tasks.contains { $0.id == seed.spec } == true)
        world.script([], confirm: true)
        try await world.event("board.remove", ["block": .string(seed.spec)])
        try check(!(try world.tree.has(seed.spec)))
        try checkEqual(controller.file(seed.board)?.comments.count, 0)
    }

    await test("a card dragged or moved with ⌥ and an arrow is one move operation, and the order is kept") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        let controller = world.controller!
        let before = world.viewMessages.count

        // To another column, at the top.
        try await world.event("board.move", ["item": .string(seed.plugin), "from": "board.list.\(seed.backlog)", "target": "board.list.\(seed.progress)", "index": 0])
        try checkEqual(controller.layout(seed.board), "Backlog: Write the spec | In Progress: Build the plugin, Write tests | Review:  | Done: Ship it")
        try checkEqual(try cards(world, seed.progress), [seed.plugin, seed.tests])
        try checkEqual(world.viewMessages.count - before, 1, "one message for one move")
        let patch = world.patches.last
        let ops = patch?.params["ops"]?.arrayValue ?? []
        try check(!ops.isEmpty && ops.count <= 6, "a few operations, not the board: \(ops.count)")
        try check(ops.contains { $0["op"]?.stringValue == "move" && $0["id"]?.stringValue == seed.plugin }, "the card itself moves: \(ops.map(\.jsonText))")
        try check((patch?.params.jsonData.count ?? 99_999) < 2_000, "the patch is small")

        // Within a column.
        try await world.event("board.move", ["item": .string(seed.tests), "from": "board.list.\(seed.progress)", "target": "board.list.\(seed.progress)", "index": 0])
        try checkEqual(try cards(world, seed.progress), [seed.tests, seed.plugin])
        // Across a restart of the plugin's view the order is the board's.
        try checkEqual(controller.columns(of: seed.board)[1].tasks.map(\.task.title), ["Write tests", "Build the plugin"])

        // With a tag filter on, the index counts the cards SHOWN; the hidden ones keep their place.
        let extra = try await controller.addTask(to: seed.board, column: seed.backlog, title: "Untagged")
        let second = try await controller.addTask(to: seed.board, column: seed.backlog, title: "Docs two", tags: [seed.docs])
        try await world.event("board.ftag.\(seed.docs)", ["block": "board.tags"])
        try checkEqual(try cards(world, seed.backlog), [seed.spec, second], "the plugin task moved away; Untagged is hidden")
        try await world.event("board.move", ["item": .string(seed.plugin), "from": "board.list.\(seed.progress)", "target": "board.list.\(seed.backlog)", "index": 1])
        try await world.event("board.clear")
        try checkEqual(try cards(world, seed.backlog), [seed.spec, extra, seed.plugin, second], "before the second SHOWN card; the hidden one keeps its place")

        // A move made against an older description is dropped, never misapplied.
        let stale = (world.host.lastRevision(BoardIDs.view) ?? 5) - 3
        try await world.event("board.move", ["item": .string(seed.spec), "target": "board.list.\(seed.done)", "index": 0, "revision": .int(stale)])
        try checkEqual(try cards(world, seed.backlog).first, seed.spec)
    }

    await test("a patch Vektor refused is answered with the whole view, and the next move is not dropped as stale") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        let controller = world.controller!
        // The user moved a card: a patch (revision R).
        try await controller.moveTask(seed.plugin, in: seed.board, to: seed.progress, at: 0)
        try await world.quiet()
        let patched = world.host.lastRevision(BoardIDs.view)!
        try checkEqual(world.viewMessages.last?.method, "view/patch")
        // Vektor could not apply it: it still shows R - 1.
        let refusal = world.host.refuse(BoardIDs.view, problem: "operation 1 moves a block that is not there.")
        try await world.quiet()
        try checkEqual(world.viewMessages.last?.method, "view/update", "the whole description is sent again")
        try check((world.host.lastRevision(BoardIDs.view) ?? 0) > patched)
        try check(world.host.received.contains { $0.method == "log" && ($0.params["message"]?.stringValue ?? "").contains("could not show the view") })
        // A drop made against something older than what Vektor still shows really is stale, and dropped...
        try await world.event("board.move", ["item": .string(seed.spec), "target": "board.list.\(seed.done)", "index": 0, "revision": .int((refusal.revision ?? 2) - 1)])
        try checkEqual(try cards(world, seed.backlog), [seed.spec], "an older drop is not applied")
        // ...but the next drop, made against what Vektor still showed (R - 1), is applied.
        try await world.event(
            "board.move", ["item": .string(seed.tests), "target": "board.list.\(seed.progress)", "index": 0, "revision": .int(refusal.revision ?? 0)])
        try checkEqual(try cards(world, seed.progress).first, seed.tests)
        try checkEqual(controller.columns(of: seed.board)[1].tasks.first?.task.id, seed.tests)

        // A whole description Vektor refused: the reason in words, and a way to try again.
        world.host.refuse(BoardIDs.view, problem: "The description is too large.", kind: .description)
        try await world.quiet()
        let failed = try world.tree
        try check(failed.words.contains("The description is too large."), failed.words)
        try check(failed.has("board.retry"))
        try await world.event("board.retry")
        try check(try world.tree.has("board.columns"))
    }

    await test("column menu: rename, colour, move, delete asks what to do with the tasks") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        let controller = world.controller!
        func menu(_ column: String) -> String { "board.colmenu.\(column)" }

        world.script([["title": "Doing"]])
        try await world.event("board.c.rename", ["block": .string(menu(seed.progress))])
        try checkEqual(world.asked.first?.fields?.first?.default, .string("In Progress"))
        try checkEqual(field(try world.tree.find("board.ctitle.\(seed.progress)"), "text"), "Doing")

        world.script([["role": "label3"]])
        try await world.event("board.c.colour", ["block": .string(menu(seed.progress))])
        try checkEqual(role(try world.tree.find("board.cdot.\(seed.progress)")), "label3")
        try check(world.asked.first?.fields?.first?.options?.count == 14, "no colour + the 13 roles, named in words")
        try check(world.asked.first?.fields?.first?.options?.contains { $0.title == "Yellow" } == true)

        try await world.event("board.c.right", ["block": .string(menu(seed.progress))])
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["Backlog", "Review", "Doing", "Done"])
        try await world.event("board.c.left", ["block": .string(menu(seed.progress))])
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["Backlog", "Doing", "Review", "Done"])
        let first = try world.tree.find(menu(seed.backlog))?.fields["menu"]?.arrayValue?.first { $0["action"]?.stringValue == "board.c.left" }
        try checkEqual(first?["enabled"]?.boolValue, false, "the first column cannot move left")

        // Delete: with tasks it asks where they go (or whether they go too).
        world.script([["tasks": .string("move:\(seed.done)")]])
        try await world.event("board.c.delete", ["block": .string(menu(seed.backlog))])
        let options = world.asked.first?.fields?.first?.options
        try checkEqual(options?.map(\.title), ["Move them to “Doing”", "Move them to “Review”", "Move them to “Done”", "Delete the 2 tasks and their comments"])
        try checkEqual(world.asked.first?.title, "Delete the column “Backlog”?")
        try checkEqual(world.asked.first?.subtitle, "It has 2 tasks. Choose what happens to them.")
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["Doing", "Review", "Done"])
        try checkEqual(try titles(world, seed.done), ["Ship it", "Write the spec", "Build the plugin"])
        // Delete them too.
        world.script([["tasks": "delete"]])
        try await world.event("board.c.delete", ["block": .string(menu(seed.done))])
        try check(controller.file(seed.board)?.tasks.allSatisfy { $0.column == seed.progress } == true)
        try checkEqual(controller.file(seed.board)?.comments.count, 0)
        // An empty column only asks to be sure.
        world.script([], confirm: true)
        try await world.event("board.c.delete", ["block": .string(menu(controller.columnID("Review", in: seed.board)!))])
        try checkEqual(world.confirms.first?.message, "It has no tasks.")
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["Doing"])
    }

    await test("list view: the same tasks as a sortable table with a multiple selection and one delete") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        try await world.event("board.layout", ["value": "list"])
        var tree = try world.tree
        let table = tree.find("board.table")
        try checkEqual(table?.fields["columns"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Title", "Column", "Tags", "Done", "Comments", "Updated"])
        try check(table?.fields["columns"]?.arrayValue?.allSatisfy { $0["sortable"]?.boolValue == true } == true)
        try checkEqual(field(table, "selection"), "multiple")
        try checkEqual(tree.ids("board.table"), [seed.spec, seed.plugin, seed.tests, seed.ship], "the board's own order")
        let row = tree.find(seed.spec)
        try checkEqual(row?.fields["cells"]?.arrayValue?.map(\.jsonText).prefix(5).map { String($0) },
                       ["\"Write the spec\"", "\"Backlog\"", "\"docs\"", "\"Open\"", "2"])
        try checkEqual(tree.find(seed.ship)?.fields["cells"]?.arrayValue?[3].stringValue, "Done")

        // Sorting is ours: Vektor draws the arrow and tells us the column.
        try await world.event("board.sort", ["block": "board.table", "column": "title", "ascending": true])
        tree = try world.tree
        try checkEqual(tree.ids("board.table"), [seed.plugin, seed.ship, seed.tests, seed.spec])
        try checkEqual(tree.find("board.table")?.fields["sorted"]?["column"]?.stringValue, "title")
        try await world.event("board.sort", ["block": "board.table", "column": "title", "ascending": false])
        try checkEqual(try world.tree.ids("board.table"), [seed.spec, seed.tests, seed.ship, seed.plugin])
        try await world.event("board.sort", ["block": "board.table", "column": "comments", "ascending": false])
        try checkEqual(try world.tree.ids("board.table").first, seed.spec, "most comments first")
        try await world.event("board.sort", ["block": "board.table", "column": "column", "ascending": false])
        try checkEqual(try world.tree.ids("board.table").first, seed.ship, "Done is the last column")
        try await world.event("board.sort", ["block": "board.table", "column": "done", "ascending": false])
        try checkEqual(try world.tree.ids("board.table").first, seed.ship)

        // The filter applies to the list too.
        try await world.event("board.search", ["value": "write"])
        try checkEqual(try world.tree.ids("board.table").count, 2)
        try await world.event("board.search", ["value": ""])

        // A selection and one delete for all of it.
        try check(try world.tree.find("board.deletesel")?.fields["enabled"]?.boolValue == false)
        try await world.event("board.select", ["block": "board.table", "selected": [.string(seed.tests), .string(seed.ship)]])
        let button = try world.tree.find("board.deletesel")
        try checkEqual(field(button, "title"), "Delete 2")
        try checkEqual(button?.fields["enabled"]?.boolValue, true)
        world.script([], confirm: true)
        try await world.event("board.deletesel", ["block": "board.deletesel"])
        try checkEqual(world.confirms.first?.title, "Delete 2 tasks?")
        try checkEqual(try world.tree.ids("board.table").sorted(), [seed.plugin, seed.spec].sorted())
        // ⌫ in the table with several selected is one event for the whole selection.
        world.script([], confirm: true)
        try await world.event("board.rdelete", ["block": .string(seed.spec), "selected": [.string(seed.spec), .string(seed.plugin)]])
        try checkEqual(world.confirms.first?.title, "Delete 2 tasks?")
        try check(world.controller!.file(seed.board)?.tasks.isEmpty == true)
        try check(try world.tree.has("board.norows"), "an empty list says so")
    }

    await test("a task: edit everything, tags by name, comments (author, time, text; add, delete only your own)") {
        let world = try await installed(author: "Ada")
        let seed = try await world.seedBoard()
        let controller = world.controller!
        controller.options.author = "Bob"
        let bobs = try await controller.addComment(to: seed.spec, in: seed.board, text: "Bob here.")
        controller.options.author = "Ada"
        try await world.open(seed.board)
        try await world.event("board.k.open", ["block": .string(seed.spec)])
        var tree = try world.tree
        try checkEqual(world.headerTitle, "Write the spec")
        try checkEqual(field(tree.find("board.t.title"), "value"), "Write the spec")
        try checkEqual(field(tree.find("board.t.desc"), "value"), "First **draft** of the spec.\nSecond line.")
        try checkEqual(field(tree.find("board.descpreview"), "markdown"), "First **draft** of the spec.\nSecond line.")
        try checkEqual(tree.find("board.t.tags")?.fields["tags"]?.arrayValue?.compactMap(\.stringValue), ["docs"])
        try checkEqual(tree.find("board.t.tags")?.fields["suggestions"]?.arrayValue?.compactMap(\.stringValue), ["docs", "urgent"])
        try checkEqual(tree.text("board.commentshead"), "Comments (3)")
        // Comments: author, time, text; a delete button only on your own.
        let comments = controller.comments(of: seed.spec, in: seed.board)
        let first = comments[0]
        try checkEqual(tree.text("board.cmauthor.\(first.id)"), "Ada")
        let when = tree.text("board.cmtime.\(first.id)") ?? ""
        try check(when == "just now" || when.hasSuffix("ago"), "a relative time: \(when)")
        // A conversation: your bubble trailing in the accent's fill, the others' leading in the neutral one; newest last; the
        // scroll opens at its end; the composer is outside the scroll, at the bottom.
        try checkEqual(tree.ids("board.cmline.\(first.id)").first, "board.cmspace.\(first.id)")
        try checkEqual(role(tree.find("board.cmbubble.\(first.id)")), "accent")
        try checkEqual(tree.find("board.cmbubble.\(first.id)")?.fields["filled"], .bool(true))
        try checkEqual(tree.ids("board.cmline.\(bobs)").last, "board.cmspace.\(bobs)")
        try checkEqual(role(tree.find("board.cmbubble.\(bobs)")), "neutral")
        try checkEqual(field(tree.find("board.taskscroll"), "anchor"), "end")
        try checkEqual(tree.ids("board.root").last, "board.composer")
        try check(tree.ids("board.taskscroll").suffix(3) == comments.suffix(3).map { "board.cm.\($0.id)" }, "comments in time order, newest last")
        try checkEqual(tree.text("board.cmtext.\(first.id)"), "Looks good.")
        try check(tree.has("board.cmdel.\(first.id)"))
        try check(tree.has("board.cmauthor.\(bobs)") && !tree.has("board.cmdel.\(bobs)"), "no delete on Bob's comment")

        try await world.event("board.t.title", ["block": "board.t.title", "value": "Write the final spec"])
        try await world.event("board.t.desc", ["block": "board.t.desc", "value": "# Spec\nDone soon."])
        try await world.event("board.t.done", ["block": "board.t.done", "value": true])
        try await world.event("board.t.column", ["block": "board.t.column", "value": .string(seed.progress)])
        // A tag typed that the board does not have becomes one; one taken off stays on the board.
        try await world.event("board.t.tags", ["block": "board.t.tags", "value": ["urgent", "needs review"]])
        let task = controller.task(seed.spec, in: seed.board)
        try checkEqual(task?.task.title, "Write the final spec")
        try checkEqual(task?.task.description, "# Spec\nDone soon.")
        try checkEqual(task?.task.done, true)
        try checkEqual(task?.task.column, seed.progress)
        try checkEqual(task?.tags.map(\.name), ["urgent", "needs review"])
        try check(controller.tags(of: seed.board).contains { $0.name == "docs" })

        // Add a comment: by the macOS user, now, and the field is a new, empty one.
        tree = try world.tree
        let composer = tree.all("textArea").compactMap(\.id).first { $0.hasPrefix("board.cm.new.") }!
        try await world.event("board.cm.add", ["block": .string(composer), "value": "Thanks, Bob."])
        let added = controller.comments(of: seed.spec, in: seed.board).last!
        try checkEqual(added.text, "Thanks, Bob.")
        try checkEqual(added.author, "Ada")
        tree = try world.tree
        try checkEqual(tree.text("board.commentshead"), "Comments (4)")
        try check(tree.all("textArea").compactMap(\.id).contains { $0.hasPrefix("board.cm.new.") && $0 != composer }, "the comment box is a fresh one")
        try await world.event("board.cm.add", ["value": "   "])
        try checkEqual(controller.comments(of: seed.spec, in: seed.board).count, 4, "an empty comment is not added")
        // Delete your own; Bob's is refused in words even if someone asks.
        try await world.event("board.cmdel", ["block": .string("board.cmdel.\(added.id)")])
        try checkEqual(controller.comments(of: seed.spec, in: seed.board).count, 3)
        try await world.event("board.cmdel", ["block": .string("board.cmdel.\(bobs)")])
        try checkEqual(world.alerts.last, "Only its author can delete a comment.")

        // Delete the task from here, or lose it to a sync meanwhile: back to the board.
        world.script([], confirm: true)
        try await world.event("board.t.delete")
        try check(try world.tree.has("board.columns"), "back on the board")
        try await world.event("board.k.open", ["block": .string(seed.tests)])
        try await controller.deleteTask(seed.tests, in: seed.board)
        try await world.quiet()
        try check(try world.tree.has("board.columns"), "a task that is gone closes its screen")
        try await world.event("board.k.open", ["block": .string(seed.plugin)])
        try await world.event("board.back")
        try check(try world.tree.has("board.columns"))
    }

    await test("Board settings: columns (order, name, colour), tags, general (name; the place, read-only, in words)") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        let controller = world.controller!
        try await world.event("board.m.settings")
        try checkEqual(world.headerTitle, "Board settings")
        var tree = try world.tree
        try checkEqual(tree.find("board.stab")?.fields["options"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Columns", "Tags", "General"])
        try checkEqual(tree.all("textField").compactMap { $0.fields["value"]?.stringValue }, ["Backlog", "In Progress", "Review", "Done"])
        try checkEqual(field(tree.find("board.scrole.\(seed.backlog)"), "value"), "neutral")
        try checkEqual(tree.text("board.sccount.\(seed.backlog)"), "2 tasks")

        try await world.event("board.scname", ["block": .string("board.scname.\(seed.backlog)"), "value": "Ideas"])
        try await world.event("board.scrole", ["block": .string("board.scrole.\(seed.backlog)"), "value": "label8"])
        try await world.event("board.scdown", ["block": .string("board.scdown.\(seed.backlog)")])
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["In Progress", "Ideas", "Review", "Done"])
        try checkEqual(controller.columns(of: seed.board)[1].column.role, "label8")
        try await world.event("board.scup", ["block": .string("board.scup.\(seed.backlog)")])
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["Ideas", "In Progress", "Review", "Done"])
        tree = try world.tree
        try checkEqual(tree.find("board.scup.\(seed.backlog)")?.fields["enabled"]?.boolValue, false, "the first cannot go up")
        // A refused name says why, and the field shows the real one again.
        try await world.event("board.scname", ["block": .string("board.scname.\(seed.backlog)"), "value": ""])
        try checkEqual(world.alerts.last, "A column needs a name.")
        try checkEqual(world.viewMessages.last?.method, "view/update", "the whole description again, so the field shows the real name")
        try checkEqual(field(try world.tree.find("board.scname.\(seed.backlog)"), "value"), "Ideas")
        world.script([["title": "Blocked", "role": "label1"]])
        try await world.event("board.scadd")
        try checkEqual(controller.columns(of: seed.board).last?.column.title, "Blocked")
        try checkEqual(controller.columns(of: seed.board).last?.column.role, "label1")
        world.script([["tasks": .string("delete")]])
        try await world.event("board.scdel", ["block": .string("board.scdel.\(seed.backlog)")])
        try checkEqual(controller.columns(of: seed.board).map(\.column.title), ["In Progress", "Review", "Done", "Blocked"])

        // Tags.
        try await world.event("board.stab", ["value": "tags"])
        tree = try world.tree
        try checkEqual(tree.all("textField").compactMap { $0.fields["value"]?.stringValue }, ["docs", "urgent"])
        try await world.event("board.stname", ["block": .string("board.stname.\(seed.docs)"), "value": "documentation"])
        try await world.event("board.strole", ["block": .string("board.strole.\(seed.docs)"), "value": "label5"])
        try await world.event("board.stdown", ["block": .string("board.stdown.\(seed.docs)")])
        try checkEqual(controller.tags(of: seed.board).map(\.name), ["urgent", "documentation"])
        try checkEqual(controller.tags(of: seed.board).last?.role, "label5")
        try await world.event("board.stname", ["block": .string("board.stname.\(seed.docs)"), "value": "URGENT"])
        try check(world.alerts.last?.contains("already has a tag") == true, world.alerts.last ?? "")
        world.script([["name": "later", "role": "label2"]])
        try await world.event("board.stadd")
        try checkEqual(controller.tags(of: seed.board).last?.name, "later")
        try checkEqual(controller.tags(of: seed.board).last?.role, "label2")
        world.script([], confirm: true)
        try await world.event("board.stdel", ["block": .string("board.stdel.\(seed.urgent)")])
        try checkEqual(world.confirms.first?.title, "Delete the tag “urgent”?")
        try check(controller.file(seed.board)?.tasks.allSatisfy { !$0.tags.contains(seed.urgent) } == true)

        // General.
        try await world.event("board.stab", ["value": "general"])
        tree = try world.tree
        try checkEqual(field(tree.find("board.gname"), "value"), "Roadmap")
        try check(tree.text("board.sgplace")?.hasPrefix("Local, in the plugin's own folder.") == true)
        try check((tree.text("board.sgplacehelp") ?? "").contains("Settings ▸ Plugins ▸ Board"), "says where the place is chosen")
        try check(!tree.all("textField").contains { $0.fields["value"]?.stringValue == "Local" }, "the place is not editable here")
        try await world.event("board.gname", ["block": "board.gname", "value": "Roadmap 2027"])
        try checkEqual(controller.boardName(seed.board), "Roadmap 2027")
        world.script([], confirm: true)
        try await world.event("board.gdelete")
        try check(controller.boards.isEmpty)
        try check(try world.tree.has("board.none"), "no boards left: the empty state")
    }

    await test("Sync (a place on a connection): button, progress, \"Last synced\", the error in words; none for a local place") {
        let local = try await installed()
        let localSeed = try await local.seedBoard()
        try await local.open(localSeed.board)
        try check(!(try local.tree.has("board.syncbutton")))

        let world = try await installed(remote: true, place: true)
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        var tree = try world.tree
        try check(tree.has("board.syncbutton"))
        try checkEqual(tree.find("board.syncbutton")?.fields["enabled"]?.boolValue, true)
        try checkEqual(tree.text("board.syncinfo"), "Not synced yet · changes not sent yet")
        let before = world.viewMessages.count
        try await world.event("board.sync")
        try check(world.viewMessages.count - before >= 2, "the button changes while it runs")
        let busy = world.viewMessages.dropFirst(before).contains { $0.params.jsonText.contains("\"busy\":true") }
        try check(busy, "the Sync button is busy (and disabled) while it runs")
        let progress = world.viewMessages.dropFirst(before).contains { $0.params.jsonText.contains("Board 1 of") || $0.params.jsonText.contains("Syncing") }
        try check(progress, "progress is shown while it runs")
        tree = try world.tree
        try checkEqual(tree.find("board.syncbutton")?.fields["busy"]?.boolValue, false)
        try checkEqual(tree.find("board.syncbutton")?.fields["enabled"]?.boolValue, true)
        try checkEqual(tree.text("board.syncinfo"), "Last synced just now")
        try checkEqual(world.toasts.last, "Synced. Sent 2, received 0.")
        try await world.event("board.sync")
        try checkEqual(world.toasts.last, "Already up to date.")

        // A place that cannot be read as boards: the error in plain words, nothing lost, and still a Sync button.
        try await world.controller!.addTask(to: seed.board, column: seed.backlog, title: "Unsent")
        try "this is not json".write(to: world.placeFolder.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try await world.event("board.sync")
        tree = try world.tree
        try checkEqual(tree.text("board.syncinfo"), "The last sync failed")
        try checkEqual(role(tree.find("board.syncinfo")), "danger")
        try check((tree.find("board.syncerror")?.fields["text"]?.stringValue ?? "").contains("Nothing was lost"), tree.words)
        try check(world.controller!.file(seed.board)?.tasks.contains { $0.title == "Unsent" } == true, "the unsent task is still here")
        try checkEqual(tree.find("board.syncbutton")?.fields["enabled"]?.boolValue, true)
    }

    await test("questions after a sync: both versions side by side in the diff block, the reason, the choices; nothing resolves silently") {
        @MainActor func scenario(_ choice: String) async throws -> (World, BoardController, World.Seed) {
            let world = try await installed(remote: true, place: true)
            let a = world.controller!
            let seed = try await world.seedBoard()
            _ = await a.sync()
            let b = try world.copy("B", author: "Bob")
            await b.activate(workspace: Workspace(id: "w1", name: "Work"), place: world.handle)
            _ = await b.sync()
            try await b.updateTask(seed.spec, in: seed.board, title: "Spec by Bob", description: "Bob's text")
            _ = await b.sync()
            try await a.updateTask(seed.spec, in: seed.board, title: "Spec by Ada", description: "Ada's text")
            try await world.open(seed.board)
            try await world.event("board.sync")
            return (world, a, seed)
        }

        var (world, a, seed) = try await scenario("keepTheirs")
        let tree = try world.tree
        try checkEqual(world.headerTitle, "1 thing to decide", "a sync that ends with a question takes you to it")
        let section = tree.all("section").first
        try check(section?.fields["title"]?.stringValue?.contains("Spec by Ada") == true, section?.fields["title"]?.stringValue ?? "")
        let diff = tree.all("diff").first
        try check(field(diff, "left")?.hasPrefix("Spec by Ada") == true && field(diff, "left")?.contains("Ada's text") == true, field(diff, "left") ?? "")
        try check(field(diff, "right")?.hasPrefix("Spec by Bob") == true && field(diff, "right")?.contains("Bob's text") == true, field(diff, "right") ?? "")
        try checkEqual(field(diff, "leftTitle"), "Yours")
        try checkEqual(field(diff, "rightTitle"), "In the place")
        try check(tree.words.contains("Changed here and in the place, differently."))
        try checkEqual(tree.all("button").filter { ($0.id ?? "").hasPrefix("board.cf.") }.compactMap { field($0, "title") },
                       ["Keep Your Version", "Keep the Place's Version", "Keep Both"])
        // Nothing was decided: the local copy still has its version, the place still has Bob's.
        try checkEqual(a.file(seed.board)?.tasks.first { $0.id == seed.spec }?.title, "Spec by Ada")
        try checkEqual(try world.placeJSON("boards/\(seed.board).json").value(at: "tasks")?.arrayValue?.first { $0["id"]?.stringValue == seed.spec }?["title"]?.stringValue, "Spec by Bob")
        // The board view says so too, until it is answered.
        try await world.event("board.back")
        try check(try world.tree.has("board.conflictbanner") && (try world.tree.has("board.review")))
        try await world.event("board.review")
        // Keep theirs.
        let buttons = try answerButtons(world)
        try check(buttons.count == 3)
        let theirs = buttons.first { $0.hasSuffix(".keepTheirs") }!
        try await world.event("board.resolve", ["block": .string(theirs)])
        try checkEqual(a.file(seed.board)?.tasks.first { $0.id == seed.spec }?.title, "Spec by Bob")
        try check(a.status.conflicts.isEmpty)
        try check(try world.tree.has("board.columns"), "answered: back on the board")
        try check(!(try world.tree.has("board.conflictbanner")))
        try checkEqual(world.toasts.last, "Your answers were applied.")

        // Keep mine: the place gets the local version at the sync that applies the answer.
        (world, a, seed) = try await scenario("keepMine")
        let mine = try answerButtons(world).first { $0.hasSuffix(".keepMine") }!
        try await world.event("board.resolve", ["block": .string(mine)])
        try checkEqual(try world.placeJSON("boards/\(seed.board).json").value(at: "tasks")?.arrayValue?.first { $0["id"]?.stringValue == seed.spec }?["title"]?.stringValue, "Spec by Ada")

        // Keep both: two tasks.
        (world, a, seed) = try await scenario("keepBoth")
        let both = try answerButtons(world).first { $0.hasSuffix(".keepBoth") }!
        try await world.event("board.resolve", ["block": .string(both)])
        let titles = a.file(seed.board)?.tasks.map(\.title) ?? []
        try check(titles.contains("Spec by Ada") && titles.contains("Spec by Bob"), "\(titles)")

        // Deleted on one side, changed on the other: the reason in words, and no "keep both".
        world = try await installed(remote: true, place: true)
        a = world.controller!
        seed = try await world.seedBoard()
        _ = await a.sync()
        let bob = try world.copy("B", author: "Bob")
        await bob.activate(workspace: Workspace(id: "w1", name: "Work"), place: world.handle)
        _ = await bob.sync()
        try await bob.updateTask(seed.tests, in: seed.board, title: "Tests by Bob")
        _ = await bob.sync()
        try await a.deleteTask(seed.tests, in: seed.board)
        try await world.open(seed.board)
        try await world.event("board.sync")
        let deleted = try world.tree
        try check(deleted.words.contains("Deleted here, but changed in the place."), deleted.words)
        try checkEqual(field(deleted.all("diff").first, "left"), "(deleted here)")
        try checkEqual(deleted.all("button").filter { ($0.id ?? "").hasPrefix("board.cf.") }.compactMap { field($0, "title") }, ["Keep It Deleted", "Keep the Place's Version"])
    }

    await test("empty, loading and error states are drawn in words, with a way forward") {
        // Loading: the view opened before the plugin has read the boards.
        let early = try TestHost.start(folder: pluginFolder) { setup($0) }
        early.openView(BoardIDs.view)
        _ = try await early.waitUntil("a description of the view") { $0.method == "view/update" }
        let loading = early.notifications("view/update").last?.params.jsonText ?? ""
        try check(loading.contains("Loading your boards…"), loading)
        try await early.startup()
        _ = try await early.waitUntil("the empty state", { ($0.method == "view/update" || $0.method == "view/patch") && $0.params.jsonText.contains("No boards yet") })
        await early.close()

        // No boards: the empty state with New Board…, which creates one and shows it.
        let world = try await installed()
        try await world.open()
        var tree = try world.tree
        try check(tree.has("board.none") && tree.has("board.newboard"))
        try check(tree.words.contains("No boards yet"))
        world.script([["name": "First"]])
        try await world.event("board.m.new", ["block": "board.newboard"])
        try checkEqual(world.headerTitle, "First")

        // No tasks, then a filter that hides everything.
        let board = world.controller!.boards[0].id
        tree = try world.tree
        // An empty board says so in its first column (how to add a task); the others say "No tasks"; no line above them.
        let backlog = world.controller!.columnID("Backlog", in: board)!
        let progress = world.controller!.columnID("In Progress", in: board)!
        try check(field(tree.find("board.list.\(backlog)"), "placeholder")?.hasPrefix("No tasks yet.") == true)
        try checkEqual(field(tree.find("board.list.\(progress)"), "placeholder"), "No tasks")
        try check(!tree.has("board.notasks"))
        try await world.controller!.addTask(to: board, column: backlog, title: "Only one")
        try await world.event("board.search", ["value": "zzz"])
        tree = try world.tree
        try checkEqual(tree.text("board.filtered"), "No task matches. 1 task is hidden.")
        try check(tree.has("board.clear"))
        try await world.event("board.layout", ["value": "list"])
        try check(try world.tree.has("board.norows") && (try world.tree.words.contains("No matching tasks")))
        try await world.event("board.clear")
        try await world.event("board.layout", ["value": "board"])

        // A board without columns.
        for column in world.controller!.columns(of: board).map(\.column.id) { try await world.controller!.deleteColumn(column, in: board, tasks: .delete) }
        try await world.quiet()
        tree = try world.tree
        try check(tree.has("board.nocolumns") && tree.has("board.newcolumn"))

        // A board of another workspace: said in words, with a way to show one of this workspace's.
        let other = try await installed()
        let mine = try await other.controller!.createBoard(name: "Mine")
        try await other.open("b-from-another-workspace")
        tree = try other.tree
        try check(tree.words.contains("This board belongs to another workspace"), tree.words)
        try check(tree.find("board.first")?.fields["title"]?.stringValue == "Show “Mine”")
        try await other.event("board.first")
        try checkEqual(other.headerTitle, "Mine")
        _ = mine

        // A workspace that is read-only because its list of boards cannot be read: the reason, and nothing is overwritten.
        let broken = try await World(remote: false, install: true, place: false) { data in
            let folder = data.appendingPathComponent("workspaces/w-w1/working")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "{ not a board index".write(to: folder.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        }
        try await broken.open()
        let brokenWords = try broken.tree.words
        try check(brokenWords.contains("The boards could not be read"), brokenWords)
        await broken.controller!.settle()
        let kept = try String(contentsOf: broken.host.dataFolder.appendingPathComponent("workspaces/w-w1/working/index.json"))
        try checkEqual(kept, "{ not a board index")

        // A place that has the boards but the local copy has none yet: the view waits for the first sync in words.
        let fresh = try await installed(remote: true, place: true)
        try await fresh.open()
        let buttons = try fresh.tree
        try check(buttons.has("board.syncbutton"), "an empty remote workspace can sync to get its boards")
    }

    await test("switching workspace shows only that workspace's boards, in the view and the sidebar") {
        let world = try await installed()
        let seed = try await world.seedBoard()
        try await world.open(seed.board)
        world.host.send("workspace/changed", ["id": "w2", "name": "Home"])
        try await world.quiet()
        try check(try world.tree.words.contains("This board belongs to another workspace"))
        try checkEqual(world.host.notifications("sidebar/items").last?.params["items"]?.arrayValue?.count, 0)
        world.script([["name": "Garden"]])
        try await world.event("board.m.new", ["block": "board.newboard"])
        try checkEqual(world.headerTitle, "Garden")
        world.host.send("workspace/changed", ["id": "w1", "name": "Work"])
        try await world.quiet()
        try check(try world.tree.words.contains("This board belongs to another workspace"), "Garden is not Work's")
        // The entry itself (no item) shows this workspace's boards, never the other one's "foreign" notice.
        try await world.open(nil)
        try checkEqual(world.headerTitle, "Roadmap")
        world.host.send("workspace/changed", ["id": "w2", "name": "Home"])
        try await world.quiet()
        try await world.open("b-not-here")
        world.host.send("workspace/changed", ["id": "w1", "name": "Work"])
        try await world.quiet()
        try check(try world.tree.words.contains("This board belongs to another workspace"))
        try await world.event("board.first")
        try checkEqual(world.headerTitle, "Roadmap")
    }

    await test("the view open from the start (no boards yet), boards made in two workspaces, then an item and the switcher") {
        let world = try await installed()
        try await world.open(nil)
        try check(try world.tree.has("board.none"))
        world.script([["name": "Roadmap"]])
        try await world.event("board.m.new", ["block": "board.newboard"])
        world.script([["name": "Ideas"]])
        try await world.event("board.m.new", ["block": "board.more"])
        try checkEqual(world.headerTitle, "Ideas")
        let roadmap = world.controller!.boards.first { $0.name == "Roadmap" }!.id
        let ideas = world.controller!.boards.first { $0.name == "Ideas" }!.id
        world.host.send("workspace/changed", ["id": "w2", "name": "Home"])
        try await world.quiet()
        world.script([["name": "Garden"]])
        try await world.event("board.m.new", ["block": "board.newboard"])
        try checkEqual(world.headerTitle, "Garden")
        world.host.send("workspace/changed", ["id": "w1", "name": "Work"])
        try await world.quiet()
        try await world.open(ideas)
        try checkEqual(world.headerTitle, "Ideas")
        try checkEqual(world.viewState.description?.other["item"], .string(ideas))
        try await world.event("board.switch", ["block": "board.switch", "value": .string(roadmap)])
        try checkEqual(world.headerTitle, "Roadmap")
        try checkEqual(world.viewState.description?.other["item"], .string(roadmap))
    }

    await test("a board of thousands of tasks: one move is a few operations, never the board again") {
        let count = 3000
        let columnIDs = ["c-todo", "c-doing", "c-done"]
        let board = "b-big"
        let world = try await World(remote: false, install: true, place: false) { data in
            let folder = data.appendingPathComponent("workspaces/w-w1/working")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("boards"), withIntermediateDirectories: true)
            var file = BoardFile(board: board, columns: columnIDs.enumerated().map { ColumnRecord(id: $1, title: "Column \($0)", rank: Rank.spread(3)[$0], updatedAt: "2026-01-01T00:00:00.000Z") })
            file.tags = [TagRecord(id: "g-a", name: "alpha", role: "label6", rank: "m", updatedAt: "2026-01-01T00:00:00.000Z")]
            let ranks = Rank.spread(count)
            for n in 0..<count {
                file.tasks.append(TaskRecord(
                    id: "t-\(n)", column: columnIDs[n % 3], rank: ranks[n / 3], title: "Task number \(n)", description: n % 2 == 0 ? "Some *text* for \(n)" : "",
                    tags: n % 5 == 0 ? ["g-a"] : [], createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"))
                if n % 7 == 0 { file.comments.append(CommentRecord(id: "m-\(n)", task: "t-\(n)", author: "Ada", time: "2026-01-01T00:00:00.000Z", text: "c", updatedAt: "2026-01-01T00:00:00.000Z")) }
            }
            let encoder = JSONEncoder()
            try encoder.encode(file).write(to: folder.appendingPathComponent("boards/\(board).json"))
            try encoder.encode(BoardIndexFile(boards: [BoardRecord(id: board, name: "Big", rank: "m", updatedAt: "2026-01-01T00:00:00.000Z")])).write(to: folder.appendingPathComponent("index.json"))
        }
        let started = Date()
        try await world.open(board)
        let whole = Date().timeIntervalSince(started)
        let wholeBytes = world.viewMessages.last?.params.jsonData.count ?? 0
        try checkEqual(try world.tree.all("card").count, count)
        // Move one card to the top of another column.
        let first = Date()
        try await world.event("board.move", ["item": "t-0", "from": "board.list.c-todo", "target": "board.list.c-doing", "index": 0])
        let moved = Date().timeIntervalSince(first)
        let patch = world.patches.last
        let ops = patch?.params["ops"]?.arrayValue?.count ?? 0
        let patchBytes = patch?.params.jsonData.count ?? 0
        print(String(format: "     3000 tasks: whole description %d bytes in %.2fs (open, draw, send); one move: %d operations, %d bytes, %.2fs (handle, redraw, diff, send)", wholeBytes, whole, ops, patchBytes, moved))
        try check(patch != nil && ops >= 1 && ops <= 6, "a move is a patch of a few operations: \(ops)")
        try check(patchBytes < 3_000, "\(patchBytes) bytes")
        try check(wholeBytes > 100 * patchBytes, "the patch is a small fraction of the board")
        try checkEqual(try cards(world, "c-doing").first, "t-0")
        // Rename, done, filters: each a patch too.
        let before = world.patches.count
        try await world.event("board.done", ["block": "t-1", "value": true])
        try await world.event("board.rename", ["block": "t-2", "value": "Renamed"])
        try checkEqual(world.patches.count - before, 2)
        try check(world.patches.suffix(2).allSatisfy { ($0.params.jsonData.count) < 3_000 })
        try await world.event("board.search", ["value": "number 299"])
        try check(try world.tree.all("card").count > 0 && (try world.tree.all("card").count) < 100)
    }

    await test("the Log has counts and plain words only: no title, description, comment, tag or place from the view") {
        let world = try await installed(remote: true, place: true)
        let controller = world.controller!
        let board = try await controller.createBoard(name: "SECRET-BOARD")
        let column = controller.columnID("Backlog", in: board)!
        let tag = try await controller.addTag(to: board, name: "SECRET-TAG")
        let task = try await controller.addTask(to: board, column: column, title: "SECRET-TITLE", description: "SECRET-DESCRIPTION", tags: [tag])
        try await controller.addComment(to: task, in: board, text: "SECRET-COMMENT")
        try await world.open(board)
        try await world.event("board.sync")
        try await world.event("board.k.open", ["block": .string(task)])
        try await world.event("board.back")
        try await world.event("board.search", ["value": "SECRET-TITLE"])
        world.host.refuse(BoardIDs.view, problem: "operation 1 cannot apply.")
        try await world.quiet()
        let logs = world.host.notifications("log").compactMap { $0.params["message"]?.stringValue }
        try check(!logs.isEmpty)
        try check(!logs.contains { $0.contains("SECRET") }, "\(logs)")
    }
}
