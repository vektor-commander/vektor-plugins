import Foundation
import VektorPlugin

// The five layouts: the JSON they build, pinned in sdk/fixtures/layouts.json (the Node SDK's tests build the same inputs and
// compare with the same file), that Vektor would accept it, and that events reach the right callback.

private func boardColumns() -> [BoardColumn] {
    [
        BoardColumn(id: "todo", title: "To do", role: .label6, cards: [
            BoardCard(id: "c1", title: "Write the spec", subtitle: "Draft first", role: .accent, tags: [BoardTag("docs", role: .label3)]),
            BoardCard(id: "c2", title: "Ship it"),
        ]),
        BoardColumn(id: "done", title: "Done", role: .label4),
    ]
}

private func makeBoard() -> Board {
    var board = Board(columns: boardColumns())
    board.filterOptions = [Option(value: "", title: "All"), Option(value: "docs", title: "docs")]
    board.toolbar = [.button(id: "sync", title: "Sync", symbol: "arrow.triangle.2.circlepath", action: "sync")]
    return board
}

private func makeListDetail() -> ListDetail {
    var layout = ListDetail(items: [
        ListDetailItem(id: "a", title: "Alpha", subtitle: "first", symbol: "doc", badge: Badge("new", role: .positive)),
        ListDetailItem(id: "b", title: "Beta"),
    ])
    layout.selected = "a"
    var panel = DetailPanel(title: "Alpha")
    panel.subtitle = "first"
    panel.symbol = "doc"
    panel.fields = [(label: "Size", value: "3 KB")]
    panel.markdown = "Hello"
    panel.actions = [DetailAction(key: "open", title: "Open", style: .primary)]
    layout.detail = panel.blocks
    return layout
}

private func makeTable() -> TableWithToolbar {
    let columns = [Column(id: "name", title: "Name", sortable: true), Column(id: "size", title: "Size", width: 80, sortable: true)]
    let sorted = (column: "size", ascending: false)
    let rows = TableRow.sorted([
        TableRow(id: "r1", cells: ["a", 5]), TableRow(id: "r2", cells: ["b", 20]), TableRow(id: "r3", cells: ["c", 1], dimmed: true),
    ], columns: columns, by: sorted)
    var table = TableWithToolbar(columns: columns, rows: rows)
    table.sorted = sorted
    table.selected = ["r1", "r2"]
    table.toolbar = [
        ToolbarButton(key: "delete", title: "Delete", symbol: "trash", style: .destructive, needsSelection: true),
        ToolbarButton(key: "add", title: "Add", symbol: "plus"),
    ]
    return table
}

private func makeForm() -> SettingsForm {
    SettingsForm(sections: [
        SettingsSection(id: "general", title: "General", description: "How it works.", fields: [
            SettingsField(key: "name", label: "Name", kind: .text(value: "Vektor", placeholder: "A name"), help: "Shown in the title"),
            SettingsField(key: "sync", label: "Sync", kind: .toggle(value: true)),
            SettingsField(key: "mode", label: "Mode", kind: .picker(options: [Option(value: "a", title: "A"), Option(value: "b", title: "B")], value: "a", segmented: true)),
            SettingsField(key: "notes", label: "Notes", kind: .textArea(value: "x", placeholder: nil), error: "Too short"),
        ]),
        SettingsSection(id: "more", title: "More", collapsible: true, collapsed: true, fields: [
            SettingsField(key: "count", label: "Count", kind: .stepper(value: 2, min: 0, max: 9, step: nil)),
            SettingsField(key: "colour", label: "Colour", kind: .role(value: .label1, roles: [.label1, .label4])),
            SettingsField(key: "reset", label: "Defaults", kind: .button(title: "Reset", symbol: "arrow.counterclockwise", style: .destructive)),
        ]),
    ])
}

private func makeCards() -> CardList {
    CardList(cards: [
        CardItem(id: "k1", title: "Tunnel", symbol: "cloud", pill: Badge("Running", role: .positive),
                 lines: ["example.com", CardLine("Open", link: "https://example.com")], openable: true,
                 buttons: [CardButton(key: "stop", title: "Stop", symbol: "stop"), CardButton(key: "copy", symbol: "doc.on.doc", tooltip: "Copy")],
                 menu: [.item(key: "rename", title: "Rename"), .separator, .item(key: "delete", title: "Delete", symbol: "trash", destructive: true)]),
        CardItem(id: "k2", title: "Plain"),
    ])
}

