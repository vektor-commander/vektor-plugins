import Foundation

// Board: columns of cards (a kanban board).
//
// What it draws, per column: a title, a count of the cards shown ("2 of 5" while a search or filter hides some), a "+" button and a "…" menu. Cards can be dragged between
// columns and, with the keyboard, moved with ⌥ + an arrow — Vektor does both (the lists share a drag `group` and have `move`);
// the layout only hears the result as `onMove`. Above the columns: a search field, an optional filter (a picker over the
// cards' tags) and a toolbar slot for your own blocks (a Sync button, say).
//
// Two calls, used together:
//
//     try view.show(ViewDescription(header: Header(title: "Roadmap"), root: board.block))     // draw
//     board.route(on: view, BoardHandlers(onMove: { move in … }))                              // listen, once
//
// Copy this file and change it: it is a composition of blocks, not a new kind of block.
//
// Vektor shows a move only when your next description says so, so `onMove` is where you change YOUR data (`Board.move` does it
// for the usual shape) and call `view.show` again. The SDK turns the difference into one `move` patch.

public struct BoardTag: Equatable, Sendable {
    public var text: String
    public var role: Role?
    public init(_ text: String, role: Role? = nil) {
        self.text = text
        self.role = role
    }
}

public struct BoardCard: Equatable, Sendable {
    /// The card's own id, stable for as long as the card exists (never its position): Vektor and the SDK diff by id.
    public var id: String
    public var title: String
    /// A second line under the title.
    public var subtitle: String?
    /// A colour role for the stripe.
    public var role: Role?
    /// Words on tinted capsules. The filter offers these.
    public var tags: [BoardTag]
    public init(id: String, title: String, subtitle: String? = nil, role: Role? = nil, tags: [BoardTag] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.tags = tags
    }
}

public struct BoardColumn: Equatable, Sendable {
    public var id: String
    public var title: String
    public var role: Role?
    public var cards: [BoardCard]
    public init(id: String, title: String, role: Role? = nil, cards: [BoardCard] = []) {
        self.id = id
        self.title = title
        self.role = role
        self.cards = cards
    }
}

/// An entry of a column's "…" menu. The `key` comes back in `onColumnAction`.
public struct BoardColumnAction: Equatable, Sendable {
    public var key: String
    public var title: String
    public var symbol: String?
    public var destructive: Bool
    public init(key: String, title: String, symbol: String? = nil, destructive: Bool = false) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.destructive = destructive
    }
    public static let defaults = [
        BoardColumnAction(key: "rename", title: "Rename Column", symbol: "pencil"),
        BoardColumnAction(key: "delete", title: "Delete Column", symbol: "trash", destructive: true),
    ]
}

/// A card dropped, or moved with the keyboard. `index` is its position among the cards SHOWN in `to` once it is out of its old place.
public struct BoardMove: Equatable, Sendable {
    public var card: String
    public var from: String?
    public var to: String
    public var index: Int
    public init(card: String, from: String? = nil, to: String, index: Int) {
        self.card = card
        self.from = from
        self.to = to
        self.index = index
    }
}

public struct BoardHandlers {
    /// The "+" of a column.
    public var onAdd: LayoutAction<String>?
    /// "Open" in a card's context menu (Return and a double-click edit the title).
    public var onOpen: LayoutAction<String>?
    /// A card's title edited in place: the card, the new title.
    public var onRename: LayoutAction2<String, String>?
    /// ⌫ on a card. Ask first if you like (`plugin.confirm`).
    public var onRemove: LayoutAction<String>?
    public var onMove: LayoutAction<BoardMove>?
    /// An entry of a column's "…" menu: the column, the entry's key.
    public var onColumnAction: LayoutAction2<String, String>?
    public var onSearch: LayoutAction<String>?
    /// The filter changed: the option's value, `""` for "All".
    public var onFilter: LayoutAction<String>?

