import Foundation
import VektorPlugin

// What the views read: a board's columns with the tasks they show under the board's filter, the same tasks as list rows,
// one task with its comments. Built from a per-board index (`Derived`: tasks by column in order, comment counts, tags by id)
// that is made once per change, so drawing a board of thousands of tasks costs one pass over them, never a search per card.

/// The "All tasks" filter, the Tags filter and the search of one board. Kept while the plugin runs.
public struct BoardFilter: Equatable, Sendable {
    public enum Status: String, Sendable, CaseIterable {
        case all, open, done
        public var title: String {
            switch self {
            case .all: return "All tasks"
            case .open: return "Open tasks"
            case .done: return "Done tasks"
            }
        }
    }
    public var status: Status
    /// Tag ids: a task shows when it has any of them (none: every task).
    public var tags: [String]
    /// Words the title, the description or a tag's name contain (case and accents ignored).
    public var search: String

    public init(status: Status = .all, tags: [String] = [], search: String = "") {
        self.status = status
        self.tags = tags
        self.search = search
    }

    public var isActive: Bool { status != .all || !tags.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ task: TaskRecord, tags all: [String: TagRecord]) -> Bool {
        switch status {
        case .all: break
        case .open: if task.done { return false }
        case .done: if !task.done { return false }
        }
        if !tags.isEmpty, !task.tags.contains(where: tags.contains) { return false }
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let names = task.tags.compactMap { all[$0]?.name }
        let haystack = ([task.title, task.description] + names).joined(separator: "\n")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// A task as a card or a row shows it.
public struct TaskView: Equatable, Sendable {
    public var task: TaskRecord
    /// Its tags, in the task's order.
    public var tags: [TagRecord]
    /// How many comments it has.
    public var comments: Int
}

/// A column and the tasks it shows.
public struct ColumnView: Equatable, Sendable {
    public var column: ColumnRecord
    /// The tasks the filter lets through, in order.
    public var tasks: [TaskView]
    /// Every task in the column ("3 of 5" while a filter hides some).
    public var total: Int
}

/// A row of the list view.
public struct TaskRow: Equatable, Sendable {
    public var task: TaskRecord
    public var column: ColumnRecord?
    public var tags: [TagRecord]
    public var comments: Int
    public var updated: Date?
}

/// How the list view is sorted.
public struct ListSort: Equatable, Sendable {
    public enum Key: String, Sendable, CaseIterable { case board, title, column, tags, done, comments, updated }
    /// `.board`: the board's own order (column, then place in the column).
    public var key: Key
    public var ascending: Bool
    public init(_ key: Key = .board, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

/// One board's tasks indexed for drawing.
struct Derived {
    var columns: [ColumnRecord]
    var tasksByColumn: [String: [TaskRecord]]
    var commentCounts: [String: Int]
    var tagsByID: [String: TagRecord]
    var tags: [TagRecord]

    init(_ file: BoardFile) {
        let file = file.normalized()
        columns = file.columns
        tags = file.tags
        tagsByID = Dictionary(file.tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tasksByColumn = Dictionary(grouping: file.tasks, by: \.column).mapValues { $0.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) } }
        commentCounts = file.comments.reduce(into: [:]) { $0[$1.task, default: 0] += 1 }
    }

    func view(_ task: TaskRecord) -> TaskView {
        TaskView(task: task, tags: task.tags.compactMap { tagsByID[$0] }, comments: commentCounts[task.id] ?? 0)
    }
}

extension BoardController {
    public func filter(of board: String) -> BoardFilter { filterValue(board) }

    /// Sets a board's filter (the "All tasks" picker, the Tags filter, the search). Tag ids the board does not have are dropped.
    public func setFilter(_ filter: BoardFilter, for board: String) {
        var filter = filter
        if let known = file(board).map({ Set($0.tags.map(\.id)) }) { filter.tags = filter.tags.filter(known.contains) }
        guard filter != filterValue(board) else { return }
        setFilterValue(filter, board)
        onChange?(.board(board))
    }

    /// The board's columns in order, each with the tasks the filter lets through.
    public func columns(of board: String) -> [ColumnView] {
        guard let derived = derivedValue(board) else { return [] }
        let filter = filterValue(board)
        return derived.columns.map { column in
            let all = derived.tasksByColumn[column.id] ?? []
            let shown = filter.isActive ? all.filter { filter.matches($0, tags: derived.tagsByID) } : all
            return ColumnView(column: column, tasks: shown.map(derived.view), total: all.count)
        }
    }

    /// The same tasks as `columns(of:)` shows, as rows of the list view, sorted.
    public func listRows(of board: String, sort: ListSort = ListSort()) -> [TaskRow] {
        guard let derived = derivedValue(board) else { return [] }
        let filter = filterValue(board)
        var rows: [TaskRow] = []
        var columnOrder: [String: Int] = [:]
        for (number, column) in derived.columns.enumerated() {
            columnOrder[column.id] = number
            for task in derived.tasksByColumn[column.id] ?? [] where !filter.isActive || filter.matches(task, tags: derived.tagsByID) {
                let view = derived.view(task)
                rows.append(TaskRow(task: task, column: column, tags: view.tags, comments: view.comments, updated: Stamp.date(task.updatedAt)))
            }
        }
        func names(_ row: TaskRow) -> String { row.tags.map(\.name).joined(separator: ", ") }
        func before(_ a: TaskRow, _ b: TaskRow) -> Bool {
            switch sort.key {
            case .board: return false
            case .title: return a.task.title.localizedStandardCompare(b.task.title) == .orderedAscending
            case .column: return (columnOrder[a.task.column] ?? 0) < (columnOrder[b.task.column] ?? 0)
            case .tags: return names(a).localizedStandardCompare(names(b)) == .orderedAscending
            case .done: return !a.task.done && b.task.done
            case .comments: return a.comments < b.comments
            case .updated: return a.task.updatedAt < b.task.updatedAt
            }
        }
        guard sort.key != .board else { return sort.ascending ? rows : rows.reversed() }
        // Stable: equal rows keep the board's order.
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { x, y in
            if before(x.1, y.1) { return sort.ascending }
            if before(y.1, x.1) { return !sort.ascending }
            return x.0 < y.0
        }.map(\.1)
    }

    /// One task as a card shows it.
    public func task(_ id: String, in board: String) -> TaskView? {
        guard let derived = derivedValue(board), let file = file(board), let task = file.tasks.first(where: { $0.id == id }) else { return nil }
        return derived.view(task)
    }

    /// A task's comments, oldest first.
    public func comments(of task: String, in board: String) -> [CommentRecord] {
        (file(board)?.comments ?? []).filter { $0.task == task }.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
    }

    /// A board's tags, in order (Board settings ▸ Tags, the Tags filter, a task's tag picker).
    public func tags(of board: String) -> [TagRecord] { derivedValue(board)?.tags ?? [] }
}
