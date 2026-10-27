import Foundation

// View descriptions, patches and the view state helper.
//
// A view is described as data with `view/update` (the whole description) or, for a block view, changed by id with
// `view/patch`. `ViewState` keeps what was last sent and its revision, so the plugin only says what the view should look
// like now: `show(_:)` sends a patch when one says it (block views with the same header, toolbar, banner and empty state)
// and the whole description otherwise. It also routes `view/event`s to handlers by action and recognises events made
// against an older revision.

// MARK: - Descriptions

public struct Header: Equatable, Sendable {
    public var title: String?
    public var primary: (title: String, symbol: String?, action: String)?
    public var search: Bool?
    public init(title: String? = nil, primary: (title: String, symbol: String?, action: String)? = nil, search: Bool? = nil) {
        self.title = title
        self.primary = primary
        self.search = search
    }
    public static func == (a: Header, b: Header) -> Bool { a.json == b.json }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("title", title)
        if let primary {
            var button = JSONFields()
            button.set("title", primary.title)
            button.set("symbol", primary.symbol)
            button.set("action", primary.action)
            fields["primary"] = .object(button.object)
        }
        fields.set("search", search)
        return .object(fields.object)
    }
}

public struct BannerNote: Equatable, Sendable {
    public var text: String
    public var tone: Tone?
    public var symbol: String?
    public var linkTitle: String?
    public var link: String?
    public init(_ text: String, tone: Tone? = nil, symbol: String? = nil, linkTitle: String? = nil, link: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
        self.linkTitle = linkTitle
        self.link = link
    }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("text", text)
        fields.set("tone", tone?.rawValue)
        fields.set("symbol", symbol)
        fields.set("linkTitle", linkTitle)
        fields.set("link", link)
        return .object(fields.object)
    }
}

public struct Toolbar: Equatable, Sendable {
    public var buttons: [Control]
    public var search: (placeholder: String?, action: String?)?
    public var message: String?
    public init(buttons: [Control] = [], search: (placeholder: String?, action: String?)? = nil, message: String? = nil) {
        self.buttons = buttons
        self.search = search
        self.message = message
    }
    public static func == (a: Toolbar, b: Toolbar) -> Bool { a.json == b.json }
    public var json: JSONValue {
        var fields = JSONFields()
        if !buttons.isEmpty { fields["buttons"] = .array(buttons.map(\.json)) }
        if let search {
            var object = JSONFields()
            object.set("placeholder", search.placeholder)
            object.set("action", search.action)
            fields["search"] = .object(object.object)
        }
        fields.set("message", message)
        return .object(fields.object)
    }
}

public struct EmptyState: Equatable, Sendable {
    public var title: String
    public var message: String?
    public var symbol: String?
    public var button: (title: String, action: String)?
    public init(title: String, message: String? = nil, symbol: String? = nil, button: (title: String, action: String)? = nil) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.button = button
    }
    public static func == (a: EmptyState, b: EmptyState) -> Bool { a.json == b.json }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("title", title)
        fields.set("message", message)
        fields.set("symbol", symbol)
        if let button { fields["button"] = ["title": .string(button.title), "action": .string(button.action)] }
        return .object(fields.object)
    }
}

/// A view's description. `revision` is filled in by `ViewState`. The API 1 kinds (`cards`, `list`, `form`, `detail`) go into
/// `other` as JSON, exactly as the reference shows them.
public struct ViewDescription: Equatable, Sendable {
    public var header: Header?
    public var banner: BannerNote?
    public var toolbar: Toolbar?
    public var empty: EmptyState?
    /// A block view (API 2): one root block, or several read as a vertical stack.
    public var blocks: [Block]?
    public var blocksAsList: Bool
    /// Any other field of the description (`cards`, `list`, `form`, `detail`, or one this SDK does not type yet).
    public var other: [String: JSONValue]

    public init(header: Header? = nil, banner: BannerNote? = nil, toolbar: Toolbar? = nil, empty: EmptyState? = nil, other: [String: JSONValue] = [:]) {
        self.header = header
        self.banner = banner
        self.toolbar = toolbar
        self.empty = empty
        self.blocks = nil
        self.blocksAsList = false
        self.other = other
    }

