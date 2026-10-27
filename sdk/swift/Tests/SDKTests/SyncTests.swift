import Foundation
import VektorPlugin

private func card(_ id: String, _ fields: [String: JSONValue] = [:], _ updatedAt: String = "2026-10-01T10:00:00Z") -> JSONValue {
    var object: [String: JSONValue] = ["id": .string(id), "title": .string(id.uppercased()), "column": "todo", "updatedAt": .string(updatedAt)]
    object.merge(fields) { _, new in new }
    return .object(object)
}

@MainActor
func syncTests() async {
    await test("sync: nothing changed anywhere is unchanged") {
        let base = [card("a"), card("b")]
        let result = try threeWayMerge(base: base, mine: base, theirs: base)
        try checkEqual(result.status, .unchanged)
    }

    await test("sync: only one side changed: that side wins") {
        let base = [card("a"), card("b")]
        let mine = [card("a", ["title": "Mine"], "2026-10-02T00:00:00Z"), card("b")]
        let theirs = [card("a"), card("b", ["column": "done"], "2026-10-03T00:00:00Z")]
        let result = try threeWayMerge(base: base, mine: mine, theirs: theirs)
        try checkEqual(result.status, .merged)
        try checkEqual(result.records, [mine[0], theirs[1]])
        try check(result.changedMine && result.changedTheirs)
    }

    await test("sync: both added the same id differently is a bothAdded conflict; identically is none") {
        let result = try threeWayMerge(base: [], mine: [card("n", ["title": "Mine"])], theirs: [card("n", ["title": "Theirs"], "2026-10-05T00:00:00Z")])
        try checkEqual(result.status, .conflicts)
        try checkEqual(result.conflicts.map(\.kind), [.bothAdded])
        try checkEqual(result.conflicts[0].newer, .theirs)
        try checkEqual(result.records, [card("n", ["title": "Theirs"], "2026-10-05T00:00:00Z")])
        try checkEqual(try threeWayMerge(base: [], mine: [card("n")], theirs: [card("n")]).status, .unchanged)
    }

    await test("sync: both changed the same field differently is bothChanged, naming the field") {
        let result = try threeWayMerge(base: [card("a")], mine: [card("a", ["title": "Mine"], "2026-10-02T00:00:00Z")],
                                       theirs: [card("a", ["title": "Theirs"], "2026-10-03T00:00:00Z")])
        try checkEqual(result.conflicts.map(\.kind), [.bothChanged])
        try checkEqual(result.conflicts[0].fields, ["title"])
    }

    await test("sync: both changed different fields are merged field by field, the newer stamp kept") {
        let result = try threeWayMerge(base: [card("a")], mine: [card("a", ["title": "Mine"], "2026-10-02T00:00:00Z")],
                                       theirs: [card("a", ["column": "done"], "2026-10-03T00:00:00Z")])
        try checkEqual(result.status, .merged)
        try checkEqual(result.records, [["id": "a", "title": "Mine", "column": "done", "updatedAt": "2026-10-03T00:00:00Z"]])
    }

    await test("sync: deleted on one side while changed on the other") {
        let base = [card("a"), card("b")]
        let result = try threeWayMerge(base: base, mine: [card("b", ["title": "Changed here"])], theirs: [card("a", ["title": "Changed there"])])
        try checkEqual(Set(result.conflicts.map { "\($0.id) \($0.kind)" }), ["a deletedByMe", "b deletedByThem"])
        try check(result.conflicts.first { $0.id == "a" }?.mine == nil)
    }

    await test("sync: a delete of an untouched record is taken") {
        let result = try threeWayMerge(base: [card("a"), card("b")], mine: [card("a")], theirs: [card("a"), card("b")])
        try checkEqual(result.status, .merged)
        try checkEqual(result.records.compactMap { $0["id"]?.stringValue }, ["a"])
        try check(result.changedTheirs && !result.changedMine)
    }

    await test("sync: base missing — additions taken, different copies conflict") {
        let result = try threeWayMerge(base: nil, mine: [card("m"), card("same"), card("x", ["title": "Mine"])],
                                       theirs: [card("t"), card("same"), card("x", ["title": "Theirs"])])
        try checkEqual(result.records.compactMap { $0["id"]?.stringValue }, ["m", "same", "x", "t"])
        try checkEqual(result.conflicts.map { "\($0.id) \($0.kind)" }, ["x bothAdded"])
    }

    await test("sync: Codable records, and refusals for records without ids") {
        struct Card: Codable, Equatable { var id: String; var title: String }
        let merged = try threeWayMerge(base: [Card(id: "a", title: "A")], mine: [Card(id: "a", title: "A2")], theirs: [Card(id: "a", title: "A"), Card(id: "b", title: "B")])
        try checkEqual(merged.records, [Card(id: "a", title: "A2"), Card(id: "b", title: "B")])
        try checkThrows({ _ = try threeWayMerge(base: [], mine: [["title": "no id"]], theirs: []) }, matching: "needs a text “id”")
        try checkThrows({ _ = try threeWayMerge(base: [], mine: [card("a"), card("a")], theirs: []) }, matching: "twice")
    }

    await test("sync: a field-by-field merge keeps the ignored fields (as mine has them)") {
        let result = try threeWayMerge(base: [card("a", ["local": "X"])], mine: [card("a", ["local": "X", "title": "Mine"], "2026-10-02T00:00:00Z")],
                                       theirs: [card("a", ["local": "X", "column": "done"], "2026-10-03T00:00:00Z")], ignore: ["local"])
        try checkEqual(result.status, .merged)
        try checkEqual(result.records, [["id": "a", "title": "Mine", "column": "done", "local": "X", "updatedAt": "2026-10-03T00:00:00Z"]])
    }

    await test("sync: a field named __proto__ is merged like any other") {
        let result = try threeWayMerge(base: [["id": "a", "x": 1, "__proto__": ["k": 1]]], mine: [["id": "a", "x": 2, "__proto__": ["k": 1]]],
                                       theirs: [["id": "a", "x": 1, "__proto__": ["k": 2]]])
        try checkEqual(result.status, .merged)
        try checkEqual(result.records, [["id": "a", "x": 2, "__proto__": ["k": 2]]])
    }

    await test("sync: updatedAt — a number is milliseconds since 1970; text only an ISO 8601 date-time; anything else is no stamp") {
        func newer(_ mine: JSONValue, _ theirs: JSONValue) throws -> SyncConflict.Side? {
            try threeWayMerge(base: nil, mine: [["id": "a", "v": 1, "updatedAt": mine]], theirs: [["id": "a", "v": 2, "updatedAt": theirs]]).conflicts[0].newer
        }
        try checkEqual(try newer(1792575995, "2026-01-01T00:00:00Z"), .theirs, "1792575995 ms is in January 1970")
        try checkEqual(try newer(1792575995000, "2026-01-01T00:00:00Z"), .mine)
        try checkEqual(try newer("2026-10-23T12:00:00.5+02:00", "2026-10-23T10:00:00.4Z"), .mine, "fractional seconds and an offset")
        try checkEqual(try newer("2026-10-23T10:00:00.0019Z", "2026-10-23T10:00:00.001Z"), nil, "milliseconds are the precision")
        try checkEqual(try newer("2026-01-01T00:00:00.001Z", 1767225600000), .mine)
        let notStamps: [JSONValue] = ["2026-10-24", "2026-02-30T00:00:00Z", "2026-10-23T24:00:00Z", "Fri, 23 Oct 2026 10:00:00 GMT", "1", "", true, .null]
        for notAStamp in notStamps { try checkEqual(try newer(notAStamp, "2026-10-23T10:00:00Z"), nil, "\(notAStamp)") }
    }

    await test("sync: with conflicts open, records hold what loses nothing on the place — theirs where they have it, else mine (never a delete)") {
        let base = [card("changed"), card("mineGone"), card("theirsGone")]
        let mine = [card("changed", ["title": "Mine"]), card("theirsGone", ["title": "Changed here"])]
        let theirs = [card("changed", ["title": "Theirs"]), card("mineGone", ["title": "Changed there"])]
        let result = try threeWayMerge(base: base, mine: mine, theirs: theirs)
        try checkEqual(result.status, .conflicts)
        try checkEqual(result.records, [theirs[0], mine[1], theirs[1]])
    }

    await test("sync: a change only to an ignored field, while the other side deleted the record, is a conflict too (not a silent delete)") {
        let base = [card("a", ["note": "x"]), card("b", ["note": "x"])]
        let result = try threeWayMerge(base: base, mine: [card("a", ["note": "Changed here"])], theirs: [card("b", ["note": "Changed there"])], ignore: ["note"])
        try checkEqual(result.conflicts.map { "\($0.id) \($0.kind)" }, ["a deletedByThem", "b deletedByMe"])
        let touched = try threeWayMerge(base: base, mine: [card("a", ["note": "x"], "2026-10-09T00:00:00Z"), base[1]], theirs: [base[1]], ignore: ["note"])
        try checkEqual(touched.status, .merged, "a new updatedAt alone is no change: the delete is taken")
    }
}
