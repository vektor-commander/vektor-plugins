import Foundation

// Table with toolbar: sortable columns, multiple selection and a toolbar of buttons above.
//
//     try view.show(ViewDescription(root: table.block))
//     table.route(on: view, TableHandlers(onSort: { column, ascending in … }))
//
// Vektor does not sort for you: it shows the arrow and tells you which column and direction the user chose (`onSort`); you
// sort your rows (`TableRow.sorted` does the usual comparison) and describe the table again. The same goes for the selection:
// keep the ids `onSelect` gives you and pass them back as `selected` (they decide the "N selected" text and which buttons are
// on, and Vektor starts from them when it has no selection of its own: the first time, and after the view is reopened).
//
// Vektor keeps only the selected rows that are still described, without telling you (a search that hides a selected row
// unselects it). The layout does the same: what it draws and what `onToolbar` reports count only the rows shown. Copy and adapt.

public struct TableRow: Equatable, Sendable {
    public var id: String
    public var cells: [JSONValue]
    public var dimmed: Bool?
    public init(id: String, cells: [JSONValue], dimmed: Bool? = nil) {
        self.id = id
        self.cells = cells
        self.dimmed = dimmed
    }

    /// Rows in the order a sorted column asks for: numbers as numbers, text the way the user's language orders it.
    public static func sorted(_ rows: [TableRow], columns: [Column], by sorted: (column: String, ascending: Bool)?) -> [TableRow] {
        guard let sorted, let at = columns.firstIndex(where: { $0.id == sorted.column }) else { return rows }
        func order(_ a: JSONValue?, _ b: JSONValue?) -> ComparisonResult {
            if let x = a?.numberValue, let y = b?.numberValue { return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
            return (a?.stringValue ?? a?.jsonText ?? "").localizedStandardCompare(b?.stringValue ?? b?.jsonText ?? "")
        }
        // A stable sort: rows that compare equal keep their order, in either direction.
        let ordered = rows.enumerated().sorted { left, right in
            let result = order(left.element.cells[safe: at], right.element.cells[safe: at])
            if result == .orderedSame { return left.offset < right.offset }
            return sorted.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return ordered.map(\.element)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A toolbar button. With `needsSelection` it is disabled while nothing is selected. The `key` comes back in `onToolbar`.
public struct ToolbarButton: Equatable, Sendable {
    public var key: String
    public var title: String?
    public var symbol: String?
    public var tooltip: String?
    public var style: Block.ButtonStyle?
    public var needsSelection = false
    public var enabled: Bool?
    public init(key: String, title: String? = nil, symbol: String? = nil, tooltip: String? = nil, style: Block.ButtonStyle? = nil,
                needsSelection: Bool = false, enabled: Bool? = nil) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.tooltip = tooltip
        self.style = style
        self.needsSelection = needsSelection
        self.enabled = enabled
    }
}

public struct TableHandlers {
    /// The user clicked a sortable column's header: the column, whether ascending.
    public var onSort: LayoutAction2<String, Bool>?
    public var onSelect: LayoutAction<[String]>?
    /// A toolbar button: its key and the selection the layout heard last, without rows no longer shown.
    public var onToolbar: LayoutAction2<String, [String]>?
    public var onSearch: LayoutAction<String>?
    /// Return or a double-click on a row.
    public var onOpen: LayoutAction<String>?
    /// ⌫ on a row.
    public var onDelete: LayoutAction<String>?
    public init(
        onSort: LayoutAction2<String, Bool>? = nil, onSelect: LayoutAction<[String]>? = nil, onToolbar: LayoutAction2<String, [String]>? = nil,
        onSearch: LayoutAction<String>? = nil, onOpen: LayoutAction<String>? = nil, onDelete: LayoutAction<String>? = nil
    ) {
        self.onSort = onSort
        self.onSelect = onSelect
        self.onToolbar = onToolbar
        self.onSearch = onSearch
        self.onOpen = onOpen
        self.onDelete = onDelete
    }
}

/// Remembers the selection between events, so a toolbar button can be given it. Nil until `select` says something after the
/// view opens, because a reopened view starts with no selection of Vektor's own and shows the `selected` it was described with.
@MainActor
final class SelectionMemory {
    var heard: [String]?
}

public struct TableWithToolbar {
    /// Prefix of every block id and action (default `table`).
    public var id = "table"
    public var columns: [Column]
    public var rows: [TableRow]
    public var sorted: (column: String, ascending: Bool)?
    /// The ids of the selected rows, as you last heard them from `onSelect`. Those shown drive the "N selected" text and the
    /// buttons that need a selection, and are sent as the table's `selected`: Vektor starts from them when it has no selection
    /// of its own (it never overrides one the user made).
    public var selected: [String] = []
    /// The search text; rows with no cell containing it are hidden.
    public var search = ""
    public var toolbar: [ToolbarButton] = []
    /// Your own blocks at the end of the toolbar.
    public var extra: [Block] = []

    public init(columns: [Column], rows: [TableRow]) {
        self.columns = columns
        self.rows = rows
    }

    private var names: LayoutNames { LayoutNames(id) }

    public var block: Block {
        let names = self.names
        let shown = rows.filter { row in layoutMatches(search, row.cells.map { Optional($0.stringValue ?? $0.jsonText) }) }
        // Only rows still shown can be selected: Vektor drops the others from its selection, silently.
        let shownIDs = Set(shown.map(\.id))
        let selected = self.selected.filter(shownIDs.contains)
        var bar: [Block] = [.searchField(names.id("search"), action: names.id("search"), value: search, placeholder: "Search")]
        for entry in toolbar {
            bar.append(.button(
                id: names.id("tool", entry.key), title: entry.title, symbol: entry.symbol, action: names.id("tool"), style: entry.style,
                tooltip: entry.tooltip, enabled: entry.enabled == false ? false : (entry.needsSelection && selected.isEmpty ? false : nil)))
        }
        bar.append(.spacer())
        // The count is words, so VoiceOver and a colour-blind reader get it too.
        if !selected.isEmpty { bar.append(.text("\(selected.count) selected", id: names.id("count"), style: .caption)) }
        bar += extra
        return .vstack([
            .hstack(bar, id: names.id("bar")),
            .table(
                names.id("table"), columns: columns,
                rows: shown.map {
                    .row($0.id, cells: $0.cells, action: names.id("open"), delete: names.id("delete"), dimmed: $0.dimmed)   // Return / double-click; ⌫
                },
                sorted: sorted, sort: names.id("sort"), selection: .multiple, select: names.id("select"),
                selected: selected.isEmpty ? nil : selected),
        ], id: id)
    }

    /// Sends the table's events to `handlers`. Call once, when the view is set up.
    @MainActor
    public func route(on view: ViewState, _ handlers: TableHandlers) {
        let names = self.names
        let memory = SelectionMemory()
        view.onOpen { _ in memory.heard = nil }
        // The selection the user sees: what was heard (or described), less the rows the table no longer has.
        let tableID = names.id("table")
        let visible = { [weak view] () -> [String] in
            guard let view else { return [] }
            let table = describedBlock(tableID, in: view)
            let rows = Set((table?.children ?? []).compactMap(\.id))
            let selected = memory.heard ?? table?.fields["selected"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return selected.filter(rows.contains)
        }
        view.on(names.id("sort")) { event in
            if let column = event.column { try await handlers.onSort?(column, event.ascending ?? true) }
        }
        view.on(names.id("select")) { event in
            let selected = event.selected ?? []
            memory.heard = selected
            try await handlers.onSelect?(selected)
        }
        view.on(names.id("tool")) { event in
            if let key = names.rest("tool", of: event.block) { try await handlers.onToolbar?(key, visible()) }
        }
        view.on(names.id("search")) { event in try await handlers.onSearch?(event.text ?? "") }
        view.on(names.id("open")) { event in
            if let row = event.block { try await handlers.onOpen?(row) }
        }
        view.on(names.id("delete")) { event in
            if let row = event.block { try await handlers.onDelete?(row) }
        }
    }
}