    /// A block view with one root block.
    public init(header: Header? = nil, banner: BannerNote? = nil, toolbar: Toolbar? = nil, empty: EmptyState? = nil, root: Block) {
        self.init(header: header, banner: banner, toolbar: toolbar, empty: empty)
        blocks = [root]
    }

    /// A block view whose blocks are a list (read as a vertical stack without an id).
    public init(header: Header? = nil, banner: BannerNote? = nil, toolbar: Toolbar? = nil, empty: EmptyState? = nil, blocks: [Block]) {
        self.init(header: header, banner: banner, toolbar: toolbar, empty: empty)
        self.blocks = blocks
        blocksAsList = true
    }

    /// The `blocks` field as sent.
    public var blocksJSON: JSONValue? {
        guard let blocks else { return nil }
        return blocksAsList ? .array(blocks.map(\.json)) : blocks.first?.json
    }

    /// The description as JSON, with `revision`.
    public func json(revision: Int?) -> JSONValue {
        var object = other
        if let revision { object["revision"] = .int(revision) }
        if let header { object["header"] = header.json }
        if let banner { object["banner"] = banner.json }
        if let toolbar { object["toolbar"] = toolbar.json }
        if let empty { object["empty"] = empty.json }
        if let blocksJSON { object["blocks"] = blocksJSON }
        return .object(object)
    }
}

// MARK: - Patches

/// One operation of `view/patch`.
public enum PatchOperation: Equatable, Sendable {
    case replace(id: String, block: JSONValue)
    case insert(parent: String, index: Int?, block: JSONValue)
    case remove(id: String)
    case move(id: String, parent: String, index: Int?)

    public var json: JSONValue {
        switch self {
        case .replace(let id, let block): return ["op": "replace", "id": .string(id), "block": block]
        case .insert(let parent, let index, let block):
            var object: [String: JSONValue] = ["op": "insert", "parent": .string(parent), "block": block]
            if let index { object["index"] = .int(index) }
            return .object(object)
        case .remove(let id): return ["op": "remove", "id": .string(id)]
        case .move(let id, let parent, let index):
            var object: [String: JSONValue] = ["op": "move", "id": .string(id), "parent": .string(parent)]
            if let index { object["index"] = .int(index) }
            return .object(object)
        }
    }
}

/// A block tree that patches can change in place (by reference, like Vektor's own).
final class TreeNode {
    var type: String
    var fields: [String: JSONValue]
    var children: [TreeNode]?
    weak var parent: TreeNode?

    init(_ value: JSONValue) {
        var object = value.objectValue ?? [:]
        type = object["type"]?.stringValue ?? ""
        let rawChildren = object.removeValue(forKey: "children")
        fields = object
        if let items = rawChildren?.arrayValue {
            children = items.map(TreeNode.init)
            for child in children! { child.parent = self }
        }
    }

    private init(type: String, fields: [String: JSONValue], children: [TreeNode]?) {
        self.type = type
        self.fields = fields
        self.children = children
        for child in children ?? [] { child.parent = self }
    }

    /// A deep copy, not attached anywhere.
    func copy() -> TreeNode { TreeNode(type: type, fields: fields, children: children?.map { $0.copy() }) }

