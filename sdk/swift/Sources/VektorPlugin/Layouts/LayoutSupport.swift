import Foundation

// Shared by the layouts. Read this first: every layout names its blocks and actions the same way.
//
// A layout draws blocks and, separately, routes the events those blocks cause. The two meet in names:
//
//   * every block id and every action starts with the layout's own `id` (default: the layout's name), so two layouts in one
//     view never collide;
//   * the part after the prefix says what the block is: `board.add.todo` is the "+" button of the column `todo`;
//   * routing reads that part back, so the plugin only ever sees the ids IT chose (a column id, a card id).
//
// Every container that holds changing content has an id too (even a scroll): the SDK patches a view by id. It looks inside
// a block without one, but when such a block's own fields change it must replace the nearest block above that has an id.
//
// Nothing here is clever on purpose. Copy a layout into your plugin and rename things; this file goes with it.

/// Names blocks and actions of one layout: `Names("board").id("add", "todo")` is `board.add.todo`.
public struct LayoutNames: Sendable {
    public let prefix: String
    public init(_ prefix: String) { self.prefix = prefix }

    /// `prefix.part.part…`
    public func id(_ parts: String...) -> String { ([prefix] + parts).joined(separator: ".") }

    /// The part of `value` after `prefix.kind.` — or nil when `value` is not of that kind.
    public func rest(_ kind: String, of value: String?) -> String? {
        guard let value else { return nil }
        let start = "\(prefix).\(kind)."
        guard value.hasPrefix(start), value.count > start.count else { return nil }
        return String(value.dropFirst(start.count))
    }
}

/// The block with this id in what `view` described last (with any patches since), or nil.
@MainActor
func describedBlock(_ id: String, in view: ViewState) -> Block? {
    func find(_ block: Block) -> Block? { block.id == id ? block : block.children?.lazy.compactMap(find).first }
    return view.description?.blocks?.lazy.compactMap(find).first
}

/// Case-insensitive "contains", the way a search box means it. An empty query matches everything.
func layoutMatches(_ query: String?, _ fields: String?...) -> Bool {
    layoutMatches(query, fields)
}

func layoutMatches(_ query: String?, _ fields: [String?]) -> Bool {
    let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return needle.isEmpty || fields.contains { ($0 ?? "").lowercased().contains(needle) }
}

/// The handler types the layouts use: they run on the main actor, may be async, and may throw (the SDK reports a throw in the log).
/// The whole event, and whether it was made against an older description, is `ViewEvent.current` while one runs.
public typealias LayoutAction<A> = @MainActor (A) async throws -> Void
public typealias LayoutAction2<A, B> = @MainActor (A, B) async throws -> Void
public typealias LayoutAction3<A, B, C> = @MainActor (A, B, C) async throws -> Void
