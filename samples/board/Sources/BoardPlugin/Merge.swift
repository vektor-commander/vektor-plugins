import Foundation
import VektorPlugin

// The three-way merge of a sync, record by record, against the last synced base (what both sides last agreed on):
//
//   only one side changed a record (added, changed or deleted it)  → that side's version
//   both made the same change                                      → taken, no question
//   one deleted it, the other left it as it was                    → deleted ("deletion wins over unchanged")
//   one deleted it, the other changed it                           → ASK (deleted here / deleted there)
//   both changed it differently                                     → ASK (both versions)
//   both added a record with the same id, differently               → ASK
//
// "Changed" is decided by content: `updatedAt` only says which side changed it last. A task also counts as changed on a side
// that added or deleted one of its comments, so a task deleted here while a comment was added there is asked about, never
// dropped with the comment. A real conflict is never decided here: it is reported with both versions, and the user's answer
// (a `ConflictResolution`) is applied the next time the same conflict comes up — the same versions on both sides, or it is
// asked again.
//
// `MergePolicy.record` (the default, the brief's rule) asks whenever both sides changed the same record. `.field` merges a
// record field by field first and asks only when both changed the same field.

public enum MergePolicy: String, Sendable { case record, field }

/// What the user answers to a conflict.
public enum ConflictChoice: String, Sendable, CaseIterable {
    /// This Mac's version (which may be "deleted").
    case keepMine
    /// The place's version (which may be "deleted").
    case keepTheirs
    /// Tasks only, when both sides have one: the place's version stays, this Mac's becomes a second task beside it.
    case keepBoth
}

/// Why a record is in conflict.
public enum ConflictReason: String, Sendable {
    /// Both sides changed it, differently.
    case bothChanged
    /// Both sides added it (the same id), differently. Also the first sync with a place that already holds the same board.
    case bothAdded
    /// Deleted on this Mac, changed on the place.
    case deletedHere
    /// Deleted on the place, changed on this Mac.
    case deletedThere
}

/// An answer to one conflict, remembered until the sync that applies it. It applies only while both versions are still the
/// ones the user saw.
struct ConflictResolution: Sendable {
    var choice: ConflictChoice
    var mine: String
    var theirs: String
    /// The id of this Mac's copy, for `.keepBoth`.
    var copyID: String?
}

/// A record conflict before it is turned into something to show.
struct RecordConflict<R: BoardRecordType> {
    var key: String
    var id: String
    var reason: ConflictReason
    var base: R?
    var mine: R?
    var theirs: R?
}

enum Side { case mine, theirs }