    var id: String? { fields["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var json: JSONValue {
        var object = fields
        object["type"] = .string(type)
        if let children { object["children"] = .array(children.map(\.json)) }
        return .object(object)
    }
    /// The same type and own fields (children not compared).
    func sameOwn(_ other: TreeNode) -> Bool { type == other.type && fields == other.fields }
    /// The same block, children included (what comparing their `json` would say, without building it).
    func same(_ other: TreeNode) -> Bool {
        guard sameOwn(other) else { return false }
        switch (children, other.children) {
        case (nil, nil): return true
        case (let a?, let b?): return a.count == b.count && zip(a, b).allSatisfy { $0.same($1) }
        default: return false
        }
    }

    func find(_ id: String) -> TreeNode? {
        if self.id == id { return self }
        for child in children ?? [] { if let found = child.find(id) { return found } }
        return nil
    }
    func contains(_ node: TreeNode) -> Bool {
        var current: TreeNode? = node
        while let candidate = current {
            if candidate === self { return true }
            current = candidate.parent
        }
        return false
    }
    var index: Int? { parent?.children?.firstIndex { $0 === self } }
    func detach() {
        if let index { parent?.children?.remove(at: index) }
        parent = nil
    }
    func insert(_ child: TreeNode, at index: Int) {
        if children == nil { children = [] }
        children!.insert(child, at: index)
        child.parent = self
    }
    func ids(into set: inout Set<String>) {
        if let id { set.insert(id) }
        for child in children ?? [] { child.ids(into: &set) }
    }
    /// Every block of the subtree, this one first (depth first, in order).
    func visit(_ body: (TreeNode) -> Void) {
        body(self)
        for child in children ?? [] { child.visit(body) }
    }
}

/// The blocks of a tree by id, kept up to date as blocks come and go, so finding one is a lookup instead of a walk of the
/// whole tree (which made comparing two big trees quadratic: minutes for a board of 3,000 cards). A move changes nothing here:
/// the block keeps its id and stays in the tree. A tree that lists an id twice (Vektor refuses one) is searched by walking,
/// so the first in order is found, as before.
final class TreeIndex {
    let root: TreeNode
    private var byID: [String: TreeNode] = [:]
    private(set) var unique = true

    init(_ root: TreeNode) {
        self.root = root
        root.visit { node in
            guard let id = node.id else { return }
            if byID[id] == nil { byID[id] = node } else { unique = false }
        }
    }

