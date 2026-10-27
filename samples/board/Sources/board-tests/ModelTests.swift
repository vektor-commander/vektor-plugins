import BoardPlugin
import Foundation
import VektorPlugin
import VektorPluginTestKit

// Boards, columns, tasks, tags and comments without a place: the commands the views call, the order they keep, the files they
// write, and that a restart of the plugin finds everything again.

@MainActor
private func localCopy(_ data: URL? = nil, workspace: Workspace? = Workspace(id: "w1", name: "Work"), author: String = "Ada") async throws -> (BoardController, URL) {
    let folder = try data ?? temporaryFolder()
    let clock = Clock()
    let controller = BoardController(dataFolder: folder, options: BoardController.Options(author: author, now: { clock.tick() })) { _ in
        fatalError("no place in these tests")
    }
    await controller.activate(workspace: workspace, place: nil)
    return (controller, folder)
}

@MainActor
func modelTests() async {
    await test("ranks: always strictly between, never ending in 0, any number of times at the same place") {
        var low: String? = nil
        var high: String? = nil
        for _ in 0..<200 {
            let mid = Rank.between(low, high)
            if let low { try check(low < mid, "\(low) < \(mid)") }
            if let high { try check(mid < high, "\(mid) < \(high)") }
            try check(!mid.hasSuffix("0"), mid)
            high = mid  // always insert at the very start: the worst case
        }
        try check((high ?? "").count < 60, "ranks stay short: \(high ?? "")")
        let spread = Rank.spread(1000)
        try checkEqual(spread, spread.sorted())
        try checkEqual(Set(spread).count, 1000)
        for (a, b) in [("a", "b"), ("a", "a1"), ("0i", "1"), ("zz", nil as String?), ("", "1")] {
            let mid = Rank.between(a, b)
            try check(a < mid && (b == nil || mid < b!), "\(a) < \(mid) < \(b ?? "∞")")
        }
    }

    await test("boards: per workspace, isolated; created with the mock-up's columns; renamed, reordered, deleted") {
        let data = try temporaryFolder()
        let (work, _) = try await localCopy(data, workspace: Workspace(id: "w1", name: "Work"))
        let roadmap = try await work.createBoard(name: "  Roadmap ")
        let bugs = try await work.createBoard(name: "Bugs")
        try checkEqual(work.boards.map(\.name), ["Roadmap", "Bugs"])
        try checkEqual(work.columns(of: roadmap).map(\.column.title), ["Backlog", "In Progress", "Review", "Done"])
        try checkEqual(work.columns(of: roadmap).map(\.column.role), ["neutral", "label6", "label7", "label4"])

        let (home, _) = try await localCopy(data, workspace: Workspace(id: "w2", name: "Home"))
        try checkEqual(home.boards.map(\.name), [], "another workspace has none of them")
        try check(!home.contains(roadmap) && home.file(roadmap) == nil, "a board of another workspace is not reachable")
        try await checkThrows("not in this workspace") { try await home.renameBoard(roadmap, to: "Mine now") }
        let garden = try await home.createBoard(name: "Garden")

        // The same controller switching workspace shows only that workspace's boards.
        await work.activate(workspace: Workspace(id: "w2", name: "Home"), place: nil)
        try checkEqual(work.boards.map(\.id), [garden])
        await work.activate(workspace: Workspace(id: "w1", name: "Work"), place: nil)
        try checkEqual(work.boards.map(\.id), [roadmap, bugs])

        try await work.renameBoard(bugs, to: "Bug reports")
        try await work.moveBoard(bugs, to: 0)
        try checkEqual(work.boards.map(\.name), ["Bug reports", "Roadmap"])
        try await checkThrows("needs a name") { try await work.renameBoard(bugs, to: "   ") }

        // Deleting removes only that board's file: the other board and the other workspace are untouched.
        let roadmapFile = data.appendingPathComponent("workspaces/w-w1/working/boards/\(roadmap).json")
        let bugsFile = data.appendingPathComponent("workspaces/w-w1/working/boards/\(bugs).json")
        try check(FileManager.default.fileExists(atPath: roadmapFile.path) && FileManager.default.fileExists(atPath: bugsFile.path))
        try await work.deleteBoard(bugs)
        try check(!FileManager.default.fileExists(atPath: bugsFile.path))
        try check(FileManager.default.fileExists(atPath: roadmapFile.path))
        try checkEqual(work.boards.map(\.name), ["Roadmap"])
        await work.activate(workspace: Workspace(id: "w2", name: "Home"), place: nil)
        try checkEqual(work.boards.map(\.name), ["Garden"])
    }

    await test("paths are built from ids, never names: a hostile name stays a name; a hostile id is refused") {
        let (local, data) = try await localCopy()
        let board = try await local.createBoard(name: "../../etc/passwd")
        try checkEqual(local.boardName(board), "../../etc/passwd")
        try check(Ids.isBoardID(board))
        let files = try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("workspaces/w-w1/working/boards").path)
        try checkEqual(files, ["\(board).json"])
        for bad in ["../x", "a/b", "", ".", "x y", String(repeating: "a", count: 65), "naïve"] { try check(!Ids.isBoardID(bad), bad) }
        // A workspace id that is not plain becomes a hash, never a path.
        let hostile = WorkspaceFolders.name(for: Workspace(id: "../../x", name: "x"))
        try check(!hostile.contains("/") && !hostile.contains(".."), hostile)
    }

    await test("columns, tasks, tags and comments: every operation, and the order kept") {
        let (local, _) = try await localCopy(author: "Ada Lovelace")
        let board = try await local.createBoard(name: "Roadmap", columns: [("To do", nil), ("Doing", .label6), ("Done", .label4)])
        let todo = local.columnID("To do", in: board)!
        let doing = local.columnID("Doing", in: board)!
        let done = local.columnID("Done", in: board)!
        let a = try await local.addTask(to: board, column: todo, title: "A")
        let b = try await local.addTask(to: board, column: todo, title: "B", description: "**bold** text")
        let c = try await local.addTask(to: board, column: todo, title: "C")
        _ = try await local.addTask(to: board, column: todo, title: "First", at: 0)
        try checkEqual(local.layout(board), "To do: First, A, B, C | Doing:  | Done: ")

        // Moves within a column and between columns, as a drag or ⌥ + arrow reports them.
        try await local.moveTask(c, in: board, to: todo, at: 1)
        try checkEqual(local.layout(board), "To do: First, C, A, B | Doing:  | Done: ")
        try await local.moveTask(a, in: board, to: doing, at: 0)
        try await local.moveTask(b, in: board, to: doing, at: 0)
        try checkEqual(local.layout(board), "To do: First, C | Doing: B, A | Done: ")
        try await local.moveTask(b, in: board, to: doing, at: 99)
        try checkEqual(local.layout(board), "To do: First, C | Doing: A, B | Done: ")

        // Fields.
        try await local.updateTask(a, in: board, title: "A!", description: "# Notes")
        try await local.setDone(a, in: board, true)
        let task = local.task(a, in: board)!.task
        try checkEqual([task.title, task.description, "\(task.done)"], ["A!", "# Notes", "true"])
        try await checkThrows("needs a title") { try await local.updateTask(a, in: board, title: "  ") }

        // Tags: created, several per task, renamed, coloured by role, reordered, deleted (and taken off the tasks).
        let feature = try await local.addTag(to: board, name: "feature", role: .label6)
        try await local.setTaskTags(b, in: board, names: ["feature", "UI", "ui"])
        try checkEqual(local.task(b, in: board)!.tags.map(\.name), ["feature", "UI"])
        let ui = local.tags(of: board).first { $0.name == "UI" }!.id
        try check(local.tags(of: board).allSatisfy { Role(rawValue: $0.role ?? "") != nil }, "tags get a colour role, never a value")
        try await checkThrows("already has a tag") { try await local.addTag(to: board, name: "Feature") }
        try await local.renameTag(feature, in: board, to: "feat")
        try await local.setTagRole(feature, in: board, to: .label2)
        try await local.moveTag(ui, in: board, to: 0)
        try checkEqual(local.tags(of: board).map(\.name), ["UI", "feat"])
        try checkEqual(local.tags(of: board).last?.role, "label2")
        try await local.deleteTag(ui, in: board)
        try checkEqual(local.task(b, in: board)!.tags.map(\.name), ["feat"])

        // Comments: author is the macOS user, time is now; only one's own can be deleted.
        let comment = try await local.addComment(to: b, in: board, text: "Looks good")
        try await local.addComment(to: b, in: board, text: "Ship it")
        try checkEqual(local.comments(of: b, in: board).map(\.text), ["Looks good", "Ship it"])
        try checkEqual(local.comments(of: b, in: board).first?.author, "Ada Lovelace")
        try checkEqual(local.task(b, in: board)!.comments, 2)
        try await local.deleteComment(comment, in: board)
        try checkEqual(local.task(b, in: board)!.comments, 1)

        // Columns: renamed, coloured, reordered, deleted with their tasks moved — or deleted with them.
        try await local.renameColumn(doing, in: board, to: "In Progress")
        try await local.setColumnRole(doing, in: board, to: .label7)
        try await local.moveColumn(done, in: board, to: 0)
        try checkEqual(local.layout(board), "Done:  | To do: First, C | In Progress: A!, B")
        try await local.deleteColumn(doing, in: board, tasks: .moveTo(todo))
        try checkEqual(local.layout(board), "Done:  | To do: First, C, A!, B")
        try checkEqual(local.comments(of: b, in: board).count, 1, "moved tasks keep their comments")
        let extra = try await local.addColumn(to: board, title: "Later", role: .label3)
        try await local.moveTask(c, in: board, to: extra, at: 0)
        try await local.addComment(to: c, in: board, text: "gone soon")
        try await local.deleteColumn(extra, in: board, tasks: .delete)
        try checkEqual(local.layout(board), "Done:  | To do: First, A!, B")
        try check(local.file(board)!.comments.allSatisfy { $0.task != c }, "a deleted task's comments go with it")

        // Delete a selection at once.
        try await local.deleteTasks([a, b], in: board)
        try checkEqual(local.layout(board), "Done:  | To do: First")
    }

    await test("only one's own comments can be deleted") {
        let data = try temporaryFolder()
        let (ada, _) = try await localCopy(data, author: "Ada")
        let board = try await ada.createBoard(name: "B")
        let task = try await ada.addTask(to: board, column: ada.columns(of: board)[0].column.id, title: "T")
        let comment = try await ada.addComment(to: task, in: board, text: "mine")
        let (bob, _) = try await localCopy(data, author: "Bob")
        try check(!bob.canDelete(comment: bob.comments(of: task, in: board)[0]))
        try await checkThrows("Only its author") { try await bob.deleteComment(comment, in: board) }
    }

    await test("filters: All / Open / Done, tags, search; moves count the tasks shown, hidden ones keep their place") {
        let (local, _) = try await localCopy()
        let board = try await local.createBoard(name: "B", columns: [("To do", nil)])
        let todo = local.columnID("To do", in: board)!
        for title in ["Write docs", "Fix bug", "Ship release", "Plan v2"] { _ = try await local.addTask(to: board, column: todo, title: title) }
        let fix = local.taskID("Fix bug", in: board)!
        try await local.setTaskTags(fix, in: board, names: ["bug"])
        try await local.setDone(local.taskID("Ship release", in: board)!, in: board, true)
        let bug = local.tags(of: board)[0].id

        local.setFilter(BoardFilter(status: .open), for: board)
        try checkEqual(local.layout(board), "To do: Write docs, Fix bug, Plan v2")
        try checkEqual(local.columns(of: board)[0].total, 4)
        local.setFilter(BoardFilter(status: .done), for: board)
        try checkEqual(local.layout(board), "To do: Ship release")
        local.setFilter(BoardFilter(tags: [bug]), for: board)
        try checkEqual(local.layout(board), "To do: Fix bug")
        local.setFilter(BoardFilter(search: "PLAN"), for: board)
        try checkEqual(local.layout(board), "To do: Plan v2")
        local.setFilter(BoardFilter(search: "bug"), for: board)   // a tag's name matches too
        try checkEqual(local.layout(board), "To do: Fix bug")

        // With "Open" on, the shown list is Write docs, Fix bug, Plan v2; moving Plan v2 to index 1 puts it before Fix bug.
        local.setFilter(BoardFilter(status: .open), for: board)
        try await local.moveTask(local.taskID("Plan v2", in: board)!, in: board, to: todo, at: 1)
        local.setFilter(BoardFilter(), for: board)
        try checkEqual(local.layout(board), "To do: Write docs, Plan v2, Fix bug, Ship release")

        // The list view: the same tasks, sortable.
        let rows = local.listRows(of: board, sort: ListSort(.title))
        try checkEqual(rows.map(\.task.title), ["Fix bug", "Plan v2", "Ship release", "Write docs"])
        try checkEqual(local.listRows(of: board, sort: ListSort(.done, ascending: false)).first?.task.title, "Ship release")
        try checkEqual(local.listRows(of: board).map(\.task.title), ["Write docs", "Plan v2", "Fix bug", "Ship release"])
        try checkEqual(rows.first?.column?.title, "To do")
        try check(rows.allSatisfy { $0.updated != nil })
    }

    await test("persistence: a restart of the plugin finds every board, task, tag, comment and order") {
        let data = try temporaryFolder()
        var board = ""
        do {
            let (local, _) = try await localCopy(data)
            board = try await local.createBoard(name: "Kept")
            let column = local.columns(of: board)[1].column.id
            let task = try await local.addTask(to: board, column: column, title: "Survives", description: "with *Markdown*")
            try await local.setTaskTags(task, in: board, names: ["a", "b"])
            try await local.addComment(to: task, in: board, text: "and a comment")
            _ = try await local.addTask(to: board, column: column, title: "Second", at: 0)
        }
        let (again, _) = try await localCopy(data)
        try checkEqual(again.boards.map(\.name), ["Kept"])
        try checkEqual(again.layout(board), "Backlog:  | In Progress: Second, Survives | Review:  | Done: ")
        let task = again.task(again.taskID("Survives", in: board)!, in: board)!
        try checkEqual(task.tags.map(\.name), ["a", "b"])
        try checkEqual(task.task.description, "with *Markdown*")
        try checkEqual(task.comments, 1)
        // The files are human-readable JSON with stable ids and updatedAt on every record.
        let json = try JSONValue.parse(try Data(contentsOf: data.appendingPathComponent("workspaces/w-w1/working/boards/\(board).json")))
        try checkEqual(json["format"], "vektor-board")
        try check(json["tasks"]?.arrayValue?.allSatisfy { $0["id"]?.stringValue != nil && $0["updatedAt"]?.stringValue != nil } == true)
        let text = try String(contentsOf: data.appendingPathComponent("workspaces/w-w1/working/index.json"), encoding: .utf8)
        try check(text.contains("\n  \"boards\""), "pretty-printed")
    }

    await test("thousands of tasks: adding, moving, filtering and drawing stay fast (no size limits)") {
        let (local, _) = try await localCopy()
        let board = try await local.createBoard(name: "Big")
        let columns = local.columns(of: board).map(\.column.id)
        let start = Date()
        for number in 0..<200 { _ = try await local.addTask(to: board, column: columns[number % 4], title: "Task \(number)") }
        let adding = Date().timeIntervalSince(start) / 200
        try check(adding < 0.05, "one add took \(adding) s")
        try checkEqual(local.columns(of: board).map(\.total).reduce(0, +), 200)
        // 5,000 more straight into the file (adding them one by one would measure the disk), then a restart reads it.
        let file = local.file(board)!
        var big = file
        let stamp = file.tasks[0].updatedAt
        let ranks = Rank.spread(5000)
        for number in 0..<5000 {
            big.tasks.append(TaskRecord(id: "t-big\(number)", column: columns[number % 4], rank: ranks[number], title: "Bulk \(number)", createdAt: stamp, updatedAt: stamp))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(big).write(to: local.dataFolder.appendingPathComponent("workspaces/w-w1/working/boards/\(board).json"))
        let reloaded = Date()
        let (again, _) = try await localCopy(local.dataFolder)
        try checkEqual(again.columns(of: board).map(\.total).reduce(0, +), 5200)
        try check(Date().timeIntervalSince(reloaded) < 3, "loading and drawing 5,200 tasks took \(Date().timeIntervalSince(reloaded)) s")
        let moved = Date()
        for number in 0..<20 { try await again.moveTask("t-big\(number)", in: board, to: columns[3], at: number) }
        let movedEach = Date().timeIntervalSince(moved) / 20
        try check(movedEach < 0.5, "one move of 5,200 took \(movedEach) s")
        let filtered = Date()
        again.setFilter(BoardFilter(search: "Bulk 4999"), for: board)
        try checkEqual(again.columns(of: board).flatMap(\.tasks).map(\.task.title), ["Bulk 4999"])
        _ = again.listRows(of: board, sort: ListSort(.title))
        let filtering = Date().timeIntervalSince(filtered)
        try check(filtering < 2, "filtering and sorting 5,200 took \(filtering) s")
        print(String(format: "     (wall clock: one add on 200 tasks %.1f ms; load and draw 5,200 tasks %.0f ms; one move among 5,200 %.0f ms; filter + sort %.0f ms)",
                     adding * 1000, moved.timeIntervalSince(reloaded) * 1000, movedEach * 1000, filtering * 1000))
    }
}
