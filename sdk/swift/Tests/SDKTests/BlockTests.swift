import Foundation
import VektorPlugin

/// Every builder, keyed by the names in sdk/fixtures/blocks.json (the expectations the Node SDK's tests check too).
@MainActor
let builderCases: [String: Block] = [
    "vstack": .vstack([], spacing: 4),
    "hstack": .hstack([.spacer()], spacing: 8),
    "spacer": .spacer(),
    "divider": .divider(),
    "grid": .grid([], columns: 3, minWidth: 120, spacing: 6),
    "scroll": .scroll([], axis: .both),
    "split": .split("s", .text("a"), .text("b"), axis: .horizontal, fraction: 0.3, height: 300),
    "section": .section("sec", [], title: "Open", collapsible: true, collapsed: false, count: 3),
    "tabs/tab": .tabs("t", [.tab("one", title: "One", [], symbol: "star")], segmented: true, action: "tab"),
    "card": .card([], title: "T", symbol: "doc", role: .accent, badge: Badge("new", role: .positive)),
    "panel": .panel([], title: "P", role: .label2),
    "list": .list("l", [], selection: .multiple, select: "sel", group: "g", move: "mv", placeholder: "None", spacing: 6),
    "row": .row("r", title: "T", subtitle: "S", symbol: "doc", badge: Badge("b"), buttons: [Control(title: "Go", action: "go", symbol: "play", enabled: true)],
                check: "chk", checked: true, dimmed: true)
        .menu([.item(title: "Del", action: "del", destructive: true), .separator]),
    "table": .table("tb", columns: [Column(id: "name", title: "Name", width: 200, sortable: true)], rows: [.row("r1", cells: ["a", 1])],
                    sorted: (column: "name", ascending: false), sort: "sort"),
    "tree/node": .tree("tr", [.node("n1", title: "Root", [.node("n2", title: "Leaf")], symbol: "folder", expanded: true)]),
    "text": .text("Hi", style: .mono, selectable: true, link: "https://example.com", role: .neutral, lineLimit: 2),
    "symbol": .symbol("star", role: .warning, label: "Starred"),
    "badge": .badge("docs", role: .label3, label: "Tag docs"),
    "count": .count(12, role: .accent),
    "markdown": .markdown("# Hi"),
    "empty": .empty("Nothing", title: "Empty", symbol: "tray", role: .neutral, link: "https://example.com"),
    "banner": .banner("Note", role: .warning),
    "status": .status("Synced", symbol: "checkmark", role: .positive),
    "diff": .diff(left: "a", right: "b", leftTitle: "Mine", rightTitle: "Theirs", keepLeft: "keepMine", keepRight: "keepTheirs"),
    "button": .button(id: "sync", title: "Sync", symbol: "arrow.triangle.2.circlepath", action: "sync", style: .icon, tooltip: "Sync now", busy: true, enabled: false),
    "textField": .textField("f", action: "set", value: "x", placeholder: "Type", title: "Name", error: "Too short"),
    "searchField": .searchField("q", action: "search", placeholder: "Filter"),
    "textArea": .textArea("notes", action: "save", value: "a\nb"),
    "toggle": .toggle("on", action: "flip", value: true, title: "On"),
    "checkbox": .checkbox("cb", action: "tick", value: false),
    "picker": .picker("p", action: "pick", options: [Option(value: "a", title: "A", symbol: "a.circle")], value: "a", segmented: true),
    "stepper": .stepper("st", action: "step", value: 2, min: 0, max: 10, step: 2),
    "menu": .menu([.item(title: "Rename", action: "rename", symbol: "pencil")], title: "More"),
    "datePicker": .datePicker("due", action: "due", value: "2026-10-23"),
    "tagPicker": .tagPicker("tags", action: "tags", tags: ["a"], suggestions: ["b"]),
    "rolePicker": .rolePicker("colour", action: "colour", value: .label1, roles: [.label1, .label4]),
    "spinner": .spinner(text: "Loading"),
    "progress": .progress(0.5, title: "Uploading"),
    "fileList": .fileList(["/tmp/a.txt", "/tmp/folder/"]),
    "web": .web("page", entry: "web/index.html", height: 300),
    "reference: board": .hstack([
        .panel([
            .list("todo", [
                .card([.badge("docs", id: "c1-tag", role: .label3)], id: "c1", title: "Write the spec", edit: "rename", delete: "remove"),
            ], group: "cards", move: "move"),
        ], id: "col-todo", title: "To do", role: .label6),
        .panel([.list("done", [], group: "cards", move: "move")], id: "col-done", title: "Done", role: .label4),
    ], id: "board"),
    // docs/reference.md, "Widths": a board whose columns fill the pane and scroll once they no longer fit.
    "reference: widths": .scroll([
        Block.panel([], id: "col-todo", title: "To do").grow().minWidth(240),
        Block.panel([], id: "col-done", title: "Done").grow().minWidth(240),
    ], axis: .horizontal, spacing: 12),
    "reference: web block": .vstack([
        .hstack([.button(id: "clear", title: "Clear", action: "clear")], id: "bar"),
        .web("canvas", entry: "web/canvas.html"),
    ], id: "root"),
]