    func find(_ id: String) -> TreeNode? { unique ? byID[id] : root.find(id) }
    func contains(_ id: String) -> Bool { find(id) != nil }
    /// A subtree joined the tree.
    func added(_ node: TreeNode) {
        guard unique else { return }
        node.visit { if let id = $0.id { byID[id] = $0 } }
    }
    /// A subtree left the tree.
    func removed(_ node: TreeNode) {
        guard unique else { return }
        node.visit { if let id = $0.id, byID[id] === $0 { byID[id] = nil } }
    }
}

private func asRoot(_ blocks: JSONValue) -> JSONValue {
    blocks.arrayValue.map { ["type": "vstack", "children": .array($0)] } ?? blocks
}

/// Applies patch operations to a block tree the way Vektor does: in order and all or nothing. Returns the new tree or
/// throws a `PluginError` naming the operation that cannot apply.
public func applyPatch(_ blocks: JSONValue, _ operations: [PatchOperation]) throws -> JSONValue {
    let isList = blocks.arrayValue != nil
    let root = TreeNode(asRoot(blocks))
    let tree = TreeIndex(root)
    for (number, operation) in operations.enumerated() {
        let place = "operation \(number + 1)"
        func fail(_ why: String) -> PluginError { PluginError("\(place) \(why)") }
        /// Checks a block about to join the tree; `leaving` is the subtree it replaces (its ids are free again).
        func parse(_ block: JSONValue, leaving: TreeNode?) throws {
            let taken: (String) -> Bool = { id in
                guard let found = tree.find(id) else { return false }
                return !(leaving?.contains(found) ?? false)
            }
            if let problem = validateBlocks(block, taken: taken).problems.first { throw fail(": \(problem)") }
        }
        switch operation {
        case .replace(let id, let block):
            guard let found = tree.find(id) else { throw fail("replaces “\(id)”, which the view does not have.") }
            try parse(block, leaving: found)
            let fresh = TreeNode(block)
            tree.removed(found)
            if let parent = found.parent, let index = found.index {
                parent.children![index] = fresh
                fresh.parent = parent
                tree.added(fresh)
            } else {
                root.type = fresh.type
                root.fields = fresh.fields
                root.children = fresh.children
                for child in root.children ?? [] { child.parent = root }
                tree.added(root)
            }
        case .insert(let parentID, let index, let block):
            guard let parent = tree.find(parentID) else { throw fail("inserts into “\(parentID)”, which the view does not have.") }
            let count = parent.children?.count ?? 0
            let at = index ?? count
            guard at <= count else { throw fail("inserts at \(at), but “\(parentID)” has \(count) children.") }
            try parse(block, leaving: nil)
            if BlockLimits.collections.contains(parent.type), block["id"]?.stringValue == nil {
                throw fail(": every item of “\(parentID)” needs an “id”.")
            }
            let fresh = TreeNode(block)
            parent.insert(fresh, at: at)
            tree.added(fresh)
        case .remove(let id):
            guard let found = tree.find(id), found.parent != nil else { throw fail("removes “\(id)”, which the view does not have (or is its root).") }
            tree.removed(found)
            found.detach()
        case .move(let id, let parentID, let index):
            guard let found = tree.find(id), found.parent != nil else { throw fail("moves “\(id)”, which the view does not have (or is its root).") }
            guard let target = tree.find(parentID) else { throw fail("moves into “\(parentID)”, which the view does not have.") }
            guard !found.contains(target) else { throw fail("moves “\(id)” into itself.") }
            found.detach()
            let count = target.children?.count ?? 0
            let at = index ?? count
            guard at <= count else { throw fail("moves to \(at), but “\(parentID)” has \(count) children once it is out.") }
            target.insert(found, at: at)
        }
    }
    let result = root.json
    return isList ? (result["children"] ?? .array([])) : result
}

/// At most this many operations in one `view/patch` (Vektor's protection limit).
public let maxPatchOperations = 10_000

/// The operations that turn `before` into `after`, by id — or nil when only the whole description can say it (the root
/// changed, or an id moved somewhere a patch cannot express). A block without an id is looked into when its own fields stay
/// the same; when it changes itself, the nearest block above it with an id is replaced. The result is checked: applying it
/// to `before` gives exactly `after`, or nil is returned. Items are matched by id, so keep ids stable.
///
/// Its time grows with the size of the trees, not with its square: blocks are found through an index by id, each container's
/// children are matched through a table of positions, and blocks are compared without building their JSON. A 3,000-card
/// board (some 30,000 blocks) is compared in a fraction of a second.
public func diffBlocks(_ before: JSONValue, _ after: JSONValue) -> [PatchOperation]? {
    let beforeIsList = before.arrayValue != nil
    guard beforeIsList == (after.arrayValue != nil) else { return nil }
    let newRoot = TreeNode(asRoot(after))
    let work = TreeNode(asRoot(before))
    guard work.sameOwn(newRoot) else { return nil }
    let tree = TreeIndex(work)
    var ops: [PatchOperation] = []
    var wanted = Set<String>()
    newRoot.ids(into: &wanted)
    var leftovers: [TreeNode] = []
    func canParent(_ node: TreeNode) -> Bool { node.id != nil && !(node === work && beforeIsList) }
    func collides(_ subtree: TreeNode, except: TreeNode?) -> Bool {
        var hit = false
        subtree.visit { block in
            guard !hit, let id = block.id, let found = tree.find(id) else { return }
            if !(except?.contains(found) ?? false) { hit = true }
        }
        return hit
    }

    // 1. Blocks gone from the new tree (nothing wanted inside) whose parent stays: removed first, so nothing moves to close gaps.
    var holdsWanted = Set<ObjectIdentifier>()
    func markWanted(_ node: TreeNode) -> Bool {
        var holds = node.id.map { wanted.contains($0) } ?? false
        for child in node.children ?? [] where markWanted(child) { holds = true }
        if holds { holdsWanted.insert(ObjectIdentifier(node)) }
        return holds
    }
    _ = markWanted(work)
    var early: [TreeNode] = []
    func scan(_ node: TreeNode) {
        for child in node.children ?? [] {
            if let id = child.id, !wanted.contains(id), let parentID = node.id, wanted.contains(parentID), !holdsWanted.contains(ObjectIdentifier(child)) {
                early.append(child)
            } else {
                scan(child)
            }
        }
    }
    scan(work)
    for found in early where found.parent != nil {
        tree.removed(found)
        found.detach()
        ops.append(.remove(id: found.id!))
    }

    // Where the wanted sibling before position `at` of `next` now is in `node` (its position + 1), or 0.
    func slot(_ node: TreeNode, _ next: [TreeNode], _ at: Int) -> Int {
        var back = at - 1
        while back >= 0 {
            if let id = next[back].id, let sibling = tree.find(id), sibling.parent === node, let position = sibling.index { return position + 1 }
            back -= 1
        }
        return 0
    }
    // Puts `block` into `node` right after the wanted sibling before it.
    func place(_ node: TreeNode, _ next: [TreeNode], _ at: Int, _ block: TreeNode) -> Int {
        let index = slot(node, next, at)
        node.insert(block, at: index)
        return index
    }

    // 2. Blocks that changed parent are moved there.
    func crossMoves(_ target: TreeNode) -> Bool {
        let next = target.children ?? []
        if let targetID = target.id, next.allSatisfy({ $0.id != nil }), let node = tree.find(targetID), canParent(node) {
            for (at, wantedChild) in next.enumerated() {
                guard let found = tree.find(wantedChild.id!), found.parent != nil, found.parent !== node else { continue }
                if found.contains(node) { return false }
                found.detach()
                let index = place(node, next, at, found)
                ops.append(.move(id: wantedChild.id!, parent: targetID, index: index))
            }
        }
        return next.allSatisfy(crossMoves)
    }
    guard crossMoves(newRoot) else { return nil }

    enum Outcome { case ok, replace, fail }

    func settle(_ node: TreeNode, _ index: Int, _ wantedChild: TreeNode) -> Bool {
        let child = node.children![index]
        var outcome = Outcome.replace
        if child.sameOwn(wantedChild) { outcome = reconcile(child, wantedChild) }
        if outcome == .fail { return false }
        if outcome == .replace {
            guard let id = wantedChild.id, !collides(wantedChild, except: child) else { return false }
            let fresh = wantedChild.copy()
            tree.removed(child)
            node.children![index] = fresh
            fresh.parent = node
            tree.added(fresh)
            ops.append(.replace(id: id, block: wantedChild.json))
        }
        return true
    }

    // 3. Each container: the longest run already in order stays; the rest move (or are inserted) after their wanted neighbour.
    func reconcile(_ node: TreeNode, _ target: TreeNode) -> Outcome {
        let next = target.children ?? []
        let current = node.children ?? []
        if current.count == next.count, zip(current, next).allSatisfy({ $0.same($1) }) { return .ok }
        let nextIDs = next.compactMap(\.id)
        let byID = nextIDs.count == next.count && Set(nextIDs).count == next.count
        if !byID || !canParent(node) {
            // A child without an id is "the same block" when its type and own fields match: it is reconciled in turn, so a
            // change below an id-less scroll still patches the nearest block with an id. When that cannot be said, this block
            // is replaced whole (or, at the root, the whole description is sent).
            let sameShape = current.count == next.count && zip(current, next).allSatisfy { have, want in
                want.id != nil ? have.id == want.id : (have.id == nil && have.sameOwn(want))
            }
            guard sameShape else { return node.id != nil && node !== work ? .replace : .fail }
            for (index, wantedChild) in next.enumerated() {
                if wantedChild.id != nil {
                    if !settle(node, index, wantedChild) { return .fail }
                } else if !current[index].same(wantedChild), reconcile(current[index], wantedChild) != .ok {
                    return node.id != nil && node !== work ? .replace : .fail
                }
            }
            return .ok
        }
        var rank: [String: Int] = [:]
        for (index, id) in nextIDs.enumerated() { rank[id] = index }
        let present = current.filter { $0.id.map { rank[$0] != nil } ?? false }
        let kept = Set(longestIncreasing(present.map { rank[$0.id!]! }).map { present[$0].id! })
        for (at, wantedChild) in next.enumerated() where !kept.contains(wantedChild.id!) {
            let id = wantedChild.id!
            if let found = tree.find(id) {
                guard found.parent != nil, !found.contains(node) else { return .fail }
                found.detach()
                let index = place(node, next, at, found)
                ops.append(.move(id: id, parent: node.id!, index: index))
            } else {
                if collides(wantedChild, except: nil) { return .fail }
                let fresh = wantedChild.copy()
                let index = place(node, next, at, fresh)
                tree.added(fresh)
                ops.append(.insert(parent: node.id!, index: index, block: wantedChild.json))
            }
        }
        // Positions once; a settle replaces in place. Checked before use (a block reconciled below could have taken one out).
        var position: [String: Int] = [:]
        for (index, child) in (node.children ?? []).enumerated() { if let id = child.id { position[id] = index } }
        for wantedChild in next {
            let id = wantedChild.id!
            var index = position[id]
            if index == nil || node.children?[index!].id != id { index = node.children?.firstIndex(where: { $0.id == id }) }
            guard let index else { return .fail }
            if !settle(node, index, wantedChild) { return .fail }
        }
        leftovers += (node.children ?? []).filter { child in child.id.map { rank[$0] == nil } ?? true }
        return .ok
    }

    guard reconcile(work, newRoot) == .ok else { return nil }
    // 4. Left over: blocks no longer wanted that held something wanted (moved out by now).
    for block in leftovers {
        guard let id = block.id else { return nil }
        if wanted.contains(id) { continue }
        guard let found = tree.find(id), found.parent != nil else { continue }
        tree.removed(found)
        found.detach()
        ops.append(.remove(id: id))
    }
    guard ops.count <= maxPatchOperations else { return nil }
    guard let applied = try? applyPatch(before, ops), applied == after else { return nil }
    return ops
}

/// The number of blocks in a tree (or a list of trees).
func blockCount(_ blocks: JSONValue) -> Int {
    if let items = blocks.arrayValue { return items.reduce(0) { $0 + blockCount($1) } }
    return 1 + (blocks["children"]?.arrayValue ?? []).reduce(0) { $0 + blockCount($1) }
}

/// The positions of a longest strictly increasing run in `values` (patience sorting).
func longestIncreasing(_ values: [Int]) -> [Int] {
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: values.count)
    for index in values.indices {
        var low = 0
        var high = tails.count
        while low < high {
            let middle = (low + high) / 2
            if values[tails[middle]] < values[index] { low = middle + 1 } else { high = middle }
        }
        if low > 0 { previous[index] = tails[low - 1] }
        if low == tails.count { tails.append(index) } else { tails[low] = index }
    }
    var result: [Int] = []
    var at = tails.last ?? -1
    while at >= 0 {
        result.insert(at, at: 0)
        at = previous[at]
    }
    return result
}

