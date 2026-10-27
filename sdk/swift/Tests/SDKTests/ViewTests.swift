import Foundation
import VektorPlugin

private func board(_ columns: [(String, [(String, String)])]) -> JSONValue {
    Block.hstack(columns.map { id, cards in
        Block.panel([Block.list(id, cards.map { Block.card([], id: $0.0, title: $0.1) }, group: "cards", move: "move")], id: "col-\(id)", title: id)
    }, id: "board").json
}

@MainActor
final class Recorder: NotificationSink {
    var sent: [(method: String, params: JSONValue)] = []
    func notify(_ method: String, _ params: JSONValue) { sent.append((method, params)) }
}

@MainActor
func viewTests() async {
    await test("patch: the reference example applies in order") {
        let before = board([("todo", [("c1", "One"), ("c2", "Two"), ("c3", "Three")]), ("done", [])])
        // docs/reference.md, "Patches", verbatim.
        let ops: [PatchOperation] = [
            .move(id: "c1", parent: "done", index: 0),
            .insert(parent: "todo", index: 0, block: ["type": "card", "id": "c9", "title": "New"]),
            .replace(id: "c2", block: ["type": "card", "id": "c2", "title": "Renamed"]),
            .remove(id: "c3"),
        ]
        try checkEqual(JSONValue.array(ops.map(\.json)), try JSONValue.parse(#"""
            [{"op": "move", "id": "c1", "parent": "done", "index": 0},
             {"op": "insert", "parent": "todo", "index": 0, "block": {"type": "card", "id": "c9", "title": "New"}},
             {"op": "replace", "id": "c2", "block": {"type": "card", "id": "c2", "title": "Renamed"}},
             {"op": "remove", "id": "c3"}]
            """#))
        let after = try applyPatch(before, ops)
        let todo = after.value(at: "children.0.children.0.children")!.arrayValue!
        try checkEqual(todo, [["type": "card", "id": "c9", "title": "New"], ["type": "card", "id": "c2", "title": "Renamed"]])
        try checkEqual(after.value(at: "children.1.children.0.children.0.id"), "c1")
    }

    await test("patch: all or nothing, naming the operation that cannot apply") {
        let before = board([("todo", [("c1", "One")])])
        try checkThrows({ _ = try applyPatch(before, [.remove(id: "c1"), .remove(id: "nope")]) }, matching: "operation 2 removes “nope”")
        try checkThrows({ _ = try applyPatch(before, [.insert(parent: "todo", index: 5, block: Block.card([], id: "x").json)]) }, matching: "inserts at 5")
        try checkThrows({ _ = try applyPatch(before, [.insert(parent: "todo", index: nil, block: Block.card([], id: "c1").json)]) }, matching: "listed twice")
        try checkThrows({ _ = try applyPatch(before, [.insert(parent: "todo", index: nil, block: Block.card([]).json)]) }, matching: "needs an “id”")
        try checkThrows({ _ = try applyPatch(before, [.move(id: "col-todo", parent: "todo", index: nil)]) }, matching: "into itself")
        try checkThrows({ _ = try applyPatch(before, [.remove(id: "board")]) }, matching: "or is its root")
    }

    func diffCheck(_ before: JSONValue, _ after: JSONValue) throws -> [PatchOperation] {
        guard let ops = diffBlocks(before, after) else { throw Failure(description: "a patch was expected") }
        try checkEqual(try applyPatch(before, ops), after)
        return ops
    }

    await test("diff: a card moved to another column is one move") {
        let ops = try diffCheck(board([("todo", [("c1", "One"), ("c2", "Two")]), ("done", [("c3", "Three")])]),
                                board([("todo", [("c2", "Two")]), ("done", [("c1", "One"), ("c3", "Three")])]))
        try checkEqual(ops, [.move(id: "c1", parent: "done", index: 0)])
    }

    await test("diff: insert, remove, rename; a reorder is one move") {
        let ops = try diffCheck(board([("todo", [("c1", "One"), ("c2", "Two"), ("c3", "Three")])]),
                                board([("todo", [("c1", "One!"), ("c3", "Three"), ("c4", "Four")])]))
        try checkEqual(Set(ops.map { "\($0.json["op"]!.stringValue!)" }), ["insert", "remove", "replace"])
        let reorder = try diffCheck(board([("todo", [("a", "A"), ("b", "B"), ("c", "C"), ("d", "D")])]),
                                    board([("todo", [("d", "D"), ("a", "A"), ("b", "B"), ("c", "C")])]))
        try checkEqual(reorder, [.move(id: "d", parent: "todo", index: 0)])
    }

    await test("diff: none for no change; nil when only the whole description can say it") {
        let tree = board([("todo", [("a", "A")])])
        try checkEqual(diffBlocks(tree, tree), [])
        try check(diffBlocks(Block.vstack([.text("a")]).json, Block.vstack([.text("b")]).json) == nil)
        let before = Block.vstack([.textField("f", action: "add"), .list("l", [])]).json
        let after = Block.vstack([.textField("f", action: "add"), .list("l", [.row("r1", title: "One")])]).json
        try checkEqual(try diffCheck(before, after), [.insert(parent: "l", index: 0, block: ["type": "row", "id": "r1", "title": "One"])])
    }

    await test("diff: a reorder under a block without an id (a scroll) is one move, at the root, nested and in a list root") {
        func cards(_ order: [String]) -> [Block] { order.map { Block.card([], id: $0, title: $0.uppercased()) } }
        func atRoot(_ order: [String]) -> JSONValue { Block.vstack([.scroll([.list("l", cards(order))])], id: "root").json }
        try checkEqual(try diffCheck(atRoot(["a", "b"]), atRoot(["b", "a"])), [.move(id: "a", parent: "l", index: 1)])
        func nested(_ order: [String]) -> JSONValue {
            Block.vstack([.vstack([.vstack([.scroll([.list("l", cards(order))])])], id: "mid")], id: "root").json
        }
        try checkEqual(try diffCheck(nested(["a", "b", "c"]), nested(["c", "a", "b"])), [.move(id: "c", parent: "l", index: 0)])
        func listRoot(_ order: [String]) -> JSONValue { .array([Block.scroll([.list("l", cards(order))]).json]) }
        try checkEqual(try diffCheck(listRoot(["a", "b"]), listRoot(["b", "a"])), [.move(id: "a", parent: "l", index: 1)])
    }

    await test("diff: a block without an id that changes itself replaces the nearest block with an id; at the root, none") {
        func mid(_ axis: Block.ScrollAxis) -> Block { .vstack([.scroll([.list("l", [.card([], id: "a")])], axis: axis)], id: "mid") }
        func tree(_ axis: Block.ScrollAxis) -> JSONValue { Block.vstack([mid(axis)], id: "root").json }
        try checkEqual(try diffCheck(tree(.vertical), tree(.horizontal)), [.replace(id: "mid", block: mid(.horizontal).json)])
        func bare(_ axis: Block.ScrollAxis) -> JSONValue { Block.vstack([.scroll([.list("l", [.card([], id: "a")])], axis: axis)], id: "root").json }
        try check(diffBlocks(bare(.vertical), bare(.horizontal)) == nil)
    }

    await test("diff: a 3,000-card board, one card moved, is one move") {
        func cards(_ prefix: String) -> [(String, String)] { (0..<1000).map { ("\(prefix)\($0)", "Card \(prefix)\($0)") } }
        var a = cards("a")
        let moved = a.remove(at: 500)
        var c = cards("c")
        c.insert(moved, at: 10)
        let ops = try diffCheck(board([("a", cards("a")), ("b", cards("b")), ("c", cards("c"))]), board([("a", a), ("b", cards("b")), ("c", c)]))
        try checkEqual(ops, [.move(id: "a500", parent: "c", index: 10)])
    }

    // A board the way a plugin draws one: a bar, then columns whose head holds a count, then a list of cards that each hold
    // a few blocks of their own (about ten blocks a card).
    func bigBoard(_ columns: [(String, [String])], done: Set<String> = [], title: [String: String] = [:]) -> JSONValue {
        Block.vstack([
            .hstack([.text("Board"), .searchField("search", action: "search")], id: "bar"),
            .scroll([.hstack(columns.map { column, cards in
                .panel([
                    .hstack([.text(column), .count(cards.count, id: "count-\(column)")], id: "head-\(column)"),
                    .list("list-\(column)", cards.map { id in
                        Block.card([
                            .hstack([.text(title[id] ?? "Task \(id)"), .badge("tag", role: .label1), .badge("x", role: .label2)]),
                            .markdown("Some *text* for \(id)"),
                            .hstack([.symbol("bubble.left"), .count(3, id: "\(id).n")], id: "\(id).foot"),
                        ], id: id, title: title[id] ?? "Task \(id)", check: "done", checked: done.contains(id))
                    }, group: "cards", move: "move"),
                ], id: "col-\(column)")
            }, id: "columns")], axis: .horizontal),
        ], id: "screen").json
    }

    await test("diff: time grows with the tree, not its square (3,000 cards, ~30,000 blocks): a drag, a done circle, a rename") {
        let names = ["a", "b", "c"]
        let columns = names.map { name in (name, (0..<1000).map { "\(name)\($0)" }) }
        let before = bigBoard(columns)
        var moved = columns
        let card = moved[0].1.remove(at: 500)
        moved[2].1.insert(card, at: 0)
        var blocks = 0
        func count(_ value: JSONValue) { blocks += 1; for child in value["children"]?.arrayValue ?? [] { count(child) } }
        count(before)
        try check(blocks > 25_000, "\(blocks) blocks")
        let started = Date()
        let drag = try diffCheck(before, bigBoard(moved))
        let done = try diffCheck(before, bigBoard(columns, done: ["b10"]))
        let rename = try diffCheck(before, bigBoard(columns, title: ["c999": "Renamed"]))
        let seconds = Date().timeIntervalSince(started)
        try checkEqual(drag.count, 3, "a move and the two counts: \(drag.map(\.json))")
        try checkEqual(drag.first, .move(id: "a500", parent: "list-c", index: 0))
        try checkEqual(Set(drag.dropFirst().map { $0.json["id"]?.stringValue ?? "" }), ["count-a", "count-c"])
        try checkEqual(done.map { $0.json["op"]?.stringValue }, ["replace"])
        try checkEqual(done.first?.json["id"], "b10")
        try checkEqual(rename.map { $0.json["id"]?.stringValue }, ["c999"])
        // Quadratic (every id looked up from the root), the same three took minutes in a debug build.
        try check(seconds < 20, "three diffs of a 3,000-card board took \(seconds) s")
    }

    await test("patch: thousands of operations apply in time linear in the tree (no walk per operation)") {
        let before = bigBoard([("a", (0..<1000).map { "a\($0)" }), ("b", [])])
        var ops: [PatchOperation] = []
        for n in 0..<1000 { ops.append(.move(id: "a\(n)", parent: "list-b", index: n)) }
        for n in 0..<1000 { ops.append(.insert(parent: "list-a", index: n, block: Block.card([], id: "new\(n)").json)) }
        let started = Date()
        let after = try applyPatch(before, ops)
        try check(Date().timeIntervalSince(started) < 20, "\(Date().timeIntervalSince(started)) s")
        let listB = "children.1.children.0.children.1.children.1.children"
        let listA = "children.1.children.0.children.0.children.1.children"
        try checkEqual(after.value(at: "\(listB).999.id"), "a999")
        try checkEqual(after.value(at: "\(listA).0.id"), "new0")
        // An id a patch takes away is free again; one still in the tree is not.
        try checkThrows({ _ = try applyPatch(before, [.insert(parent: "list-b", index: 0, block: Block.card([], id: "a1").json)]) }, matching: "listed twice")
        let reused = try applyPatch(before, [.remove(id: "a1"), .insert(parent: "list-b", index: 0, block: Block.card([], id: "a1").json)])
        try checkEqual(reused.value(at: "\(listB).0.id"), "a1")
        // A replace may keep the ids of what it replaces, and they can be found after it.
        let replaced = try applyPatch(before, [.replace(id: "a2", block: Block.card([.count(1, id: "a2.n")], id: "a2").json), .remove(id: "a2.n")])
        try checkEqual(replaced.value(at: "\(listA).2.children"), .array([]))
    }

    await test("diff: a tree that lists an id twice is still compared (by walking, the first found), or left to the whole description") {
        let twice = Block.vstack([.list("l", [.card([], id: "a"), .card([], id: "b")]), .list("m", [.card([], id: "a")])], id: "root").json
        let changed = Block.vstack([.list("l", [.card([], id: "b"), .card([], id: "a")]), .list("m", [.card([], id: "a")])], id: "root").json
        if let ops = diffBlocks(twice, changed) { try checkEqual(try applyPatch(twice, ops), changed) }
    }

    await test("diff: random changes in a deeper tree (heads, counts, nested blocks, columns gained and lost) rebuild it exactly") {
        var seed: UInt64 = 11
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var patched = 0
        for round in 0..<300 {
            let names = ["x", "y", "z", "w"].filter { _ in random(5) != 0 }
            let columns = names.map { name in (name, (0..<random(7)).map { "\(name)\($0)" }) }
            var pool = columns.flatMap(\.1).filter { _ in random(5) != 0 }
            if random(2) == 0 { pool.append("new\(round)") }
            let nextNames = random(3) == 0 ? ["x", "y", "z", "w"].filter { _ in random(5) != 0 } : names
            var next = nextNames.map { ($0, [String]()) }
            if !next.isEmpty { for card in pool { next[random(next.count)].1.append(card) } }
            let done = Set(pool.filter { _ in random(4) == 0 })
            let title = Dictionary(uniqueKeysWithValues: pool.filter { _ in random(5) == 0 }.map { ($0, "T\($0)") })
            let before = bigBoard(columns)
            let after = bigBoard(next, done: done, title: title)
            if let ops = diffBlocks(before, after) {
                try checkEqual(try applyPatch(before, ops), after, "round \(round)")
                patched += 1
            } else {
                // Only when the columns changed (a new column that receives cards cannot be inserted while they are elsewhere).
                try check(names != nextNames, "round \(round): no patch")
            }
        }
        try check(patched > 200, "\(patched) of 300 rounds patched")
    }

    await test("diff: random changes always give a patch that rebuilds the new tree exactly") {
        var seed: UInt64 = 7
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for round in 0..<300 {
            let columns = ["x", "y", "z"].map { id in (id, (0..<random(6)).map { ("\(id)\($0)", "T\(random(3))") }) }
            let all = columns.flatMap(\.1)
            var shuffled = all.filter { _ in random(4) != 0 }.map { ($0.0, random(4) == 0 ? $0.1 + "!" : $0.1) }
            if random(2) == 0 { shuffled.append(("new\(round)", "New")) }
            var next: [(String, [(String, String)])] = [("x", []), ("y", []), ("z", [])]
            for card in shuffled { next[random(3)].1.append(card) }
            let before = board(columns)
            let after = board(next)
            guard let ops = diffBlocks(before, after) else { throw Failure(description: "round \(round): no patch") }
            try checkEqual(try applyPatch(before, ops), after, "round \(round)")
        }
    }

    await test("ViewState: whole description first, then patches, revisions counting up") {
        let sink = Recorder()
        let view = ViewState(view: "board", sink: sink)
        func describe(_ columns: [(String, [(String, String)])], title: String = "Board") throws -> ViewDescription {
            ViewDescription(header: Header(title: title), root: try Block(json: board(columns)))
        }
        try checkEqual("\(try view.show(try describe([("todo", [("c1", "One")]), ("done", [])])))", "update")
        try checkEqual("\(try view.show(try describe([("todo", []), ("done", [("c1", "One")])])))", "patch")
        try checkEqual("\(try view.show(try describe([("todo", []), ("done", [("c1", "One")])])))", "unchanged")
        try checkEqual("\(try view.show(try describe([("todo", []), ("done", [("c1", "One")])], title: "Board 2")))", "update")
        try checkEqual(sink.sent.map(\.method), ["view/update", "view/patch", "view/update"])
        try checkEqual(sink.sent[0].params.value(at: "description.revision"), 1)
        try checkEqual(sink.sent[1].params, ["view": "board", "revision": 2, "ops": [["op": "move", "id": "c1", "parent": "done", "index": 0]]])
        try checkEqual(view.revision, 3)
    }

    await test("ViewState: reopened → whole again; patches off; a refused tree throws before sending") {
        let sink = Recorder()
        let view = ViewState(view: "v", sink: sink)
        try view.show(ViewDescription(root: .list("l", [])))
        try await view.receive(Method.viewOpened, ["view": "v"])
        try view.show(ViewDescription(root: .list("l", [.row("r", title: "x")])))
        view.patches = false
        try view.show(ViewDescription(root: .list("l", [.row("r", title: "x"), .row("s", title: "y")])))
        try checkEqual(sink.sent.map(\.method), ["view/update", "view/update", "view/update"])
        try checkThrows({ try view.show(ViewDescription(root: Block(type: "list", fields: ["id": "l"], children: [Block(type: "row")]))) },
                        matching: "cannot be shown: every item of “l” needs an “id”")
        try checkEqual(sink.sent.count, 3)
    }

    await test("ViewState: patch() applies to the kept description and refuses one that cannot apply") {
        let sink = Recorder()
        let view = ViewState(view: "v", sink: sink)
        try checkThrows({ try view.patch([.remove(id: "x")]) }, matching: "send the whole description first")
        try view.update(ViewDescription(root: .list("l", [.row("a", title: "A")])))
        try view.patch([.insert(parent: "l", index: nil, block: Block.row("b", title: "B").json)])
        try checkEqual(view.description?.blocks?.first?.children?.compactMap(\.id), ["a", "b"])
        try checkThrows({ try view.patch([.remove(id: "zzz")]) }, matching: "removes “zzz”")
    }

    await test("ViewState: events routed by action; stale moves ignored, stale text delivered and marked") {
        let sink = Recorder()
        let view = ViewState(view: "v", sink: sink)
        var seen: [String] = []
        view.on("add") { seen.append("add \($0.text ?? "") \($0.isStale)") }
        view.on("move") { seen.append("move \($0.item ?? "") \($0.isStale)") }
        view.on("strict", stale: .ignore) { _ in seen.append("strict") }
        view.onAnyEvent { seen.append("other \($0.action)") }
        try view.update(ViewDescription(root: .list("l", [])))
        try view.update(ViewDescription(root: .list("l", [])))
        try await view.receive(Method.viewEvent, ["view": "v", "action": "add", "value": "x", "revision": 1])
        try await view.receive(Method.viewEvent, ["view": "v", "action": "move", "item": "c1", "target": "l", "index": 0, "revision": 1])
        try await view.receive(Method.viewEvent, ["view": "v", "action": "move", "item": "c2", "target": "l", "index": 0, "revision": 2])
        try await view.receive(Method.viewEvent, ["view": "v", "action": "strict", "revision": 1])
        try await view.receive(Method.viewEvent, ["view": "v", "action": "unknown", "revision": 2])
        try checkEqual(seen, ["add x true", "move c2 false", "other unknown"])
    }

    await test("ViewState: a refused patch is answered with the whole description, numbered above anything sent; once") {
        let sink = Recorder()
        let view = ViewState(view: "board", sink: sink)
        var heard: [String] = []
        view.onRefused { heard.append("\($0.kind?.rawValue ?? "?") \($0.revision.map(String.init) ?? "nil") \($0.refusedRevision.map(String.init) ?? "nil") \($0.problem)") }
        func describe(_ columns: [(String, [(String, String)])]) throws -> ViewDescription { ViewDescription(root: try Block(json: board(columns))) }
        try view.show(try describe([("todo", [("c1", "One"), ("c2", "Two")]), ("done", [])]))         // 1: update
        try view.show(try describe([("todo", [("c2", "Two")]), ("done", [("c1", "One")])]))           // 2: patch
        try view.show(try describe([("todo", []), ("done", [("c1", "One"), ("c2", "Two")])]))         // 3: patch
        try checkEqual(sink.sent.map(\.method), ["view/update", "view/patch", "view/patch"])
        try await view.receive(Method.viewRefused, ViewRefusal(view: "board", kind: .patch, revision: 1, refusedRevision: 2, problem: "operation 1 moves “c1”, which the view does not have.").json)
        try checkEqual(heard, ["patch 1 2 operation 1 moves “c1”, which the view does not have."])
        try checkEqual(sink.sent.map(\.method), ["view/update", "view/patch", "view/patch", "view/update"])
        try checkEqual(sink.sent[3].params.value(at: "description.revision"), 4)
        try checkEqual(sink.sent[3].params.value(at: "description.blocks"), board([("todo", []), ("done", [("c1", "One"), ("c2", "Two")])]))
        // The patch sent after the refused one is refused too: the whole description already went out after it, so not again.
        try await view.receive(Method.viewRefused, ["view": "board", "kind": "patch", "revision": 1, "refusedRevision": 3, "problem": "x"])
        try checkEqual(sink.sent.count, 4)
        try checkEqual(view.refusal?.refusedRevision, 3)
    }

    await test("ViewState: after a refusal, events made against the revision Vektor still shows are not stale") {
        let sink = Recorder()
        let view = ViewState(view: "v", sink: sink)
        var seen: [String] = []
        view.on("move") { seen.append("\($0.item ?? "") stale=\($0.isStale)") }
        view.resendsAfterRefusal = false
        try view.update(ViewDescription(root: .list("l", [.row("a", title: "A"), .row("b", title: "B")])))   // 1
        try view.show(ViewDescription(root: .list("l", [.row("b", title: "B"), .row("a", title: "A")])))     // 2: refused below
        try await view.receive(Method.viewRefused, ["view": "v", "kind": "patch", "revision": 1, "refusedRevision": 2, "problem": "no"])
        try await view.receive(Method.viewEvent, ["view": "v", "action": "move", "item": "a", "target": "l", "index": 1, "revision": 1])
        try checkEqual(seen, ["a stale=false"])
        // The next show sends the whole description (Vektor kept what it showed), and events then carry its revision.
        try checkEqual("\(try view.show(ViewDescription(root: .list("l", [.row("b", title: "B"), .row("a", title: "A")]))))", "update")
        try await view.receive(Method.viewEvent, ["view": "v", "action": "move", "item": "b", "target": "l", "index": 1, "revision": 3])
        try checkEqual(view.refusal == nil, true)
        try await view.receive(Method.viewEvent, ["view": "v", "action": "move", "item": "c", "target": "l", "index": 0, "revision": 1])
        try checkEqual(seen, ["a stale=false", "b stale=false"])
    }

    await test("ViewState: a refused whole description is not sent again; the handler decides; unknown kinds are read") {
        let sink = Recorder()
        let view = ViewState(view: "v", sink: sink)
        var refusals: [ViewRefusal] = []
        view.onRefused { refusals.append($0) }
        try view.update(ViewDescription(root: .list("l", [])))
        try await view.receive(Method.viewRefused, ["view": "v", "kind": "description", "revision": .null, "refusedRevision": 1, "problem": "too deep"])
        try checkEqual(sink.sent.count, 1)
        try checkEqual(refusals.first?.revision, nil)
        try checkEqual(refusals.first?.kind, .description)
        try await view.receive(Method.viewRefused, ["view": "v", "kind": "somethingNew", "revision": 1, "problem": "?"])
        try checkEqual(refusals.last?.kind, nil)
        try checkEqual(sink.sent.count, 1)
        try checkEqual(ViewRefusal(view: "v", kind: .patch, revision: nil, problem: "p").json, ["view": "v", "kind": "patch", "revision": .null, "problem": "p"])
    }
}