@MainActor
private let layoutCases: [String: () throws -> Block] = [
    "board": { makeBoard().block },
    "board: columns fill the pane": {
        var board = makeBoard()
        board.columnMinWidth = 260
        return board.block
    },
    "board: filtered": {
        var board = makeBoard()
        board.search = "ship"
        return board.block
    },
    "listDetail": { makeListDetail().block },
    "listDetail: nothing chosen": {
        var layout = makeListDetail()
        layout.selected = nil
        layout.search = "be"
        layout.emptyDetail = (nil, "Choose an item.", "sidebar.right")
        return layout.block
    },
    "table": { makeTable().block },
    "settingsForm": { makeForm().block },
    "cardList": { try makeCards().block },
    "cardList: empty": {
        var cards = CardList(cards: [])
        cards.empty = ("No tunnels", "Create one.", "cloud")
        return try cards.block
    },
]

/// Records what the callbacks were called with.
@MainActor
private final class Calls {
    var log: [String] = []
}

@MainActor
private func fire(_ view: ViewState, _ params: JSONValue) async throws {
    var all = params.objectValue!
    all["view"] = "v"
    try await view.receive("view/event", .object(all))
}

@MainActor
private func freshView() -> ViewState { ViewState(view: "v", sink: Recorder()) }

@MainActor
func layoutTests() async {
    await test("layouts: every layout builds exactly the JSON in sdk/fixtures/layouts.json") {
        let fixtures = try JSONValue.parse(try Data(contentsOf: repository.appendingPathComponent("sdk/fixtures/layouts.json")))
        try checkEqual(Set(layoutCases.keys), Set(fixtures.objectValue!.keys), "a fixture without a Swift case, or the reverse")
        for name in layoutCases.keys.sorted() { try checkEqual(try layoutCases[name]!().json, fixtures[name]!, name) }
    }

    await test("layouts: every layout is a tree Vektor accepts, with no colour value") {
        for (name, build) in layoutCases {
            let result = validateBlocks(try build().json)
            try check(result.problems.isEmpty && result.warnings.isEmpty, "\(name): \(result)")
        }
    }

    await test("board: events reach the typed callbacks") {
        let view = freshView()
        let calls = Calls()
        makeBoard().route(on: view, BoardHandlers(
            onAdd: { calls.log.append("add \($0)") }, onOpen: { calls.log.append("open \($0)") },
            onRename: { calls.log.append("rename \($0) \($1)") }, onRemove: { calls.log.append("remove \($0)") },
            onMove: { calls.log.append("move \($0.card) \($0.from ?? "-") \($0.to) \($0.index)") },
            onColumnAction: { calls.log.append("column \($0) \($1)") }, onSearch: { calls.log.append("search \($0)") },
            onFilter: { calls.log.append("filter \($0)") }))
        try await fire(view, ["action": "board.add", "block": "board.add.todo"])
        try await fire(view, ["action": "board.open", "block": "c1"])
        try await fire(view, ["action": "board.rename", "block": "c1", "value": "New title"])
        try await fire(view, ["action": "board.remove", "block": "c2"])
        try await fire(view, ["action": "board.move", "item": "c1", "from": "board.list.todo", "target": "board.list.done", "index": 2])
        try await fire(view, ["action": "board.column.delete", "block": "board.colmenu.done"])
        try await fire(view, ["action": "board.search", "block": "board.search", "value": "spec"])
        try await fire(view, ["action": "board.filter", "block": "board.filter", "value": "docs"])
        try checkEqual(calls.log, [
            "add todo", "open c1", "rename c1 New title", "remove c2", "move c1 todo done 2", "column done delete", "search spec", "filter docs",
        ])
    }

    await test("layouts: a callback reads the whole event, and whether it is stale, from ViewEvent.current") {
        let view = freshView()
        let calls = Calls()
        try view.update(ViewDescription(root: makeBoard().block))
        try view.update(ViewDescription(root: makeBoard().block))   // revision 2
        makeBoard().route(on: view, BoardHandlers(onSearch: { text in
            calls.log.append("\(text) \(ViewEvent.current?.action ?? "-") stale=\(ViewEvent.current?.isStale ?? false)")
        }))
        try await fire(view, ["action": "board.search", "value": "x", "revision": 1])
        try await fire(view, ["action": "board.search", "value": "y", "revision": 2])
        try checkEqual(calls.log, ["x board.search stale=true", "y board.search stale=false"])
        try check(ViewEvent.current == nil)
    }

    await test("board: a move made against an older description is dropped, other events are not") {
        let view = freshView()
        let calls = Calls()
        try view.update(ViewDescription(root: makeBoard().block))
        try view.update(ViewDescription(root: makeBoard().block))   // revision 2
        makeBoard().route(on: view, BoardHandlers(onMove: { _ in calls.log.append("move") }, onSearch: { _ in calls.log.append("search") }))
        try await fire(view, ["action": "board.move", "item": "c1", "target": "board.list.done", "index": 0, "revision": 1])
        try await fire(view, ["action": "board.search", "value": "x", "revision": 1])
        try await fire(view, ["action": "board.move", "item": "c1", "target": "board.list.done", "index": 0, "revision": 2])
        try checkEqual(calls.log, ["search", "move"])
    }

    await test("board: moving a card is a move patch, not a replaced column") {
        // A board of 40 cards: a patch is sent when it is smaller than the whole description, which it is only if the counts
        // (blocks of their own) change instead of the columns' own fields.
        var columns = [
            BoardColumn(id: "a", title: "A", cards: (0..<20).map { BoardCard(id: "a\($0)", title: "Card \($0)", tags: [BoardTag("x")]) }),
            BoardColumn(id: "b", title: "B", cards: (0..<20).map { BoardCard(id: "b\($0)", title: "Card \($0)") }),
        ]
        let recorder = Recorder()
        let view = ViewState(view: "w", sink: recorder)
        try view.show(ViewDescription(root: Board(columns: columns).block))
        _ = Board.apply(BoardMove(card: "a3", to: "b", index: 5), to: &columns)
        let outcome = try view.show(ViewDescription(root: Board(columns: columns).block))
        try check(outcome == .patch, "\(outcome)")
        let ops = recorder.sent[1].params["ops"]!.arrayValue!
        try check(ops.contains { $0["op"] == "move" && $0["id"] == "a3" && $0["parent"] == "board.list.b" && $0["index"] == 5 }, JSONValue.array(ops).jsonText)
        try check(!ops.contains { $0["op"] == "replace" && ($0["id"]?.stringValue ?? "").hasPrefix("board.col.") }, "a column was replaced")
        try check(JSONValue.array(ops).jsonText.count < 600, "a small patch")
    }

    await test("board: the \"All\" filter option (value \"\") goes out as a value Vektor accepts and comes back as \"\"") {
        var board = makeBoard()
        let filter = board.block.json.value(at: "children.0.children.1")!
        try checkEqual(filter["type"], "picker")
        try checkEqual(filter["options"]?.arrayValue?.map { $0["value"] }, ["board.all", "docs"])
        try checkEqual(filter["value"], "board.all")
        board.filter = "docs"
        try checkEqual(board.block.json.value(at: "children.0.children.1.value"), "docs")
        board.id = "roadmap"
        board.filter = ""
        try checkEqual(board.block.json.value(at: "children.0.children.1.value"), "roadmap.all")
        let view = freshView()
        let calls = Calls()
        makeBoard().route(on: view, BoardHandlers(onFilter: { calls.log.append("filter [\($0)]") }))
        try await fire(view, ["action": "board.filter", "block": "board.filter", "value": "board.all"])
        try await fire(view, ["action": "board.filter", "block": "board.filter", "value": "docs"])
        try checkEqual(calls.log, ["filter []", "filter [docs]"])
    }

    await test("board: a card opens from its context menu (Vektor gives `edit` precedence on Return); the \"…\" has a VoiceOver label") {
        let todo = makeBoard().block.json.value(at: "children.1.children.0.children.0")!
        let c1 = todo.value(at: "children.1.children.0")!
        try checkEqual(c1["id"], "c1")
        try checkEqual(c1["edit"], "board.rename")
        try checkEqual(c1["action"], nil, "an action would never fire beside edit")
        try checkEqual(c1["menu"], [["title": "Open", "action": "board.open"]])
        let more = todo.value(at: "children.0.children")!.arrayValue!.first { $0["type"] == "menu" }
        try checkEqual(more?["label"], "To do actions")
    }

    await test("board: a custom id and column menu") {
        var board = makeBoard()
        board.id = "roadmap"
        board.columnMenu = [BoardColumnAction(key: "archive", title: "Archive")]
        let text = board.block.json.jsonText
        try check(board.block.id == "roadmap" && text.contains("\"roadmap.column.archive\"") && !text.contains("\"board."), text)
    }

    await test("board: Board.apply counts shown cards only, and keeps hidden ones in place") {
        var columns = [
            BoardColumn(id: "a", title: "A", cards: ["1": "one", "2": "two x", "3": "three", "4": "four x"].sorted { $0.key < $1.key }.map { BoardCard(id: $0.key, title: $0.value) }),
            BoardColumn(id: "b", title: "B", cards: [BoardCard(id: "5", title: "five x"), BoardCard(id: "6", title: "sixty"), BoardCard(id: "7", title: "seven x")]),
        ]
        let shown: (BoardCard) -> Bool = { $0.title.hasSuffix("x") }
        // Shown in b: 5, 7. Dropping card 2 at index 1 (between 5 and 7) goes right before 7, after the hidden 6.
        try check(Board.apply(BoardMove(card: "2", from: "a", to: "b", index: 1), to: &columns, isShown: shown))
        try checkEqual(columns[1].cards.map(\.id), ["5", "6", "2", "7"])
        try checkEqual(columns[0].cards.map(\.id), ["1", "3", "4"])
        try check(Board.apply(BoardMove(card: "1", to: "b", index: 99), to: &columns, isShown: shown))
        try checkEqual(columns[1].cards.last?.id, "1")
        try check(Board.apply(BoardMove(card: "4", to: "a", index: 0), to: &columns))
        try checkEqual(columns[0].cards.map(\.id), ["4", "3"])
        try check(Board.apply(BoardMove(card: "3", to: "a", index: -1), to: &columns))   // a malformed index: last, not a crash
        try checkEqual(columns[0].cards.map(\.id), ["4", "3"])
        try check(!Board.apply(BoardMove(card: "nope", to: "a", index: 0), to: &columns))
        try check(!Board.apply(BoardMove(card: "3", to: "nope", index: 0), to: &columns))
    }

    await test("board: search and filter hide cards and the count says so") {
        var board = makeBoard()
        board.search = "ship"
        let json = board.block.json
        let todo = json.value(at: "children.1.children.0.children.0")!
        try checkEqual(todo["id"], "board.col.todo")
        try checkEqual(todo.value(at: "children.0.children.0.text"), "1 of 2")
        try checkEqual(todo.value(at: "children.1.children")?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["c2"])
        board.search = ""
        board.filter = "docs"
        try check(board.shows(BoardCard(id: "x", title: "x", tags: [BoardTag("docs")])))
        try check(!board.shows(BoardCard(id: "x", title: "x")))
    }

    await test("list with detail: the chosen item is sent as the list's `selected` while it is shown") {
        var layout = makeListDetail()
        try checkEqual(layout.block.json.value(at: "children.0.children.1.selected"), ["a"])
        layout.search = "be"   // "a" is hidden
        try checkEqual(layout.block.json.value(at: "children.0.children.1.selected"), nil)
        layout.search = ""
        layout.selected = nil
        try checkEqual(layout.block.json.value(at: "children.0.children.1.selected"), nil)
    }

    await test("list with detail: events reach the typed callbacks") {
        let view = freshView()
        let calls = Calls()
        makeListDetail().route(on: view, ListDetailHandlers(
            onSelect: { calls.log.append("select \($0 ?? "none")") }, onOpen: { calls.log.append("open \($0)") },
            onSearch: { calls.log.append("search \($0)") }, onDetailAction: { calls.log.append("action \($0)") }))
        try await fire(view, ["action": "listDetail.select", "block": "listDetail.list", "selected": ["b"]])
        try await fire(view, ["action": "listDetail.select", "block": "listDetail.list", "selected": []])
        try await fire(view, ["action": "listDetail.open", "block": "a"])
        try await fire(view, ["action": "listDetail.search", "value": "be"])
        try await fire(view, ["action": "listDetail.action", "block": "listDetail.action.open"])
        try checkEqual(calls.log, ["select b", "select none", "open a", "search be", "action open"])
    }

    await test("table: sorting, selection, toolbar, search, open, delete") {
        let view = freshView()
        let calls = Calls()
        var drawn = makeTable()
        drawn.selected = []
        try view.update(ViewDescription(root: drawn.block))
        makeTable().route(on: view, TableHandlers(
            onSort: { calls.log.append("sort \($0) \($1)") }, onSelect: { calls.log.append("select \($0.joined(separator: ","))") },
            onToolbar: { calls.log.append("tool \($0) \($1.joined(separator: ","))") }, onSearch: { calls.log.append("search \($0)") },
            onOpen: { calls.log.append("open \($0)") }, onDelete: { calls.log.append("delete \($0)") }))
        try await fire(view, ["action": "table.sort", "block": "table.table", "column": "size", "ascending": true])
        try await fire(view, ["action": "table.select", "block": "table.table", "selected": ["r1", "r3"]])
        try await fire(view, ["action": "table.tool", "block": "table.tool.delete"])
        try await fire(view, ["action": "table.search", "value": "a"])
        try await fire(view, ["action": "table.open", "block": "r1"])
        try await fire(view, ["action": "table.delete", "block": "r3"])
        try checkEqual(calls.log, ["sort size true", "select r1,r3", "tool delete r1,r3", "search a", "open r1", "delete r3"])
    }

    await test("table: only shown rows count as selected, and they are sent as the table's `selected`") {
        func table(_ selected: [String], search: String = "") -> JSONValue {
            var table = makeTable()
            table.selected = selected
            table.search = search
            return table.block.json
        }
        func bar(_ json: JSONValue, _ id: String) -> JSONValue? { json.value(at: "children.0.children")?.arrayValue?.first { $0["id"]?.stringValue == id } }
        try checkEqual(table(["r1", "r2"]).value(at: "children.1.selected"), ["r1", "r2"])
        let searched = table(["r1", "r2"], search: "a")   // only r1 ("a") is shown
        try checkEqual(searched.value(at: "children.1.children")?.arrayValue?.map { $0["id"] }, ["r1"])
        try checkEqual(searched.value(at: "children.1.selected"), ["r1"])
        try checkEqual(bar(searched, "table.count")?["text"], "1 selected")
        let hidden = table(["r2"], search: "a")
        try checkEqual(hidden.value(at: "children.1.selected"), nil)
        try checkEqual(bar(hidden, "table.count"), nil)
        try checkEqual(bar(hidden, "table.tool.delete")?["enabled"], false)
    }

    await test("table: onToolbar reports only rows still described, and a reopened view starts from the described selection") {
        let view = freshView()
        let calls = Calls()
        @MainActor func draw(_ selected: [String], search: String = "") throws {
            var table = makeTable()
            table.selected = selected
            table.search = search
            try view.show(ViewDescription(root: table.block))
        }
        @MainActor func reopen() async throws {
            try await view.receive("view/closed", ["view": "v"])
            try await view.receive("view/opened", ["view": "v"])
        }
        makeTable().route(on: view, TableHandlers(onToolbar: { calls.log.append("tool \($0) [\($1.joined(separator: ","))]") }))
        try await view.receive("view/opened", ["view": "v"])
        try draw([])
        try await fire(view, ["action": "table.select", "block": "table.table", "selected": ["r1", "r2"]])
        try draw(["r1", "r2"], search: "a")   // r2 is hidden: Vektor unselects it, silently
        try await fire(view, ["action": "table.tool", "block": "table.tool.delete"])
        try await reopen()
        try draw([])                          // Vektor starts with nothing selected
        try await fire(view, ["action": "table.tool", "block": "table.tool.add"])
        try await reopen()
        try draw(["r3"])                      // …or with the described `selected`
        try await fire(view, ["action": "table.tool", "block": "table.tool.add"])
        try checkEqual(calls.log, ["tool delete [r1]", "tool add []", "tool add [r3]"])
    }

    await test("table: TableRow.sorted orders numbers as numbers and text naturally") {
        let columns = [Column(id: "n", title: "N"), Column(id: "s", title: "S")]
        let rows = [TableRow(id: "a", cells: ["file10", 10]), TableRow(id: "b", cells: ["file2", 9]), TableRow(id: "c", cells: ["file1", 100])]
        try checkEqual(TableRow.sorted(rows, columns: columns, by: ("s", true)).map(\.id), ["b", "a", "c"])
        try checkEqual(TableRow.sorted(rows, columns: columns, by: ("n", true)).map(\.id), ["c", "b", "a"])
        try checkEqual(TableRow.sorted(rows, columns: columns, by: ("n", false)).map(\.id), ["a", "b", "c"])
        try checkEqual(TableRow.sorted(rows, columns: columns, by: nil).map(\.id), ["a", "b", "c"])
    }

    await test("table: a toolbar button that needs a selection is disabled without one") {
        var table = makeTable()
        table.selected = []
        let buttons = table.block.json.value(at: "children.0.children")!.arrayValue!.filter { $0["type"]?.stringValue == "button" }
        try checkEqual(buttons.map { $0["enabled"] }, [JSONValue.bool(false), nil])
    }

    await test("settings form: changes and buttons reach the callbacks with the field key") {
        let view = freshView()
        let calls = Calls()
        makeForm().route(on: view, SettingsFormHandlers(
            onChange: { calls.log.append("change \($0) \($1.jsonText)") }, onButton: { calls.log.append("button \($0)") }))
        try await fire(view, ["action": "settings.change", "block": "settings.field.name", "value": "Z"])
        try await fire(view, ["action": "settings.change", "block": "settings.field.sync", "value": false])
        try await fire(view, ["action": "settings.change", "block": "settings.field.tags", "value": ["a", "b"]])
        try await fire(view, ["action": "settings.press", "block": "settings.field.reset"])
        try checkEqual(calls.log, ["change name \"Z\"", "change sync false", "change tags [\"a\",\"b\"]", "button reset"])
    }

    await test("settings form: text typed against an older revision is still delivered") {
        let view = freshView()
        let calls = Calls()
        try view.update(ViewDescription(root: makeForm().block))
        try view.update(ViewDescription(root: makeForm().block))
        makeForm().route(on: view, SettingsFormHandlers(onChange: { key, _ in calls.log.append(key) }))
        try await fire(view, ["action": "settings.change", "block": "settings.field.name", "value": "Za", "revision": 1])
        try checkEqual(calls.log, ["name"])
    }

    await test("card list: the cards are the items of a list (only a collection's items get Return and a double-click), spaced, nothing selected") {
        let block = try makeCards().block.json
        try checkEqual(block["type"], "list")
        try checkEqual(block["id"], "cards")
        try checkEqual(block["selection"], "none")
        try checkEqual(block["spacing"], 8)
        try checkEqual(block["children"]?.arrayValue?.map { [$0["type"], $0["id"], $0["action"]] }, [["card", "k1", "cards.open"], ["card", "k2", nil]])
    }

    await test("card list: a button key with a dot (or none) is refused while drawing, since the card id may have dots") {
        for key in ["open.url", ""] {
            let cards = CardList(cards: [CardItem(id: "k1", title: "T", buttons: [CardButton(key: key, symbol: "safari")])])
            try checkThrows({ _ = try cards.block }, matching: "The button key “\(key)” of the card “k1” must be a word without dots.")
        }
    }

    await test("card list: open, buttons (card ids may contain dots) and menus") {
        let view = freshView()
        let calls = Calls()
        makeCards().route(on: view, menuKeys: ["rename", "delete"], CardListHandlers(
            onOpen: { calls.log.append("open \($0)") }, onButton: { calls.log.append("button \($0) \($1)") }, onMenu: { calls.log.append("menu \($0) \($1)") }))
        try await fire(view, ["action": "cards.open", "block": "k1"])
        try await fire(view, ["action": "cards.button", "block": "cards.button.stop.k1"])
        try await fire(view, ["action": "cards.button", "block": "cards.button.copy.my.card.1"])
        try await fire(view, ["action": "cards.menu.delete", "block": "k1"])
        try await fire(view, ["action": "cards.menu.rename", "block": "cards.more.k2"])
        try checkEqual(calls.log, ["open k1", "button k1 stop", "button my.card.1 copy", "menu k1 delete", "menu k2 rename"])
    }

    await test("layouts: events of another layout, or with no block, are ignored") {
        let view = freshView()
        let calls = Calls()
        makeBoard().route(on: view, BoardHandlers(
            onAdd: { _ in calls.log.append("add") }, onOpen: { _ in calls.log.append("open") }, onMove: { _ in calls.log.append("move") },
            onColumnAction: { _, _ in calls.log.append("column") }))
        try await fire(view, ["action": "board.add", "block": "other.add.todo"])
        try await fire(view, ["action": "board.open"])
        try await fire(view, ["action": "board.move", "item": "c1", "target": "elsewhere", "index": 0])
        try await fire(view, ["action": "board.column.rename", "block": "x"])
        try checkEqual(calls.log, [])
    }
}