// MARK: - The view state helper

extension ViewEvent {
    /// The event whose handler is running, nil outside one. A layout's callbacks get only what the layout reads from the event
    /// (a card id, a column); this is the rest, the same as the event Node.js layouts pass last: `ViewEvent.current?.isStale`.
    @TaskLocal public static var current: ViewEvent?
}

/// Which stale events a handler still receives. `.ignoreMoves` (the default): a move against an older revision is dropped,
/// because "put this at index 3" no longer means what the user saw; any other event is delivered with `isStale` set, so
/// text typed in quick succession is never lost.
public enum StalePolicy: Sendable { case ignoreMoves, ignore, deliver }

/// What `show` sent.
public enum ShowOutcome: Sendable { case update, patch, unchanged }

/// Something that can send notifications: the plugin, or a recorder in a test.
@MainActor
public protocol NotificationSink: AnyObject {
    func notify(_ method: String, _ params: JSONValue)
}

@MainActor
public final class ViewState {
    public let view: String
    /// The revision of the description sent last (0: nothing sent yet).
    public private(set) var revision = 0
    /// The description sent last.
    public private(set) var description: ViewDescription?
    /// The sidebar item the view was opened for (API 2), while it is open.
    public private(set) var item: String?
    /// Whether Vektor shows the view now (between `view/opened` and `view/closed`).
    public private(set) var isOpen = false
    /// Send `view/patch` when a patch says it (block views only).
    public var patches = true
    /// Check block trees before sending, the way Vektor does, and throw for one it would refuse.
    public var validates = true
    /// API 2: the last `view/refused` Vektor sent for this view, until it shows something sent after it (nil: none).
    public private(set) var refusal: ViewRefusal?
    /// After Vektor refused a **patch**, send the whole description kept here again (numbered above anything sent), as the
    /// reference asks — unless an `onRefused` handler already sent something. A refused whole description is not sent again
    /// (it would be refused again): `onRefused` decides what to show instead; the next `show` sends the whole description.
    public var resendsAfterRefusal = true