    public init(
        onAdd: LayoutAction<String>? = nil, onOpen: LayoutAction<String>? = nil, onRename: LayoutAction2<String, String>? = nil,
        onRemove: LayoutAction<String>? = nil, onMove: LayoutAction<BoardMove>? = nil, onColumnAction: LayoutAction2<String, String>? = nil,
        onSearch: LayoutAction<String>? = nil, onFilter: LayoutAction<String>? = nil
    ) {
        self.onAdd = onAdd
        self.onOpen = onOpen
        self.onRename = onRename
        self.onRemove = onRemove
        self.onMove = onMove
        self.onColumnAction = onColumnAction
        self.onSearch = onSearch
        self.onFilter = onFilter
    }
}

public struct Board {
    /// Prefix of every block id and action (default `board`).
    public var id = "board"
    public var columns: [BoardColumn]
    /// The search text shown in the search field; cards that do not contain it (in title, subtitle or a tag) are hidden.
    public var search = ""
    /// A filter over tags: `options` (include an "All" option with value `""`), and the one chosen (`""`: all).
    public var filterOptions: [Option]?
    public var filter = ""
    /// Vektor refuses an option whose value is empty, so the "All" option's `""` goes out as this value and comes back as `""`.
    public var filterAll: String { names.id("all") }
    /// Your own blocks, in the bar above the columns (a Sync button, a "New column" button …).
    public var toolbar: [Block] = []
    /// What a column's "…" menu offers. Default: rename and delete. `[]` shows no menu.
    public var columnMenu = BoardColumnAction.defaults
    /// Shown in an empty column.
    public var placeholder = "No cards"
    /// Columns fill the pane, sharing its width, and scroll sideways once they would be narrower than this (points, 20…4000).
    /// nil: a column is as wide as its widest card.
    public var columnMinWidth: Double?

    /// The drag group every list shares, so cards move between columns.
    public static let group = "cards"

    public init(columns: [BoardColumn]) { self.columns = columns }

    private var names: LayoutNames { LayoutNames(id) }

    /// Whether a card shows under the search and filter.
    public func shows(_ card: BoardCard) -> Bool {
        let tagOK = filter.isEmpty || card.tags.contains { $0.text == filter }
        return tagOK && layoutMatches(search, [card.title, card.subtitle] + card.tags.map { Optional($0.text) })
    }

    private func cardBlock(_ item: BoardCard) -> Block {
        var children: [Block] = []
        if let subtitle = item.subtitle, !subtitle.isEmpty { children.append(.text(subtitle, id: names.id("subtitle", item.id), style: .caption)) }
        for (index, tag) in item.tags.enumerated() { children.append(.badge(tag.text, id: names.id("tag", item.id, String(index)), role: tag.role)) }
        return Block.card(
            children, id: item.id, title: item.title, role: item.role,
            edit: names.id("rename"),     // Return or a double-click: the title edited in place
            delete: names.id("remove")    // ⌫ / ⌘⌫
        )
        // Vektor gives `edit` precedence over `action` on Return and a double-click, so a card that can be renamed is opened
        // from its context menu. A menu item's event names the block carrying the menu: the card.
        .menu([.item(title: "Open", action: names.id("open"))])
    }

    private func columnBlock(_ column: BoardColumn) -> Block {
        let shown = column.cards.filter(shows)
        let entries = columnMenu.map {
            MenuEntry.item(title: $0.title, action: names.id("column", $0.key), symbol: $0.symbol, destructive: $0.destructive ? true : nil)
        }
        // The count is a block of its own, not the panel's `badge`: a card that moves changes two counts, and a change in a panel's
        // own fields would make the SDK replace the whole column (all its cards) instead of sending one small `move`.
        // With a search or filter on, it also says how many there are.
        let countID = names.id("count", column.id)
        var header: [Block] = [
            shown.count == column.cards.count
                ? .count(shown.count, id: countID) : .badge("\(shown.count) of \(column.cards.count)", id: countID),
            .spacer(),
            .button(id: names.id("add", column.id), symbol: "plus", action: names.id("add"), style: .icon, tooltip: "Add a card"),
        ]
        if !entries.isEmpty { header.append(Block.menu(entries, id: names.id("colmenu", column.id)).label("\(column.title) actions")) }
        let panel = Block.panel(
            [
                .hstack(header, id: names.id("head", column.id)),
                .list(names.id("list", column.id), shown.map(cardBlock), group: Self.group, move: names.id("move"), placeholder: placeholder),
            ],
            id: names.id("col", column.id), title: column.title, role: column.role)
        return columnMinWidth.map { panel.grow().minWidth($0) } ?? panel
    }

