import BoardPlugin
import Foundation
import VektorPlugin
import VektorPluginTestKit

// Storage and sync, against the test kit's fake place over the real protocol. "Mac A" and "Mac B" are two controllers with
// their own data folders sharing one place, as two Macs sharing a folder on a server would.

private let work = Workspace(id: "w1", name: "Work")

/// A place with one synced board ("Roadmap": One, Two, Three in Backlog) that both Macs have.
@MainActor
private func pair(policy: MergePolicy = .record, wrapA: ((PlaceStore) -> PlaceStore)? = nil) async throws -> (World, BoardController, BoardController, String) {
    let world = try await World()
    let a = try world.mac("A", policy: policy, wrap: wrapA)
    let b = try world.mac("B", policy: policy)
    await a.activate(workspace: work, place: world.handle)
    await b.activate(workspace: work, place: world.handle)
    let board = try await a.createBoard(name: "Roadmap")
    let backlog = a.columnID("Backlog", in: board)!
    for title in ["One", "Two", "Three"] { _ = try await a.addTask(to: board, column: backlog, title: title) }
    try checkEqual(try await syncClean(a).sent, 2, "the board's file and the index")
    try checkEqual(try await syncClean(b).received, 2)
    try checkEqual(b.layout(board), a.layout(board))
    return (world, a, b, board)
}

/// Syncs and expects no error and no question.
@MainActor
@discardableResult
private func syncClean(_ mac: BoardController, line: Int = #line) async throws -> SyncReport {
    guard let report = await mac.sync() else { throw Failure(description: "line \(line): no sync (no place)") }
    if let error = mac.status.error { throw Failure(description: "line \(line): the sync failed: \(error)") }
    try check(report.conflicts.isEmpty, "line \(line): unexpected questions: \(report.conflicts.map(\.title))")
    return report
}

/// What the place holds for a board, read back as the plugin's own model.
@MainActor
private func placeBoard(_ world: World, _ board: String) throws -> BoardFile {
    try JSONDecoder().decode(BoardFile.self, from: try Data(contentsOf: world.placeFolder.appendingPathComponent("boards/\(board).json")))
}