    private weak var sink: NotificationSink?
    private var handlers: [String: (handler: @MainActor (ViewEvent) async throws -> Void, stale: StalePolicy)] = [:]
    private var fallback: (handler: @MainActor (ViewEvent) async throws -> Void, stale: StalePolicy)?
    private var openHandlers: [@MainActor (ViewOpenedParams) async throws -> Void] = []
    private var closeHandlers: [@MainActor (ViewOpenedParams) async throws -> Void] = []
    private var refusedHandlers: [@MainActor (ViewRefusal) async throws -> Void] = []
    private var needsWhole = true
    /// The revision of the last whole description sent (0: none).
    private var wholeRevision = 0

    public init(view: String, sink: NotificationSink) {
        self.view = view
        self.sink = sink
    }

    /// Runs on `view/opened`: describe the view here (`show`). `item` is the sidebar item it was opened for.
    @discardableResult
    public func onOpen(_ handler: @escaping @MainActor (ViewOpenedParams) async throws -> Void) -> Self {
        openHandlers.append(handler)
        return self
    }

    @discardableResult
    public func onClose(_ handler: @escaping @MainActor (ViewOpenedParams) async throws -> Void) -> Self {
        closeHandlers.append(handler)
        return self
    }

    /// API 2: Vektor refused a description or a patch of this view (`view/refused`). `refusal.problem` says why, in plain
    /// words. When the handler runs, the next `show` already sends the whole description; after a refused patch the SDK resends
    /// the kept description by itself if the handler sent nothing (`resendsAfterRefusal`).
    @discardableResult
    public func onRefused(_ handler: @escaping @MainActor (ViewRefusal) async throws -> Void) -> Self {
        refusedHandlers.append(handler)
        return self
    }