/// The stable text of a record (or of its absence), for comparing what the user saw with what is there now.
func digest<R: Encodable>(_ record: R?) -> String {
    guard let record else { return "deleted" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
}

/// The key of a conflict: where it is and which record.
func conflictKey(scope: String, kind: String, id: String) -> String { "\(scope)|\(kind)|\(id)" }

struct RecordMerge<R: BoardRecordType> {
    var records: [R]
    var conflicts: [RecordConflict<R>]
    /// Records that only a resolution created (this Mac's copy of a "keep both").
    var copies: [R] = []
}

/// Merges one kind of record. `touched(id, side)`: whether that side changed something that belongs to the record but lives
/// elsewhere (a task's comments) — such a record is not "unchanged", so a delete on the other side is asked about.
func mergeRecords<R: BoardRecordType>(
    scope: String, kind: String, base: [R], mine: [R], theirs: [R], policy: MergePolicy,
    resolutions: [String: ConflictResolution], touched: (String, Side) -> Bool = { _, _ in false }
) -> RecordMerge<R> {
    let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let mineByID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let theirsByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var order: [String] = []
    var listed = Set<String>()
    for id in mine.map(\.id) + theirs.map(\.id) + base.map(\.id) where listed.insert(id).inserted { order.append(id) }

    var result = RecordMerge<R>(records: [], conflicts: [])
    for id in order {
        let was = baseByID[id]
        let my = mineByID[id]
        let their = theirsByID[id]
        func keep(_ record: R?) { if let record { result.records.append(record) } }
        func ask(_ reason: ConflictReason) {
            let key = conflictKey(scope: scope, kind: kind, id: id)
            if let answer = resolutions[key], answer.mine == digest(my), answer.theirs == digest(their) {
                switch answer.choice {
                case .keepMine: keep(my)
                case .keepTheirs: keep(their)
                case .keepBoth:
                    keep(their)
                    if var copy = my, their != nil, let copyID = answer.copyID {
                        copy.id = copyID
                        result.copies.append(copy)
                        result.records.append(copy)
                    } else if their == nil {
                        keep(my)
                    }
                }
                return
            }
            result.conflicts.append(RecordConflict(key: key, id: id, reason: reason, base: was, mine: my, theirs: their))
            // Until it is answered the board is not written; the record stays out of the merged result's decisions.
            keep(their ?? my)
        }
        switch (my, their) {
        case (nil, nil):
            continue
        case (let m?, let t?) where m.sameContent(as: t):
            keep(m.updatedAt >= t.updatedAt ? m : t)
        case (let m?, nil):
            guard let was else { keep(m); continue }                                    // added here
            if m.sameContent(as: was), !touched(id, .mine) { continue }                 // deleted there, unchanged here
            ask(.deletedThere)
        case (nil, let t?):
            guard let was else { keep(t); continue }                                    // added there
            if t.sameContent(as: was), !touched(id, .theirs) { continue }               // deleted here, unchanged there
            ask(.deletedHere)
        case (let m?, let t?):
            guard let was else { ask(.bothAdded); continue }
            if m.sameContent(as: was) { keep(t); continue }
            if t.sameContent(as: was) { keep(m); continue }
            if policy == .field, let merged = fieldMerge(base: was, mine: m, theirs: t) { keep(merged); continue }
            ask(.bothChanged)
        }
    }
    return result
}

/// Field by field: each field takes the side that changed it; nil when both changed one field differently.
private func fieldMerge<R: BoardRecordType>(base: R, mine: R, theirs: R) -> R? {
    guard let b = (try? JSONValue(encoding: base))?.objectValue, let m = (try? JSONValue(encoding: mine))?.objectValue,
        let t = (try? JSONValue(encoding: theirs))?.objectValue
    else { return nil }
    var merged: [String: JSONValue] = [:]
    for key in Set(b.keys).union(m.keys).union(t.keys) where key != "updatedAt" {
        let (x, y, z) = (b[key], m[key], t[key])
        let value: JSONValue?
        if y == z { value = y } else if y == x { value = z } else if z == x { value = y } else { return nil }
        if let value { merged[key] = value }
    }
    merged["updatedAt"] = .string(max(mine.updatedAt, theirs.updatedAt))
    return try? JSONValue.object(merged).decode(R.self)
}

// MARK: - A board file

struct BoardMerge {
    var file: BoardFile
    var columns: [RecordConflict<ColumnRecord>] = []
    var tasks: [RecordConflict<TaskRecord>] = []
    var tags: [RecordConflict<TagRecord>] = []
    var comments: [RecordConflict<CommentRecord>] = []
    var hasConflicts: Bool { !(columns.isEmpty && tasks.isEmpty && tags.isEmpty && comments.isEmpty) }
}

/// Merges one board's file. With no conflicts the result is also made whole again: a task whose column was deleted on the
/// other side moves to the first column (never dropped), tags that no longer exist are taken off tasks, and comments of a
/// task that is gone go with it.
func mergeBoard(
    id: String, base: BoardFile?, mine: BoardFile, theirs: BoardFile, policy: MergePolicy, resolutions: [String: ConflictResolution],
    now: String
) -> BoardMerge {
    let base = base ?? BoardFile(board: id)
    func commentsByTask(_ file: BoardFile) -> [String: Set<String>] {
        Dictionary(grouping: file.comments, by: \.task).mapValues { Set($0.map { digest($0) }) }
    }
    let baseComments = commentsByTask(base)
    let mineComments = commentsByTask(mine)
    let theirsComments = commentsByTask(theirs)
    let columns = mergeRecords(scope: id, kind: "column", base: base.columns, mine: mine.columns, theirs: theirs.columns, policy: policy, resolutions: resolutions)
    let tags = mergeRecords(scope: id, kind: "tag", base: base.tags, mine: mine.tags, theirs: theirs.tags, policy: policy, resolutions: resolutions)
    let tasks = mergeRecords(
        scope: id, kind: "task", base: base.tasks, mine: mine.tasks, theirs: theirs.tasks, policy: policy, resolutions: resolutions
    ) { task, side in
        (side == .mine ? mineComments[task] : theirsComments[task]) != baseComments[task]
    }
    let comments = mergeRecords(scope: id, kind: "comment", base: base.comments, mine: mine.comments, theirs: theirs.comments, policy: policy, resolutions: resolutions)
    var result = BoardMerge(
        file: BoardFile(board: id, columns: columns.records, tasks: tasks.records, tags: tags.records, comments: comments.records),
        columns: columns.conflicts, tasks: tasks.conflicts, tags: tags.conflicts, comments: comments.conflicts)
    if !result.hasConflicts {
        result.file = repaired(result.file, now: now)
    }
    result.file = result.file.normalized()
    return result
}

/// The board made whole: every task in a column that exists, every tag on a task one that exists, every comment on a task
/// that exists. Only what is broken changes.
func repaired(_ file: BoardFile, now: String) -> BoardFile {
    var file = file.normalized()
    let columnIDs = Set(file.columns.map(\.id))
    if file.tasks.contains(where: { !columnIDs.contains($0.column) }) {
        if file.columns.isEmpty {
            // Every column was deleted on one side while the other still had tasks: they are kept in a column of their own.
            let recovered = "c-recovered"
            file.columns.append(ColumnRecord(id: recovered, title: "Recovered", role: Role.neutral.rawValue, rank: Rank.between(nil, nil), updatedAt: now))
        }
        let first = file.columns[0].id
        var last = file.tasks.filter { $0.column == first }.map(\.rank).max()
        for index in file.tasks.indices where !columnIDs.contains(file.tasks[index].column) {
            let rank = Rank.between(last, nil)
            file.tasks[index].column = first
            file.tasks[index].rank = rank
            file.tasks[index].updatedAt = now
            last = rank
        }
    }
    let tagIDs = Set(file.tags.map(\.id))
    for index in file.tasks.indices where file.tasks[index].tags.contains(where: { !tagIDs.contains($0) }) {
        file.tasks[index].tags.removeAll { !tagIDs.contains($0) }
        file.tasks[index].updatedAt = now
    }
    let taskIDs = Set(file.tasks.map(\.id))
    file.comments.removeAll { !taskIDs.contains($0.task) }
    return file.normalized()
}

/// Merges the index (the list of boards).
func mergeIndex(base: BoardIndexFile?, mine: BoardIndexFile, theirs: BoardIndexFile, policy: MergePolicy, resolutions: [String: ConflictResolution])
    -> RecordMerge<BoardRecord>
{
    mergeRecords(scope: "index", kind: "board", base: base?.boards ?? [], mine: mine.boards, theirs: theirs.boards, policy: policy, resolutions: resolutions)
}