    /// The board as one block: a bar (search, filter, your toolbar) over the columns, which scroll sideways.
    public var block: Block {
        var bar: [Block] = [.searchField(names.id("search"), action: names.id("search"), value: search, placeholder: "Search cards")]
        if let filterOptions {
            let options = filterOptions.map { Option(value: $0.value.isEmpty ? filterAll : $0.value, title: $0.title, symbol: $0.symbol) }
            bar.append(.picker(names.id("filter"), action: names.id("filter"), options: options, value: filter.isEmpty ? filterAll : filter))
        }
        bar.append(.spacer())
        bar += toolbar
        return .vstack([
            .hstack(bar, id: names.id("bar")),
            .scroll([.hstack(columns.map(columnBlock), id: names.id("columns"))], id: names.id("scroll"), axis: .horizontal),
        ], id: id)
    }

    /// Sends the board's events to `handlers`. Call once, when the view is set up. The board must be the one you draw
    /// (the same `id` and `columnMenu`).
    ///
    /// Moves made against an older description are dropped by the view state (the default `.ignoreMoves` policy), because
    /// "put it at index 3" no longer means what the user saw.
    @MainActor
    public func route(on view: ViewState, _ handlers: BoardHandlers) {
        let names = self.names
        view.on(names.id("add")) { event in
            if let column = names.rest("add", of: event.block) { try await handlers.onAdd?(column) }
        }
        view.on(names.id("open")) { event in
            if let card = event.block { try await handlers.onOpen?(card) }
        }
        view.on(names.id("rename")) { event in
            if let card = event.block { try await handlers.onRename?(card, event.text ?? "") }
        }
        view.on(names.id("remove")) { event in
            if let card = event.block { try await handlers.onRemove?(card) }
        }
        view.on(names.id("move")) { event in
            guard let card = event.item, let to = names.rest("list", of: event.target) else { return }
            try await handlers.onMove?(BoardMove(card: card, from: names.rest("list", of: event.from), to: to, index: event.index ?? 0))
        }
        for entry in columnMenu {
            // A menu item's event names the block that carries the menu: the column's "…" block.
            view.on(names.id("column", entry.key)) { event in
                if let column = names.rest("colmenu", of: event.block) { try await handlers.onColumnAction?(column, entry.key) }
            }
        }
        view.on(names.id("search")) { event in try await handlers.onSearch?(event.text ?? "") }
        let filterAll = self.filterAll
        view.on(names.id("filter")) { event in
            let value = event.text ?? ""
            try await handlers.onFilter?(value == filterAll ? "" : value)
        }
    }

    /// Applies a move to your columns: the card leaves its column and goes into `to` at the position `index` counts among the
    /// cards that are shown (a search or filter may hide some; they keep their place). Returns false when the card or the
    /// column is unknown. This is the usual `onMove`:
    ///
    ///     onMove: { move in if Board.apply(move, to: &columns, isShown: board.shows) { draw() } }
    public static func apply(_ move: BoardMove, to columns: inout [BoardColumn], isShown: (BoardCard) -> Bool = { _ in true }) -> Bool {
        guard let source = columns.firstIndex(where: { $0.cards.contains { $0.id == move.card } }),
            let target = columns.firstIndex(where: { $0.id == move.to })
        else { return false }
        let moving = columns[source].cards.remove(at: columns[source].cards.firstIndex { $0.id == move.card }!)
        // `index` counts shown cards only: find the shown card that must come right after, and insert before it.
        let shown = columns[target].cards.filter(isShown)
        // An index past either end (a malformed event) puts it last, as in Node.js.
        let at = shown.indices.contains(move.index) ? columns[target].cards.firstIndex { $0.id == shown[move.index].id }! : columns[target].cards.count
        columns[target].cards.insert(moving, at: at)
        return true
    }
}