    /// Routes `view/event`s with this `action` (the string your description carried) to `handler`.
    @discardableResult
    public func on(_ action: String, stale: StalePolicy = .ignoreMoves, _ handler: @escaping @MainActor (ViewEvent) async throws -> Void) -> Self {
        handlers[action] = (handler, stale)
        return self
    }

    /// Receives events whose action has no handler of its own.
    @discardableResult
    public func onAnyEvent(stale: StalePolicy = .ignoreMoves, _ handler: @escaping @MainActor (ViewEvent) async throws -> Void) -> Self {
        fallback = (handler, stale)
        return self
    }

    /// Shows `description`: as a patch when the previous one was a block view with the same header, banner, toolbar and
    /// empty state and a patch can say the change (and is smaller); as the whole description otherwise.
    @discardableResult
    public func show(_ description: ViewDescription) throws -> ShowOutcome {
        if !needsWhole, let previous = self.description, let oldBlocks = previous.blocksJSON, let newBlocks = description.blocksJSON {
            var oldRest = previous
            oldRest.blocks = nil
            var newRest = description
            newRest.blocks = nil
            if oldRest.json(revision: nil) == newRest.json(revision: nil) {
                if oldBlocks == newBlocks { return .unchanged }
                if patches, let ops = diffBlocks(oldBlocks, newBlocks), !ops.isEmpty {
                    let opsJSON = JSONValue.array(ops.map(\.json))
                    let patchBytes = opsJSON.jsonData.count
                    // Every block is at least `{"type":"…"}`: a patch smaller than that bound is smaller than the whole
                    // description without writing out the whole description to count it (40 ms for a 3,000-card board).
                    if patchBytes < 12 * blockCount(newBlocks) || patchBytes < description.json(revision: nil).jsonData.count {
                        try check(newBlocks)
                        revision += 1
                        self.description = description
                        sink?.notify(Method.viewPatch, ["view": .string(view), "revision": .int(revision), "ops": opsJSON])
                        return .patch
                    }
                }
            }
        }
        try update(description)
        return .update
    }

