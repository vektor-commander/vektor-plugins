import Foundation

// Three-way sync of records: what both sides last agreed on (base), what this Mac has (mine) and what the place has now
// (theirs). Records are matched by a stable `id`; `updatedAt` says which side changed one last. The result says what to
// keep — it never decides a real conflict for you: those are reported, and resolving them (ask the user, keep the newer,
// keep both) is the plugin's choice.
//
// Per record:
//   only one side changed it (or added it, or deleted it) → that side's version is taken;
//   both made the same change                              → taken, no conflict;
//   both changed it, different fields                      → merged field by field;
//   both changed the same field differently                → conflict (.bothChanged, with the fields);
//   both added it with different content                   → conflict (.bothAdded);
//   one deleted it, the other changed it                   → conflict (.deletedByMe / .deletedByThem).
//     (here a change to an ignored field counts too: the delete would throw it away)
// With no base at all (the first sync), every record both sides hold differently is a .bothAdded conflict.
//
// While a conflict is open, its record in `records` is theirs' version (mine's when they deleted it): writing `records` to the
// place then loses nothing there, and a record either side still has is never dropped. Mine's version is only in the
// conflict, so resolve every conflict before you write `records` anywhere.
//
// Records are JSON objects with a text `id` (and optionally `updatedAt`: milliseconds since 1970, or ISO 8601 date-time text — see `syncStamp`). For your own Codable type, convert
// with `JSONValue(encoding:)` and `decode`.

public struct SyncConflict: Equatable, Sendable {
    public enum Kind: String, Sendable { case bothChanged, bothAdded, deletedByMe, deletedByThem }
    public var id: String
    public var kind: Kind
    public var base: JSONValue?
    /// nil when this side deleted it.
    public var mine: JSONValue?
    public var theirs: JSONValue?
    /// For `.bothChanged`: the fields both sides changed differently.
    public var fields: [String]
    /// Which side changed it last by `updatedAt`, when both have one and they differ — a hint, not a decision.
    public var newer: Side?
    public enum Side: String, Sendable { case mine, theirs }
}

public struct SyncResult: Equatable, Sendable {
    public enum Status: String, Sendable { case unchanged, merged, conflicts }
    /// `.unchanged`: both sides already agree. `.merged`: no conflicts, `records` is the agreed set. `.conflicts`: see them.
    public var status: Status
    /// Every record, in mine's order with theirs' new ones after. **Do not write them while `conflicts` is not empty**: resolve
    /// each conflict first (put the version you chose in its place). Until then a conflicting record holds theirs' version, or
    /// mine's when they deleted it — what loses nothing on the place; mine's own version is only in `conflict.mine`.
    public var records: [JSONValue]
    public var conflicts: [SyncConflict]
    /// Whether `records` differs from mine (your local copy needs updating) and from theirs (the place needs writing).
    public var changedMine: Bool
    public var changedTheirs: Bool
}

/// `updatedAt` as milliseconds since 1970, read the same way in every SDK: a number is milliseconds since 1970 (JavaScript's
/// `Date.now()`, so Node and Swift plugins can share a file); text is an ISO 8601 date-time ("2026-10-23T10:00:00Z", optional
/// fractional seconds, "Z" or an offset), read to the millisecond. Anything else — a date without a time, another format, an
/// impossible date — is no stamp (nil), never a guess.
func syncStamp(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let number)?: return number.isFinite ? number : nil
    case .string(let text)?: return isoDateTimeMilliseconds(text)
    default: return nil
    }
}

private let isoDateTime = try! NSRegularExpression(
    pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:Z|([+-])(\d{2}):(\d{2}))$"#)

// Not ISO8601DateFormatter: its fractional seconds are all-or-nothing, and the result must match the Node SDK's to the
// millisecond. Plain arithmetic does.
private func isoDateTimeMilliseconds(_ text: String) -> Double? {
    guard let match = isoDateTime.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
    let numbers = (1...6).map { Int(group($0)!)! }
    let (year, month, day, hour, minute, second) = (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5])
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...12).contains(month), (1...monthDays[month - 1]).contains(day), hour <= 23, minute <= 59, second <= 59 else { return nil }
    let (offsetHours, offsetMinutes) = (Int(group(9) ?? "0")!, Int(group(10) ?? "0")!)
    guard offsetHours <= 23, offsetMinutes <= 59 else { return nil }
    let offset = (group(8) == "-" ? -1 : 1) * (offsetHours * 60 + offsetMinutes)
    let fraction = String((group(7) ?? "").prefix(3))
    let milliseconds = Int(fraction + String(repeating: "0", count: 3 - fraction.count))!
    let minutes = (daysSince1970(year, month, day) * 24 + hour) * 60 + minute - offset
    return Double(minutes) * 60_000 + Double(second * 1000 + milliseconds)
}

// Days from 1970-01-01 to a Gregorian date (Howard Hinnant's days_from_civil): plain arithmetic, the same in the Node SDK.
private func daysSince1970(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146097 + dayOfEra - 719468
}

