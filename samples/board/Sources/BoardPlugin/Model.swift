import Foundation

// The data model: what one workspace's boards are, as records with stable ids, and the two kinds of file that hold them.
//
//     index.json              the workspace's boards: id, name, order            (BoardIndexFile)
//     boards/<board id>.json  one board: its columns, tasks, tags and comments  (BoardFile)
//
// Both are human-readable JSON (keys sorted, pretty-printed). Every record has a stable `id`, never its name or position, and
// an `updatedAt` (ISO 8601, milliseconds, UTC). That is what lets a sync merge record by record: two people who change
// different records never conflict. Order is a `rank` per record (a fractional index, `Rank`), never a position in an array,
// so moving one task changes that one task and nothing else. A path is built from a board's id, never from its name, and only
// from an id `Ids.isBoardID` accepts: one board's operations can never reach another board's file.
//
// Colours are colour ROLES of the theme (`label1` … `label8`, `accent`, `neutral` …), stored by name, never a colour value.

/// The shape every record shares: a stable id and when it last changed.
public protocol BoardRecordType: Codable, Equatable, Sendable {
    var id: String { get set }
    var updatedAt: String { get set }
}

extension BoardRecordType {
    /// The same record, ignoring when it changed: two sides that made the same change agree.
    func sameContent(as other: Self) -> Bool {
        var a = self
        var b = other
        a.updatedAt = ""
        b.updatedAt = ""
        return a == b
    }
}

/// A board as the index lists it.
public struct BoardRecord: BoardRecordType {
    public var id: String
    public var name: String
    public var rank: String
    public var updatedAt: String
    public init(id: String, name: String, rank: String, updatedAt: String) {
        self.id = id
        self.name = name
        self.rank = rank
        self.updatedAt = updatedAt
    }
}

public struct ColumnRecord: BoardRecordType {
    public var id: String
    public var title: String
    /// A colour role's name (`label6`), or nil for none.
    public var role: String?
    public var rank: String
    public var updatedAt: String
    public init(id: String, title: String, role: String? = nil, rank: String, updatedAt: String) {
        self.id = id
        self.title = title
        self.role = role
        self.rank = rank
        self.updatedAt = updatedAt
    }
}