    /// Sends the whole description (a new revision).
    public func update(_ description: ViewDescription) throws {
        if let blocks = description.blocksJSON { try check(blocks) }
        revision += 1
        self.description = description
        needsWhole = false
        wholeRevision = revision
        sink?.notify(Method.viewUpdate, ["view": .string(view), "description": description.json(revision: revision)])
    }

    /// Sends patch operations you built yourself, after applying them to the kept description (so they must apply).
    public func patch(_ operations: [PatchOperation]) throws {
        guard var description, let blocks = description.blocksJSON, !needsWhole else {
            throw PluginError("The view “\(view)” has no block description yet: send the whole description first.")
        }
        guard operations.count <= maxPatchOperations else {
            throw PluginError("A patch can hold at most \(maxPatchOperations) operations: send the whole view instead.")
        }
        let patched = try applyPatch(blocks, operations)
        if let items = patched.arrayValue {
            description.blocks = try items.map(Block.init(json:))
        } else {
            description.blocks = [try Block(json: patched)]
        }
        revision += 1
        self.description = description
        sink?.notify(Method.viewPatch, ["view": .string(view), "revision": .int(revision), "ops": .array(operations.map(\.json))])
    }

    /// The next `show` sends the whole description.
    public func invalidate() { needsWhole = true }

    private func check(_ blocks: JSONValue) throws {
        guard validates else { return }
        if let problem = validateBlocks(blocks).problems.first { throw PluginError("The view “\(view)” cannot be shown: \(problem)") }
    }

    /// Called by the plugin for this view's `view/opened`, `view/closed` and `view/event`.
    public func receive(_ method: String, _ params: JSONValue) async throws {
        switch method {
        case Method.viewOpened:
            let opened = ViewOpenedParams(view: view, item: params["item"]?.stringValue)
            isOpen = true
            item = opened.item
            needsWhole = true
            refusal = nil
            for handler in openHandlers { try await handler(opened) }
        case Method.viewClosed:
            isOpen = false
            let closed = ViewOpenedParams(view: view, item: params["item"]?.stringValue)
            for handler in closeHandlers { try await handler(closed) }
            item = nil
        case Method.viewRefused:
            let refused = ViewRefusal(params)
            refusal = refused
            // Vektor keeps what it showed: whatever comes next must be the whole description.
            needsWhole = true
            let before = revision
            for handler in refusedHandlers { try await handler(refused) }
            // A refused patch: send the whole description again, once — not when a handler sent something already, and not
            // when a whole description went out after the refused patch (Vektor refuses the patches in between one by one).
            if resendsAfterRefusal, refused.kind == .patch, revision == before, let description,
                refused.refusedRevision.map({ $0 > wholeRevision }) ?? true
            {
                try update(description)
            }
        case Method.viewEvent:
            var event = ViewEvent(params)
            // An event made against the revision Vektor still shows after a refusal is not stale: Vektor never showed anything
            // newer. Once an event carries a newer revision, Vektor shows that one.
            if let shown = refusal?.revision, let made = event.revision, made > shown { refusal = nil }
            let shownAfterRefusal = refusal.map { $0.revision != nil && $0.revision == event.revision } ?? false
            event.isStale = !shownAfterRefusal && (event.revision.map { revision > 0 && $0 < revision } ?? false)
            guard let route = handlers[event.action] ?? fallback else { return }
            if event.isStale, route.stale == .ignore || (route.stale == .ignoreMoves && event.isMove) { return }
            try await ViewEvent.$current.withValue(event) { try await route.handler(event) }
        default:
            break
        }
    }
}