/// Compares `mine` and `theirs` against `base` (nil: there is no base yet). Throws for a record without a text `id`, or an
/// id held twice by one side. `ignore`: fields never compared (besides `updatedAt`, which only says when).
public func threeWayMerge(base: [JSONValue]?, mine: [JSONValue], theirs: [JSONValue], ignore: Set<String> = []) throws -> SyncResult {
    let ignored = ignore.union(["id", "updatedAt"])
    func byID(_ records: [JSONValue], _ side: String) throws -> (map: [String: [String: JSONValue]], order: [String]) {
        var map: [String: [String: JSONValue]] = [:]
        var order: [String] = []
        for record in records {
            guard let object = record.objectValue, let id = object["id"]?.stringValue, !id.isEmpty else {
                throw PluginError("Every record of \(side) needs a text “id”.")
            }
            guard map[id] == nil else { throw PluginError("\(side) holds the record “\(id)” twice.") }
            map[id] = object
            order.append(id)
        }
        return (map, order)
    }
    let b = try byID(base ?? [], "base")
    let m = try byID(mine, "mine")
    let t = try byID(theirs, "theirs")
    func content(_ record: [String: JSONValue]) -> [String: JSONValue] { record.filter { !ignored.contains($0.key) } }
    func same(_ x: [String: JSONValue]?, _ y: [String: JSONValue]?) -> Bool {
        guard let x, let y else { return x == nil && y == nil }
        return content(x) == content(y)
    }
    // Whether a record is as the base had it, ignored fields included: a delete on the other side is taken only then, because
    // a change to an ignored field is still a change, and the delete would throw it away. A new `updatedAt` alone is none.
    func untouched(_ x: [String: JSONValue], _ was: [String: JSONValue]) -> Bool {
        x.filter { $0.key != "updatedAt" } == was.filter { $0.key != "updatedAt" }
    }
    func newer(_ x: [String: JSONValue]?, _ y: [String: JSONValue]?) -> SyncConflict.Side? {
        guard let a = syncStamp(x?["updatedAt"]), let c = syncStamp(y?["updatedAt"]), a != c else { return nil }
        return a > c ? .mine : .theirs
    }
    func later(_ x: [String: JSONValue], _ y: [String: JSONValue]) -> [String: JSONValue] { newer(x, y) == .theirs ? y : x }

    let order = m.order + t.order.filter { m.map[$0] == nil } + b.order.filter { m.map[$0] == nil && t.map[$0] == nil }
    var settled: [String: [String: JSONValue]?] = [:]
    var conflicts: [SyncConflict] = []

    for id in order {
        let was = b.map[id]
        let my = m.map[id]
        let their = t.map[id]
        func conflict(_ kind: SyncConflict.Kind, _ fields: [String] = []) {
            conflicts.append(SyncConflict(
                id: id, kind: kind, base: was.map(JSONValue.object), mine: my.map(JSONValue.object), theirs: their.map(JSONValue.object),
                fields: fields, newer: newer(my, their)))
            // Theirs' version, so that writing these records by mistake overwrites nothing on the place (mine is in the
            // conflict); mine's when they deleted it, so that a record changed here is not dropped.
            settled[id] = .some(their ?? my)
        }
        switch (my, their) {
        case (let my?, let their?):
            if same(my, their) { settled[id] = .some(later(my, their)); continue }
            guard let was else { conflict(.bothAdded); continue }
            if same(my, was) { settled[id] = .some(their); continue }
            if same(their, was) { settled[id] = .some(my); continue }
            let fields = Set(was.keys).union(my.keys).union(their.keys).subtracting(ignored)
            // Ignored fields are never compared, so they are not merged either: they stay as mine has them, or a merge would
            // drop them from the record. `updatedAt` is set below, from the side that changed it last.
            var merged = my.filter { ignored.contains($0.key) && $0.key != "updatedAt" }
            var clashes: [String] = []
            for field in fields {
                let (x, y, z) = (was[field], my[field], their[field])
                let value: JSONValue?
                if y == z { value = y } else if y == x { value = z } else if z == x { value = y } else {
                    clashes.append(field)
                    value = y
                }
                if let value { merged[field] = value }
            }
            if !clashes.isEmpty { conflict(.bothChanged, clashes.sorted()); continue }
            if let stampValue = later(my, their)["updatedAt"] { merged["updatedAt"] = stampValue }
            settled[id] = .some(merged)
        case (let my?, nil):
            guard let was else { settled[id] = .some(my); continue }                                  // added here
            if untouched(my, was) { settled[id] = .some(nil) } else { conflict(.deletedByThem) }      // deleted there
        case (nil, let their?):
            guard let was else { settled[id] = .some(their); continue }                               // added there
            if untouched(their, was) { settled[id] = .some(nil) } else { conflict(.deletedByMe) }     // deleted here
        case (nil, nil):
            settled[id] = .some(nil)
        }
    }

    let records: [[String: JSONValue]] = order.compactMap { settled[$0] ?? nil }
    func differs(_ side: [String: [String: JSONValue]]) -> Bool {
        records.count != side.count || records.contains { record in side[record["id"]!.stringValue!] != record }
    }
    let changedMine = differs(m.map)
    let changedTheirs = differs(t.map)
    let status: SyncResult.Status = !conflicts.isEmpty ? .conflicts : (!changedMine && !changedTheirs ? .unchanged : .merged)
    return SyncResult(status: status, records: records.map(JSONValue.object), conflicts: conflicts, changedMine: changedMine, changedTheirs: changedTheirs)
}

/// `threeWayMerge` for your own Codable records (each encodes an `id`, and optionally `updatedAt`).
public func threeWayMerge<R: Codable>(base: [R]?, mine: [R], theirs: [R], ignore: Set<String> = []) throws -> (result: SyncResult, records: [R]) {
    let result = try threeWayMerge(
        base: try base?.map { try JSONValue(encoding: $0) }, mine: try mine.map { try JSONValue(encoding: $0) },
        theirs: try theirs.map { try JSONValue(encoding: $0) }, ignore: ignore)
    return (result, try result.records.map { try $0.decode(R.self) })
}