public struct TaskRecord: BoardRecordType {
    public var id: String
    /// The column it is in.
    public var column: String
    /// Its place in the column.
    public var rank: String
    public var title: String
    /// Markdown.
    public var description: String
    /// Tag ids, in the order the user gave them.
    public var tags: [String]
    public var done: Bool
    public var createdAt: String
    public var updatedAt: String
    public init(
        id: String, column: String, rank: String, title: String, description: String = "", tags: [String] = [], done: Bool = false,
        createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.column = column
        self.rank = rank
        self.title = title
        self.description = description
        self.tags = tags
        self.done = done
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TagRecord: BoardRecordType {
    public var id: String
    public var name: String
    /// A colour role's name, or nil for none.
    public var role: String?
    public var rank: String
    public var updatedAt: String
    public init(id: String, name: String, role: String? = nil, rank: String, updatedAt: String) {
        self.id = id
        self.name = name
        self.role = role
        self.rank = rank
        self.updatedAt = updatedAt
    }
}

/// A comment on a task. Comments are a record of their own (not a field of the task), so two people commenting on one task at
/// the same time never conflict. A comment is never edited: added, or deleted by its author.
public struct CommentRecord: BoardRecordType {
    public var id: String
    public var task: String
    /// The macOS user's name of whoever wrote it.
    public var author: String
    /// When it was written (ISO 8601).
    public var time: String
    public var text: String
    public var updatedAt: String
    public init(id: String, task: String, author: String, time: String, text: String, updatedAt: String) {
        self.id = id
        self.task = task
        self.author = author
        self.time = time
        self.text = text
        self.updatedAt = updatedAt
    }
}

/// `index.json`.
public struct BoardIndexFile: Codable, Equatable, Sendable {
    public static let formatName = "vektor-board-index"
    public var format = BoardIndexFile.formatName
    public var version = 1
    public var boards: [BoardRecord]
    public init(boards: [BoardRecord] = []) { self.boards = boards }

    /// Sorted the one way every copy is sorted, so two equal indexes are equal values and equal bytes.
    public func normalized() -> BoardIndexFile {
        var copy = self
        copy.boards.sort { ($0.rank, $0.id) < ($1.rank, $1.id) }
        return copy
    }
}

/// `boards/<id>.json`: one board's columns, tasks, tags and comments. The board's name and place in the list are the index's.
public struct BoardFile: Codable, Equatable, Sendable {
    public static let formatName = "vektor-board"
    public var format = BoardFile.formatName
    public var version = 1
    public var board: String
    public var columns: [ColumnRecord]
    public var tasks: [TaskRecord]
    public var tags: [TagRecord]
    public var comments: [CommentRecord]

    public init(board: String, columns: [ColumnRecord] = [], tasks: [TaskRecord] = [], tags: [TagRecord] = [], comments: [CommentRecord] = []) {
        self.board = board
        self.columns = columns
        self.tasks = tasks
        self.tags = tags
        self.comments = comments
    }

    /// Sorted the one way every copy is sorted: columns and tags by rank, tasks by column then rank, comments by task then
    /// time. Ties (two copies inserting at the same place) are broken by id, so every copy shows the same order.
    public func normalized() -> BoardFile {
        var copy = self
        copy.columns.sort { ($0.rank, $0.id) < ($1.rank, $1.id) }
        copy.tags.sort { ($0.rank, $0.id) < ($1.rank, $1.id) }
        copy.tasks.sort { ($0.column, $0.rank, $0.id) < ($1.column, $1.rank, $1.id) }
        copy.comments.sort { ($0.task, $0.time, $0.id) < ($1.task, $1.time, $1.id) }
        return copy
    }
}

// MARK: - Reading and writing the files

enum BoardJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    static func index(_ data: Data, path: String) throws -> BoardIndexFile {
        guard let file = try? JSONDecoder().decode(BoardIndexFile.self, from: data), file.format == BoardIndexFile.formatName else {
            throw BoardError("“\(path)” is not a board index this plugin can read, so nothing was changed.")
        }
        guard file.version <= 1 else { throw BoardError("“\(path)” was written by a newer version of this plugin. Update the plugin to use it.") }
        var seen = Set<String>()
        for board in file.boards {
            guard Ids.isBoardID(board.id) else { throw BoardError("“\(path)” lists a board whose id cannot be used, so nothing was changed.") }
            guard seen.insert(board.id).inserted else { throw BoardError("“\(path)” lists a board twice, so nothing was changed.") }
        }
        return file.normalized()
    }

    static func board(_ data: Data, path: String, id: String) throws -> BoardFile {
        guard let file = try? JSONDecoder().decode(BoardFile.self, from: data), file.format == BoardFile.formatName else {
            throw BoardError("“\(path)” is not a board this plugin can read, so nothing was changed.")
        }
        guard file.version <= 1 else { throw BoardError("“\(path)” was written by a newer version of this plugin. Update the plugin to use it.") }
        guard file.board == id else { throw BoardError("“\(path)” holds another board than its name says, so nothing was changed.") }
        func unique<R: BoardRecordType>(_ records: [R]) -> Bool {
            var seen = Set<String>()
            return records.allSatisfy { !$0.id.isEmpty && seen.insert($0.id).inserted }
        }
        guard unique(file.columns), unique(file.tasks), unique(file.tags), unique(file.comments) else {
            throw BoardError("“\(path)” holds a record twice, so nothing was changed.")
        }
        return file.normalized()
    }
}

// MARK: - Ids, time

public enum Ids {
    private static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

    /// A new id: a kind letter, a dash and 16 random characters (80 bits): `b-…` board, `c-…` column, `t-…` task, `g-…` tag,
    /// `m-…` comment.
    public static func make(_ kind: Character) -> String {
        var generator = SystemRandomNumberGenerator()
        return "\(kind)-" + String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// Whether `id` may name a board's file: letters, digits, `-` and `_`, 1 to 64 of them. A board id read from a place that
    /// is not one is refused (the place may have been edited by hand), never used to build a path.
    public static func isBoardID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    /// The path of a board's file, relative to the place.
    static func boardPath(_ id: String) -> String { "boards/\(id).json" }

    /// The board id a path names, or nil.
    static func boardID(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let id = String(name.dropLast(5))
        return isBoardID(id) ? id : nil
    }
}

enum Stamp {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    /// The same without fractions of a second: a file another tool (or a hand) wrote says `…T16:06:30Z` (seen in Vektor: such a
    /// time was shown raw instead of "3 minutes ago").
    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let lock = NSLock()

    static func string(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: text) ?? whole.date(from: text)
    }
}

/// An error in plain words: shown to the user as written.
public struct BoardError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}