@MainActor
func blockTests() async {
    await test("builders: every case of sdk/fixtures/blocks.json, exactly") {
        let fixtures = try JSONValue.parse(try Data(contentsOf: repository.appendingPathComponent("sdk/fixtures/blocks.json")))
        let names = Set(fixtures.objectValue!.keys)
        try checkEqual(Set(builderCases.keys), names, "a fixture without a Swift case, or the reverse")
        for name in names.sorted() { try checkEqual(builderCases[name]!.json, fixtures[name]!, name) }
    }

    await test("builders: every block type of the reference is covered") {
        var covered = Set<String>()
        func walk(_ block: Block) { covered.insert(block.type); block.children?.forEach(walk) }
        builderCases.values.forEach(walk)
        try checkEqual(covered, BlockLimits.types)
    }

    await test("builders: fields on any block") {
        let block = Block.card([], id: "c")
            .menu([.item(title: "Open", action: "open")]).tooltip("Tip").label("Spoken").drag("cards")
            .drop(action: "dropped", accepts: ["cards"]).fileDrop(action: "files", accepts: .files, extensions: ["md"])
            .revealOnHover().enabled(false).error("Wrong")
        let expected: JSONValue = [
            "type": "card", "id": "c", "children": [], "menu": [["title": "Open", "action": "open"]], "tooltip": "Tip", "label": "Spoken",
            "drag": "cards", "drop": ["action": "dropped", "accepts": ["cards"]], "fileDrop": ["action": "files", "accepts": "files", "extensions": ["md"]],
            "revealOnHover": true, "enabled": false, "error": "Wrong",
        ]
        try checkEqual(block.json, expected)
        try checkEqual(try Block(json: expected), block)
    }

    await test("widths: width, minWidth, maxWidth and grow on any block; out of 20…4000 a warning, never a refusal") {
        let block = Block.card([], id: "c").width(300).minWidth(220).maxWidth(4000).grow()
        try checkEqual(block.json, ["type": "card", "id": "c", "children": [], "width": 300, "minWidth": 220, "maxWidth": 4000, "grow": true])
        try checkEqual(Block.text("t").grow(false).json, ["type": "text", "text": "t", "grow": false])
        try check(validateBlocks(block).problems.isEmpty && validateBlocks(block).warnings.isEmpty)
        let edges = validateBlocks(Block.hstack([Block.panel([], id: "a").width(20), Block.panel([], id: "b").maxWidth(4000)]))
        try check(edges.problems.isEmpty && edges.warnings.isEmpty, "\(edges.warnings)")
        let bad = validateBlocks(Block.hstack([
            Block.panel([], id: "a").width(5), Block.panel([], id: "b").maxWidth(9000),
            Block.panel([], id: "c").with("minWidth", "wide"), Block.panel([], id: "d").with("grow", "yes"),
        ]))
        try checkEqual(bad.problems, [])
        try checkEqual(bad.warnings.count, 4)
        try check(bad.warnings[0].contains("“a”") && bad.warnings[0].contains("“width”") && bad.warnings[0].contains("20 to 4000"))
        try check(bad.warnings[1].contains("“b”") && bad.warnings[1].contains("“maxWidth”"))
        try check(bad.warnings[2].contains("“c”") && bad.warnings[2].contains("“minWidth”"))
        try check(bad.warnings[3].contains("“d”") && bad.warnings[3].contains("“grow”"))
        // A grid's minWidth is its tile minimum, in the same range.
        try check(validateBlocks(Block.grid([], id: "g", minWidth: 160)).warnings.isEmpty)
        try checkEqual(Block.scroll([], axis: .horizontal, spacing: 12).json, ["type": "scroll", "axis": "horizontal", "spacing": 12, "children": []])
    }

    await test("roles: the thirteen of the reference, each with a name") {
        try checkEqual(Role.allCases.map(\.rawValue), ["accent", "positive", "warning", "danger", "neutral", "label1", "label2", "label3", "label4", "label5", "label6", "label7", "label8"])
        try checkEqual(Role.allCases.dropFirst(5).map(\.title), ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"])
    }

    await test("validateBlocks refuses what Vektor refuses, in its words") {
        func problem(_ value: JSONValue) -> String { validateBlocks(value).problems.first ?? "" }
        try check(problem(["id": "x"]).contains("needs a “type”"))
        try check(problem(Block.vstack([.text("a", id: "x"), .text("b", id: "x")]).json).contains("“x” is listed twice"))
        try check(problem(["type": "list", "id": "l", "children": [["type": "row", "title": "no id"]]]).contains("every item of “l” needs an “id”"))
        try check(problem(["type": "textField", "action": "a"]).contains("a “textField” block needs an “id”"))
        try check(problem(Block.button(title: "Nothing").json).contains("needs an “action”"))
        try check(problem(["type": "picker", "id": "p", "action": "a"]).contains("needs “options”"))
        try check(problem(["type": "table", "id": "t"]).contains("needs “columns”"))
        try check(problem(["type": "web", "id": "w"]).contains("needs an “entry”"))
        try check(problem(Block.tabs("t", [.text("not a tab")]).json).contains("must be a “tab”"))
        // Vektor trims required strings: empty or blank is missing.
        try check(problem(Block.picker("p", action: "a", options: [Option(value: "", title: "All")]).json).contains("every option of “p” needs a “value” and a “title”"))
        try check(problem(Block.picker("p", action: "a", options: [Option(value: "x", title: "  ")]).json).contains("every option of “p” needs a “value” and a “title”"))
        try check(problem(Block.table("t", columns: [Column(id: "", title: "Name")], rows: []).json).contains("every column of “t” needs an “id” and a “title”"))
        try check(problem(Block.table("t", columns: [Column(id: "name", title: " ")], rows: []).json).contains("every column of “t” needs an “id” and a “title”"))
        try check(problem(Block.menu([.item(title: "", action: "a")]).json).contains("needs a “title” and an “action”"))
        try check(problem(Block.menu([.item(title: "Go", action: " ")]).json).contains("needs a “title” and an “action”"))
        try check(problem(Block.button(title: "Blank", action: "").json).contains("needs an “action”"))
        try check(problem(Block.web("w", entry: " ").json).contains("needs an “entry”"))
        try check(problem(["type": " "]).contains("needs a “type”"))
        try check(problem(Block.textField(" ", action: "a").json).contains("a “textField” block needs an “id”"))
        var deep = Block.text("leaf")
        for _ in 0..<70 { deep = .vstack([deep]) }
        try check(problem(deep.json).contains("nested more than 64 deep"))
        let ignored = validateBlocks(["type": "text", "text": "x", "color": "#ff0000", "role": "crimson"])
        try checkEqual(ignored.problems, [])
        try checkEqual(ignored.warnings.count, 2)
        try check(validateBlocks([Block.text("a"), Block.textField("f", action: "x")]).problems.isEmpty)
    }
}