@MainActor
func syncTests() async {
    await test("storage round-trip: what one Mac writes, another reads exactly; files are readable JSON with ids and updatedAt") {
        let world = try await World()
        let a = try world.mac("A")
        await a.activate(workspace: work, place: world.handle)
        try check(a.status.showsSyncButton, "a place on a connection has a Sync button")
        let board = try await a.createBoard(name: "Round trip")
        let column = a.columns(of: board)[0].column.id
        let task = try await a.addTask(to: board, column: column, title: "Task", description: "**Markdown**\n\n- a\n- b")
        try await a.setTaskTags(task, in: board, names: ["x", "y"])
        try await a.addComment(to: task, in: board, text: "a comment")
        // Saved on this Mac at once, marked unsynced; the place has nothing yet.
        try check(a.status.unsynced)
        try check(!world.placeHas("index.json"))
        try await syncClean(a)
        try check(!a.status.unsynced)
        try check(a.status.lastSynced != nil)
        let index = try world.placeJSON("index.json")
        try checkEqual(index["format"], "vektor-board-index")
        try checkEqual(index.value(at: "boards.0.name"), "Round trip")
        try check(index.value(at: "boards.0.updatedAt")?.stringValue != nil)

        let b = try world.mac("B")
        await b.activate(workspace: work, place: world.handle)
        try await syncClean(b)
        try checkEqual(b.file(board), a.file(board))
        try checkEqual(b.boards, a.boards)
        try checkEqual(try placeBoard(world, board), a.file(board)!)
    }

    await test("remote newer: the other Mac's change arrives; nothing is written back") {
        let (world, a, b, board) = try await pair()
        try await b.updateTask(b.taskID("Two", in: board)!, in: board, title: "Two (from B)")
        try await syncClean(b)
        let writesBefore = world.calls("storage/write")
        let report = try await syncClean(a)
        try checkEqual(report.received, 1)
        try checkEqual(world.calls("storage/write"), writesBefore, "A changed nothing, so A writes nothing")
        try checkEqual(a.layout(board), "Backlog: One, Two (from B), Three | In Progress:  | Review:  | Done: ")
    }

    await test("local newer: this Mac's change is saved at once, marked unsynced, and sent by Sync") {
        let (world, a, b, board) = try await pair()
        let three = a.taskID("Three", in: board)!
        try await a.moveTask(three, in: board, to: a.columnID("Done", in: board)!, at: 0)
        try await a.setDone(three, in: board, true)
        try check(a.status.unsynced)
        try checkEqual(try placeBoard(world, board).tasks.first { $0.id == three }?.done, false, "not on the place before Sync")
        try checkEqual(try await syncClean(a).sent, 1)
        try checkEqual(try placeBoard(world, board).tasks.first { $0.id == three }?.done, true)
        try await syncClean(b)
        try checkEqual(b.layout(board), "Backlog: One, Two | In Progress:  | Review:  | Done: Three")
    }

    await test("both changed different records: everything merges, no question, on both Macs") {
        let (world, a, b, board) = try await pair()
        let one = a.taskID("One", in: board)!
        let two = a.taskID("Two", in: board)!
        try await a.updateTask(one, in: board, title: "One (A)")
        try await a.moveTask(two, in: board, to: a.columnID("Review", in: board)!, at: 0)
        try await a.addTag(to: board, name: "from A")
        try await b.updateTask(b.taskID("Three", in: board)!, in: board, description: "B wrote this")
        try await b.addComment(to: one, in: board, text: "B comments on One")    // a comment is a record of its own
        _ = try await b.addTask(to: board, column: b.columnID("Done", in: board)!, title: "New from B")
        try await b.addColumn(to: board, title: "Blocked", role: .label1)
        try await syncClean(a)
        try await syncClean(b)
        try await syncClean(a)
        try checkEqual(a.file(board), b.file(board))
        try checkEqual(a.layout(board), "Backlog: One (A), Three | In Progress:  | Review: Two | Done: New from B | Blocked: ")
        try checkEqual(a.comments(of: one, in: board).map(\.text), ["B comments on One"])
        try checkEqual(a.tags(of: board).map(\.name), ["from A"])
        try checkEqual(a.task(a.taskID("Three", in: board)!, in: board)?.task.description, "B wrote this")
        try checkEqual(try placeBoard(world, board), a.file(board)!)
    }

    await test("both changed the same record: asked with both versions; nothing written until answered") {
        let (world, a, b, board) = try await pair()
        let two = a.taskID("Two", in: board)!
        try await a.updateTask(two, in: board, title: "Two by A")
        try await b.updateTask(two, in: board, title: "Two by B")
        try await syncClean(a)
        let placeBefore = try placeBoard(world, board)
        let report = await b.sync()!
        try checkEqual(report.conflicts.count, 1)
        let question = report.conflicts[0]
        try checkEqual(question.subject, .task)
        try checkEqual(question.reason, .bothChanged)
        try checkEqual(question.title, "Task “Two by B”")
        try check(question.mine?.hasPrefix("Two by B\nColumn: Backlog") == true, question.mine ?? "")
        try check(question.theirs?.hasPrefix("Two by A\nColumn: Backlog") == true, question.theirs ?? "")
        try checkEqual(question.choices, [.keepMine, .keepTheirs, .keepBoth])
        try checkEqual(b.status.conflicts, report.conflicts)
        try check(b.status.unsynced)
        try checkEqual(try placeBoard(world, board), placeBefore, "nothing written while the question is open")
        try checkEqual(b.task(two, in: board)?.task.title, "Two by B", "this Mac keeps its version meanwhile")
        // Another Sync without an answer asks again and still writes nothing.
        try checkEqual(await b.sync()!.conflicts.map(\.id), [question.id])
        try checkEqual(try placeBoard(world, board), placeBefore)
    }

    for choice in ConflictChoice.allCases {
        await test("both changed the same record: “\(choice.rawValue)” gives the expected result on both Macs") {
            let (world, a, b, board) = try await pair()
                let two = a.taskID("Two", in: board)!
            try await a.updateTask(two, in: board, title: "Two by A")
            try await a.addComment(to: two, in: board, text: "A's comment stays either way")
            try await b.updateTask(two, in: board, title: "Two by B", description: "B's notes")
            try await syncClean(a)
            let question = await b.sync()!.conflicts[0]
            try await b.resolveConflict(question.id, choice)   // the last answer applies them all with a sync
            try check(b.status.conflicts.isEmpty && b.status.error == nil, "\(b.status)")
            try check(!b.status.unsynced)
            try await syncClean(a)
            try checkEqual(a.file(board), b.file(board))
            try checkEqual(try placeBoard(world, board), b.file(board)!)
            let titles = b.columns(of: board)[0].tasks.map(\.task.title)
            switch choice {
            case .keepMine:
                try checkEqual(titles, ["One", "Two by B", "Three"])
                try checkEqual(b.task(two, in: board)?.task.description, "B's notes")
            case .keepTheirs:
                try checkEqual(titles, ["One", "Two by A", "Three"])
                try checkEqual(b.task(two, in: board)?.task.description, "")
            case .keepBoth:
                try checkEqual(titles.sorted(), ["One", "Three", "Two by A", "Two by B"])
                try checkEqual(b.task(two, in: board)?.task.title, "Two by A", "the place's version keeps the id")
            }
            try checkEqual(b.comments(of: two, in: board).map(\.text), ["A's comment stays either way"])
        }
    }

    await test("record policy asks when both changed one record, even different fields; field policy merges those") {
        for policy in [MergePolicy.record, .field] {
            let (world, a, b, board) = try await pair(policy: policy)
            let one = a.taskID("One", in: board)!
            try await a.updateTask(one, in: board, title: "One renamed by A")
            try await b.setDone(one, in: board, true)
            try await syncClean(a)
            let report = await b.sync()!
            if policy == .record {
                try checkEqual(report.conflicts.map(\.reason), [.bothChanged])
            } else {
                try check(report.conflicts.isEmpty)
                try checkEqual(b.task(one, in: board)?.task.title, "One renamed by A")
                try checkEqual(b.task(one, in: board)?.task.done, true)
            }
            await world.close()
        }
    }

    await test("deleted vs unchanged: the deletion wins; deleted vs changed: asked, and each answer does what it says") {
        do {
            let (world, a, b, board) = try await pair()
            try await a.deleteTask(a.taskID("One", in: board)!, in: board)
            try await syncClean(a)
            try await syncClean(b)
            try checkEqual(b.columns(of: board)[0].tasks.map(\.task.title), ["Two", "Three"])
            await world.close()
        }
        for choice in [ConflictChoice.keepMine, .keepTheirs] {
            let (world, a, b, board) = try await pair()
            let two = a.taskID("Two", in: board)!
            try await a.deleteTask(two, in: board)
            try await b.updateTask(two, in: board, title: "Two, changed on B")
            try await syncClean(a)
            let question = await b.sync()!.conflicts.first
            try checkEqual(question?.reason, .deletedThere)
            try checkEqual(question?.theirs, nil, "deleted on the place")
            try check(question?.mine?.hasPrefix("Two, changed on B") == true)
            try checkEqual(question?.choices, [.keepMine, .keepTheirs], "keeping both makes no sense for a deletion")
            try await b.resolveConflict(question!.id, choice)
            try await syncClean(a)
            let expected = choice == .keepMine ? ["One", "Two, changed on B", "Three"] : ["One", "Three"]
            try checkEqual(b.columns(of: board)[0].tasks.map(\.task.title), expected)
            try checkEqual(a.columns(of: board)[0].tasks.map(\.task.title), expected)
            await world.close()
        }
    }

    await test("deleted here, commented there: asked, never dropped with the comment") {
        let (world, a, b, board) = try await pair()
        let three = a.taskID("Three", in: board)!
        try await b.addComment(to: three, in: board, text: "still needed!")
        try await syncClean(b)
        try await a.deleteTask(three, in: board)
        let question = await a.sync()!.conflicts.first
        try checkEqual(question?.reason, .deletedHere)
        try checkEqual(question?.mine, nil)
        try await a.resolveConflict(question!.id, .keepTheirs)
        try checkEqual(a.comments(of: three, in: board).map(\.text), ["still needed!"])
    }

    await test("a board deleted on one Mac while changed on the other: asked; deleted where it was unchanged") {
        do {
            let (world, a, b, board) = try await pair()
            try await a.deleteBoard(board)
            try await b.addComment(to: b.taskID("One", in: board)!, in: board, text: "keep this board")
            try await syncClean(b)
            let question = await a.sync()!.conflicts.first
            try checkEqual(question?.subject, .boardContents)
            try checkEqual(question?.reason, .deletedHere)
            try check(question?.theirs?.contains("1 comment(s)") == true, question?.theirs ?? "")
            try await a.resolveConflict(question!.id, .keepTheirs)
            try checkEqual(a.boards.map(\.name), ["Roadmap"], "kept: it comes back")
            try checkEqual(a.file(board), b.file(board))
            await world.close()
        }
        do {
            let (world, a, b, board) = try await pair()
            try await a.deleteBoard(board)
            try await syncClean(a)
            try check(!world.placeHas("boards/\(board).json"), "its file is deleted on the place")
            try await syncClean(b)
            try checkEqual(b.boards.count, 0)
            try check(b.file(board) == nil)
            await world.close()
        }
    }

    await test("ifVersion: a write refused because the place changed restarts the sync, which merges instead of overwriting") {
        var place: FaultyPlace?
        let (world, a, _, board) = try await pair { inner in
            let faulty = FaultyPlace(inner)
            place = faulty
            return faulty
        }
        try await a.updateTask(a.taskID("One", in: board)!, in: board, title: "One by A")
        // Right before A writes the board, someone else changes another task in the place's file.
        var once = true
        place!.beforeWrite = { path in
            guard once, path.hasPrefix("boards/") else { return }
            once = false
            try world.editPlace(path) { json in
                var tasks = json["tasks"]!.arrayValue!
                let at = tasks.firstIndex { $0["title"] == "Three" }!
                var task = tasks[at].objectValue!
                task["title"] = "Three edited by hand"
                task["updatedAt"] = "2026-10-24T12:00:00.000Z"
                tasks[at] = .object(task)
                var object = json.objectValue!
                object["tasks"] = .array(tasks)
                json = .object(object)
            }
        }
        let report = try await syncClean(a)
        try checkEqual(report.restarts, 1)
        let titles = try placeBoard(world, board).tasks.map(\.title).sorted()
        try checkEqual(titles, ["One by A", "Three edited by hand", "Two"], "both changes, nothing overwritten")
        try checkEqual(a.file(board)!.tasks.map(\.title).sorted(), titles)
    }

    await test("nothing is read or written when both sides are unchanged") {
        let (world, a, b, _) = try await pair()
        let reads = world.calls("storage/read")
        let writes = world.calls("storage/write")
        let lists = world.calls("storage/list")
        try await syncClean(a)
        try await syncClean(b)
        try checkEqual(world.calls("storage/read"), reads)
        try checkEqual(world.calls("storage/write"), writes)
        try checkEqual(world.calls("storage/delete"), 0)
        try check(world.calls("storage/list") > lists, "only the listing (names and versions)")
    }

    await test("an interrupted sync (stopped before a write) leaves the place readable and resumes; nothing is lost") {
        var place: FaultyPlace?
        let world = try await World()
        let data = try temporaryFolder("A")
        let a = try world.mac("A", data: data) { inner in
            let faulty = FaultyPlace(inner)
            faulty.killBeforeWrite = 3    // board 1, board 2, then the index: stopped before the index
            place = faulty
            return faulty
        }
        await a.activate(workspace: work, place: world.handle)
        let first = try await a.createBoard(name: "First")
        let second = try await a.createBoard(name: "Second")
        _ = try await a.addTask(to: first, column: a.columns(of: first)[0].column.id, title: "kept")
        let report = await a.sync()
        try checkEqual(report, nil)
        try check(a.status.error != nil, "the stop is reported")
        try checkEqual(place!.writes, 3)
        // The place: both board files, no index yet — a reader sees no board (old state), never a half one.
        try check(world.placeHas("boards/\(first).json") && !world.placeHas("index.json"))
        let b = try world.mac("B")
        await b.activate(workspace: work, place: world.handle)
        try await syncClean(b)
        try checkEqual(b.boards.count, 0, "another Mac sees the old state")

        // The plugin starts again (a new controller on the same data folder) and syncs: it resumes.
        let again = try world.mac("A", data: data)
        await again.activate(workspace: work, place: world.handle)
        try check(again.status.unsynced)
        try await syncClean(again)
        try checkEqual(again.boards.map(\.name).sorted(), ["First", "Second"])
        try await syncClean(b)
        try checkEqual(b.boards.map(\.name).sorted(), ["First", "Second"])
        try checkEqual(b.file(first), again.file(first))
        try checkEqual(b.file(second), again.file(second))
    }

    await test("an interrupted sync (stopped after a write reached the place, before this Mac recorded it) resumes without a question") {
        let (world, _, b, board) = try await pair()
        let data = try temporaryFolder("C")
        var place: FaultyPlace?
        let c = try world.mac("C", data: data) { inner in
            let faulty = FaultyPlace(inner)
            place = faulty
            return faulty
        }
        await c.activate(workspace: work, place: world.handle)
        try await syncClean(c)
        try await b.updateTask(b.taskID("One", in: board)!, in: board, title: "One by B")
        try await syncClean(b)
        try await c.updateTask(c.taskID("Two", in: board)!, in: board, title: "Two by C")
        place!.killAfterWrite = place!.writes + 1
        _ = await c.sync()
        try check(c.status.error != nil)
        // The place has C's merged board; C's own copy and base do not know yet. The journal does.
        try checkEqual(try placeBoard(world, board).tasks.map(\.title).sorted(), ["One by B", "Three", "Two by C"])
        try check(FileManager.default.fileExists(atPath: data.appendingPathComponent("workspaces/w-w1/sync/journal").path))

        // Edited again on C before the next sync: kept, on top of what was written.
        let again = try world.mac("C", data: data)
        await again.activate(workspace: work, place: world.handle)
        try await again.updateTask(again.taskID("Three", in: board)!, in: board, title: "Three by C")
        let report = try await syncClean(again)
        try checkEqual(report.conflicts.count, 0)
        try checkEqual(again.file(board)!.tasks.map(\.title).sorted(), ["One by B", "Three by C", "Two by C"])
        try checkEqual(try placeBoard(world, board), again.file(board)!)
        try check((try? FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("workspaces/w-w1/sync/journal").path))?.isEmpty ?? true)
    }

    await test("Sync never loses unsynced changes: an unreachable place keeps them, marked unsynced") {
        let (world, _, b, board) = try await pair()
        try await b.updateTask(b.taskID("One", in: board)!, in: board, title: "Precious")
        // The place goes away (the folder is removed: Vektor answers "missing").
        try FileManager.default.removeItem(at: world.placeFolder)
        let report = await b.sync()
        try checkEqual(report, nil)
        try check(b.status.error?.contains("no longer exists") == true || b.status.error?.isEmpty == false, b.status.error ?? "")
        try check(b.status.unsynced)
        try checkEqual(b.task(b.taskID("Precious", in: board)!, in: board)?.task.title, "Precious")
    }

    await test("a place emptied after a sync is never read as “every board deleted”: this Mac's boards are sent again") {
        let (world, a, _, board) = try await pair()
        for name in try FileManager.default.contentsOfDirectory(atPath: world.placeFolder.path) {
            try FileManager.default.removeItem(at: world.placeFolder.appendingPathComponent(name))
        }
        try await syncClean(a)
        try checkEqual(a.boards.map(\.name), ["Roadmap"])
        try checkEqual(try placeBoard(world, board), a.file(board)!)
    }

    await test("a Mac with boards of its own joins a place with other boards: both sets, nothing asked") {
        let (world, a, _, board) = try await pair()
        let c = try world.mac("C")
        await c.activate(workspace: work, place: nil)
        let own = try await c.createBoard(name: "C's own")
        await c.activate(workspace: work, place: world.handle)
        try await syncClean(c)
        try checkEqual(Set(c.boards.map(\.id)), [board, own])
        try await syncClean(a)
        try checkEqual(Set(a.boards.map(\.id)), [board, own])
    }

    await test("a board file edited by hand into something else is refused in plain words, never overwritten") {
        let (world, a, _, board) = try await pair()
        try Data("{\"not\": \"a board\"}".utf8).write(to: world.placeFolder.appendingPathComponent("boards/\(board).json"))
        try await a.updateTask(a.taskID("One", in: board)!, in: board, title: "changed")
        _ = await a.sync()
        try check(a.status.error?.contains("is not a board this plugin can read") == true, a.status.error ?? "")
        try checkEqual(String(decoding: try Data(contentsOf: world.placeFolder.appendingPathComponent("boards/\(board).json")), as: UTF8.self), "{\"not\": \"a board\"}")
        try check(a.status.unsynced)
    }

    await test("a folder on this Mac as the place: saved there on each change, no Sync button") {
        let world = try await World(remote: false)
        let a = try world.mac("A")
        await a.activate(workspace: work, place: world.handle)
        try check(!a.status.showsSyncButton)
        let board = try await a.createBoard(name: "Local")
        try await a.addTask(to: board, column: a.columns(of: board)[0].column.id, title: "on disk")
        await a.settle()
        try checkEqual(try placeBoard(world, board).tasks.map(\.title), ["on disk"])
        try check(!a.status.unsynced)
        try checkEqual(try world.placeJSON("index.json").value(at: "boards.0.name"), "Local")
    }

    await test("the Log: counts and plain words only — never a name, a title, a description, a comment or the place's handle") {
        let (world, a, b, board) = try await pair()
        let secrets = ["Secret board name 7731", "Secret task title 4410", "Secret description 9921", "Secret comment 5512", "Secret tag 1093"]
        try await a.renameBoard(board, to: secrets[0])
        let task = try await a.addTask(to: board, column: a.columns(of: board)[0].column.id, title: secrets[1], description: secrets[2])
        try await a.addComment(to: task, in: board, text: secrets[3])
        try await a.setTaskTags(task, in: board, names: [secrets[4]])
        try await syncClean(a)
        try await syncClean(b)
        try await b.updateTask(task, in: board, title: secrets[1] + " B")
        try await a.updateTask(task, in: board, title: secrets[1] + " A")
        try await syncClean(b)
        _ = await a.sync()   // a question
        try await a.resolveConflict(a.status.conflicts[0].id, .keepBoth)
        try await a.deleteBoard(board)
        try await syncClean(a)
        try check(!world.logs.isEmpty, "the controller does log")
        let pluginLog = world.host.notifications("log").compactMap { $0.params["message"]?.stringValue }
        let stderr = world.host.transcript.filter { $0.hasPrefix("stderr:") }
        for line in world.logs + pluginLog + stderr {
            for secret in secrets { try check(!line.contains(secret), "the Log line “\(line)” contains a record's contents") }
            try check(!line.contains(world.handle.place), "the Log line “\(line)” contains the place's handle")
        }
    }
}
