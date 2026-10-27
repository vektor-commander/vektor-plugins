import Foundation

// List with detail: a split view — a searchable list on the left, the chosen item on the right.
//
//     try view.show(ViewDescription(root: layout.block))
//     layout.route(on: view, ListDetailHandlers(onSelect: { item in … }))
//
// The layout owns the arrangement (the draggable divider, the search field, the list with single selection); YOU own what the
// right side shows: `detail` is any blocks you like. `DetailPanel` below builds the usual one (a heading, label/value rows,
// Markdown, buttons) so you can start from it. Copy and adapt.

public struct ListDetailItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    public var badge: Badge?
    public var dimmed: Bool?
    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, badge: Badge? = nil, dimmed: Bool? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.badge = badge
        self.dimmed = dimmed
    }
}

/// One button under the detail. The `key` comes back in `onDetailAction`.
public struct DetailAction: Equatable, Sendable {
    public var key: String
    public var title: String
    public var symbol: String?
    public var style: Block.ButtonStyle?
    public var enabled: Bool?
    public init(key: String, title: String, symbol: String? = nil, style: Block.ButtonStyle? = nil, enabled: Bool? = nil) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.style = style
        self.enabled = enabled
    }
}

/// The usual right-hand side: heading, fields, Markdown, buttons. Give it the same `id` as the layout's.
public struct DetailPanel {
    public var id = "listDetail"
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    /// Label/value rows.
    public var fields: [(label: String, value: String)] = []
    public var markdown: String?
    public var actions: [DetailAction] = []
    public init(title: String) { self.title = title }

    public var blocks: [Block] {
        let names = LayoutNames(id)
        var heading: [Block] = []
        if let symbol { heading.append(.symbol(symbol, id: names.id("detail", "symbol"))) }
        var titles: [Block] = [.text(title, id: names.id("detail", "title"), style: .title, selectable: true)]
        if let subtitle { titles.append(.text(subtitle, id: names.id("detail", "subtitle"), style: .caption)) }
        heading.append(.vstack(titles))
        var out: [Block] = [.hstack(heading, id: names.id("detail", "heading"))]
        for (index, field) in fields.enumerated() {
            out.append(.hstack([
                .text(field.label, id: names.id("field", String(index), "label"), style: .caption),
                .spacer(),
                .text(field.value, id: names.id("field", String(index), "value"), selectable: true),
            ], id: names.id("field", String(index))))
        }
        if let markdown { out.append(.markdown(markdown, id: names.id("detail", "markdown"))) }
        if !actions.isEmpty {
            out.append(.hstack(actions.map {
                .button(id: names.id("action", $0.key), title: $0.title, symbol: $0.symbol, action: names.id("action"), style: $0.style, enabled: $0.enabled)
            }, id: names.id("actions")))
        }
        return out
    }
}

public struct ListDetailHandlers {
    /// The chosen item changed; nil: nothing is chosen any more.
    public var onSelect: LayoutAction<String?>?
    /// Return or a double-click on an item.
    public var onOpen: LayoutAction<String>?
    public var onSearch: LayoutAction<String>?
    /// A button of `DetailPanel`.
    public var onDetailAction: LayoutAction<String>?
    public init(
        onSelect: LayoutAction<String?>? = nil, onOpen: LayoutAction<String>? = nil, onSearch: LayoutAction<String>? = nil,
        onDetailAction: LayoutAction<String>? = nil
    ) {
        self.onSelect = onSelect
        self.onOpen = onOpen
        self.onSearch = onSearch
        self.onDetailAction = onDetailAction
    }
}

public struct ListDetail {
    /// Prefix of every block id and action (default `listDetail`).
    public var id = "listDetail"
    public var items: [ListDetailItem]
    /// The id of the chosen item, if any (what you heard from `onSelect`). It decides whether the right side shows `detail`,
    /// and while the item is shown it is sent as the list's `selected`: Vektor starts from it when it has no selection of its
    /// own (the first time, after the view is reopened, after the selected item was hidden); it never overrides the user's.
    public var selected: String?
    /// The search text; items that do not contain it (title or subtitle) are hidden.
    public var search = ""
    /// What the right side shows for the chosen item. With no item chosen it shows `emptyDetail`.
    public var detail: [Block] = []
    public var emptyDetail: (title: String?, text: String, symbol: String?) = (nil, "Choose an item.", nil)
    /// Your own blocks beside the search field (a "New" button, a Sync button …).
    public var toolbar: [Block] = []
    /// Where the divider starts: the list's share of the width (0…1).
    public var fraction = 0.38
    /// Shown when no item matches.
    public var placeholder = "Nothing found"

    public init(items: [ListDetailItem]) { self.items = items }

    /// The two panes as one block.
    public var block: Block {
        let names = LayoutNames(id)
        let shown = items.filter { layoutMatches(search, $0.title, $0.subtitle) }
        let left = Block.vstack([
            .hstack([.searchField(names.id("search"), action: names.id("search"), value: search, placeholder: "Search")] + toolbar, id: names.id("bar")),
            .list(
                names.id("list"),
                shown.map {
                    .row($0.id, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, badge: $0.badge, action: names.id("open"), dimmed: $0.dimmed)   // Return or a double-click
                },
                selection: .single, select: names.id("select"),
                selected: selected.flatMap { id in shown.contains { $0.id == id } ? [id] : nil }, placeholder: placeholder),
        ], id: names.id("left"))
        let rightBlocks = selected != nil && !detail.isEmpty
            ? detail : [Block.empty(emptyDetail.text, id: names.id("nothing"), title: emptyDetail.title, symbol: emptyDetail.symbol)]
        return .split(names.id("split"), left, .vstack(rightBlocks, id: names.id("right")), axis: .horizontal, fraction: fraction)
    }

    /// Sends the layout's events to `handlers`. Call once, when the view is set up.
    @MainActor
    public func route(on view: ViewState, _ handlers: ListDetailHandlers) {
        let names = self.names
        view.on(names.id("select")) { event in try await handlers.onSelect?(event.selected?.first) }
        view.on(names.id("open")) { event in
            if let item = event.block { try await handlers.onOpen?(item) }
        }
        view.on(names.id("search")) { event in try await handlers.onSearch?(event.text ?? "") }
        view.on(names.id("action")) { event in
            if let key = names.rest("action", of: event.block) { try await handlers.onDetailAction?(key) }
        }
    }

    private var names: LayoutNames { LayoutNames(id) }
}
