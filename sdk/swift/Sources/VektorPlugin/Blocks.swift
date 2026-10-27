import Foundation

// Typed builders for every block of a block view (plugin API 2; docs/reference.md, "Block views"). Each builder gives exactly
// the JSON the reference documents: `type`, the fields you passed (nil ones are left out) and, for containers, `children`.
//
//     Block.hstack([
//         Block.panel([Block.list("todo", cards, group: "cards", move: "move")], id: "col-todo", title: "To do", role: .label6),
//     ], id: "board")
//
// Rules the builders help with:
//   * Ids: collections' items, inputs, sections, tabs, splits, nodes and web blocks need an `id`, unique in the view; their
//     builders take it first. Keep ids STABLE across descriptions (a card's id is the card's own id, never its position):
//     Vektor and `ViewState` diff by id.
//   * Colours: never a colour value. Name a `Role`. `validateBlocks` reports a `color`/`background`/… field.

/// A colour role. Every theme defines every role, graded for contrast under every accent.
public enum Role: String, Codable, Sendable, CaseIterable {
    case accent, positive, warning, danger, neutral
    case label1, label2, label3, label4, label5, label6, label7, label8

    /// What a person reads for the role: the colour is never the only thing that says which one it is.
    public var title: String {
        switch self {
        case .accent: return "Accent"
        case .positive: return "Positive"
        case .warning: return "Warning"
        case .danger: return "Danger"
        case .neutral: return "Neutral"
        case .label1: return "Red"
        case .label2: return "Orange"
        case .label3: return "Yellow"
        case .label4: return "Green"
        case .label5: return "Teal"
        case .label6: return "Blue"
        case .label7: return "Purple"
        case .label8: return "Pink"
        }
    }

    /// The fields Vektor ignores (and logs) because they would carry a colour value.
    public static let colourValueKeys: [String] = ["color", "colour", "background", "backgroundColor", "foreground", "foregroundColor", "tint", "fill", "textColor"]
}

/// One item of a context menu or a "…" menu, or a separator.
public enum MenuEntry: Equatable, Sendable {
    case item(title: String, action: String, symbol: String? = nil, destructive: Bool? = nil, enabled: Bool? = nil)
    case separator

    public var json: JSONValue {
        switch self {
        case .separator: return ["separator": true]
        case .item(let title, let action, let symbol, let destructive, let enabled):
            var fields = JSONFields()
            fields.set("title", title)
            fields.set("action", action)
            fields.set("symbol", symbol)
            fields.set("destructive", destructive)
            fields.set("enabled", enabled)
            return .object(fields.object)
        }
    }
}

/// A small button on a row (`buttons`).
public struct Control: Equatable, Sendable {
    public var title: String
    public var action: String
    public var symbol: String?
    public var enabled: Bool?
    public init(title: String, action: String, symbol: String? = nil, enabled: Bool? = nil) {
        self.title = title
        self.action = action
        self.symbol = symbol
        self.enabled = enabled
    }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("title", title)
        fields.set("symbol", symbol)
        fields.set("action", action)
        fields.set("enabled", enabled)
        return .object(fields.object)
    }
}

/// A word on a tinted capsule beside a title (a card's, a panel's, a row's `badge`).
public struct Badge: Equatable, Sendable {
    public var text: String
    public var role: Role?
    public init(_ text: String, role: Role? = nil) {
        self.text = text
        self.role = role
    }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("text", text)
        fields.set("role", role?.rawValue)
        return .object(fields.object)
    }
}

/// An option of a picker.
public struct Option: Equatable, Sendable {
    public var value: String
    public var title: String
    public var symbol: String?
    public init(value: String, title: String, symbol: String? = nil) {
        self.value = value
        self.title = title
        self.symbol = symbol
    }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("value", value)
        fields.set("title", title)
        fields.set("symbol", symbol)
        return .object(fields.object)
    }
}

/// A column of a table.
public struct Column: Equatable, Sendable {
    public var id: String
    public var title: String
    public var width: Double?
    public var sortable: Bool?
    public init(id: String, title: String, width: Double? = nil, sortable: Bool? = nil) {
        self.id = id
        self.title = title
        self.width = width
        self.sortable = sortable
    }
    public var json: JSONValue {
        var fields = JSONFields()
        fields.set("id", id)
        fields.set("title", title)
        fields.set("width", width)
        fields.set("sortable", sortable)
        return .object(fields.object)
    }
}

public enum Selection: String, Sendable { case none, single, multiple }

/// A block: its `type`, its fields, and its children (nil for blocks that hold none).
public struct Block: Equatable, Sendable {
    public var type: String
    public var fields: [String: JSONValue]
    public var children: [Block]?

    public init(type: String, fields: [String: JSONValue] = [:], children: [Block]? = nil) {
        self.type = type
        self.fields = fields
        self.children = children
    }

    public var id: String? {
        get { fields["id"]?.stringValue }
        set { fields["id"] = newValue.map(JSONValue.string) }
    }

    /// The block as JSON, exactly as it is sent.
    public var json: JSONValue {
        var object = fields
        object["type"] = .string(type)
        if let children { object["children"] = .array(children.map(\.json)) }
        return .object(object)
    }

    /// Reads a block back from JSON (a description the plugin kept, a test). Throws for something that is not a block.
    public init(json: JSONValue) throws {
        guard case .object(var object) = json, let type = object["type"]?.stringValue else {
            throw PluginError("A block is an object with a “type”.")
        }
        self.type = type
        object["type"] = nil
        if let raw = object.removeValue(forKey: "children") {
            guard case .array(let items) = raw else { throw PluginError("The “children” of a block must be a list.") }
            children = try items.map(Block.init(json:))
        }
        fields = object
    }

    private static func make(_ type: String, _ build: (inout JSONFields) -> Void, children: [Block]? = nil) -> Block {
        var fields = JSONFields()
        build(&fields)
        return Block(type: type, fields: fields.object, children: children)
    }

    // MARK: Fields on any block

    /// Sets (or with nil removes) any field: for one this SDK does not type yet.
    public func with(_ key: String, _ value: JSONValue?) -> Block {
        var copy = self
        copy.fields[key] = value
        return copy
    }
    public func id(_ id: String) -> Block { with("id", .string(id)) }
    /// A context menu.
    public func menu(_ entries: [MenuEntry]) -> Block { with("menu", .array(entries.map(\.json))) }
    public func tooltip(_ text: String) -> Block { with("tooltip", .string(text)) }
    /// What VoiceOver reads.
    public func label(_ text: String) -> Block { with("label", .string(text)) }
    /// The block can be dragged; the value is its group.
    public func drag(_ group: String) -> Block { with("drag", .string(group)) }
    /// Blocks of these drag groups may be dropped here; `action` is sent with `item`, `target`, `index`.
    public func drop(action: String, accepts: [String]) -> Block {
        with("drop", ["action": .string(action), "accepts": .array(accepts.map(JSONValue.string))])
    }
    public enum FileDropAccepts: String, Sendable { case files, folders, both }
    /// Files and folders dropped from Vektor's panes or Finder (local items only).
    public func fileDrop(action: String, accepts: FileDropAccepts? = nil, extensions: [String]? = nil) -> Block {
        var fields = JSONFields()
        fields.set("action", action)
        fields.set("accepts", accepts?.rawValue)
        fields.set("extensions", extensions)
        return with("fileDrop", .object(fields.object))
    }
    /// Drawn only while the pointer is over it or it has the keyboard.
    public func revealOnHover(_ on: Bool = true) -> Block { with("revealOnHover", .bool(on)) }
    public func enabled(_ on: Bool) -> Block { with("enabled", .bool(on)) }
    /// An inline error under an input.
    public func error(_ text: String?) -> Block { with("error", text.map(JSONValue.string)) }

    // Widths (API 2): structural numbers in points, never a theme's, from `BlockLimits.widths` (20…4000; Vektor ignores another
    // value and the Log says so — `validateBlocks` warns). A block without them is drawn as before.

    /// The width the block asks for; never wider than its row offers, so it cannot push the view past the pane.
    public func width(_ points: Double) -> Block { with("width", .number(points)) }
    /// The narrowest it is drawn: honoured inside a horizontal `scroll` only, which shows the rest by scrolling. (On a `grid`,
    /// `minWidth` keeps its own meaning: the tile minimum, which `Block.grid(minWidth:)` sets.)
    public func minWidth(_ points: Double) -> Block { with("minWidth", .number(points)) }
    /// The widest it is drawn.
    public func maxWidth(_ points: Double) -> Block { with("maxWidth", .number(points)) }
    /// The block takes a share of the width its row leaves; growing siblings share it equally. Inside a horizontal `scroll`, a
    /// growing child makes the row at least as wide as the scroll is shown (a board whose columns fill the pane).
    public func grow(_ on: Bool = true) -> Block { with("grow", .bool(on)) }

    // MARK: Layout

    public static func vstack(_ children: [Block], id: String? = nil, spacing: Double? = nil) -> Block {
        make("vstack", { $0.set("id", id); $0.set("spacing", spacing) }, children: children)
    }
    public static func hstack(_ children: [Block], id: String? = nil, spacing: Double? = nil) -> Block {
        make("hstack", { $0.set("id", id); $0.set("spacing", spacing) }, children: children)
    }
    public static func spacer(id: String? = nil) -> Block { make("spacer", { $0.set("id", id) }) }
    public static func divider(id: String? = nil) -> Block { make("divider", { $0.set("id", id) }) }
    /// Tiles: `columns` fixed, or as many as fit at `minWidth`.
    public static func grid(_ children: [Block], id: String? = nil, columns: Int? = nil, minWidth: Double? = nil, spacing: Double? = nil) -> Block {
        make("grid", { $0.set("id", id); $0.set("columns", columns); $0.set("minWidth", minWidth); $0.set("spacing", spacing) }, children: children)
    }
    public enum ScrollAxis: String, Sendable { case vertical, horizontal, both }
    public static func scroll(_ children: [Block], id: String? = nil, axis: ScrollAxis? = nil, spacing: Double? = nil) -> Block {
        make("scroll", { $0.set("id", id); $0.set("axis", axis?.rawValue); $0.set("spacing", spacing) }, children: children)
    }
    public enum SplitAxis: String, Sendable { case horizontal, vertical }
    /// Two children with a divider the user drags. Inside a vertical scroll it needs a `height`.
    public static func split(_ id: String, _ first: Block, _ second: Block, axis: SplitAxis? = nil, fraction: Double? = nil, height: Double? = nil) -> Block {
        make("split", { $0.set("id", id); $0.set("axis", axis?.rawValue); $0.set("fraction", fraction); $0.set("height", height) }, children: [first, second])
    }
    public static func section(_ id: String, _ children: [Block], title: String? = nil, collapsible: Bool? = nil, collapsed: Bool? = nil, count: Int? = nil) -> Block {
        make("section", { $0.set("id", id); $0.set("title", title); $0.set("collapsible", collapsible); $0.set("collapsed", collapsed); $0.set("count", count) }, children: children)
    }
    /// Tabs over `tab` children; `action` sends the chosen tab's id as `value`.
    public static func tabs(_ id: String, _ tabs: [Block], segmented: Bool = false, action: String? = nil) -> Block {
        make("tabs", { $0.set("id", id); if segmented { $0.set("style", "segmented") }; $0.set("action", action) }, children: tabs)
    }
    public static func tab(_ id: String, title: String, _ children: [Block], symbol: String? = nil) -> Block {
        make("tab", { $0.set("id", id); $0.set("title", title); $0.set("symbol", symbol) }, children: children)
    }
    /// An elevated surface; a role draws a stripe. As a list's item it needs an id and may be edited, checked, deleted.
    public static func card(
        _ children: [Block] = [], id: String? = nil, title: String? = nil, symbol: String? = nil, role: Role? = nil, badge: Badge? = nil,
        action: String? = nil, edit: String? = nil, delete: String? = nil, check: String? = nil, checked: Bool? = nil, dimmed: Bool? = nil
    ) -> Block {
        make("card", {
            $0.set("id", id); $0.set("title", title); $0.set("symbol", symbol); $0.set("role", role?.rawValue); $0.set("badge", badge?.json)
            item(&$0, action: action, edit: edit, delete: delete, check: check, checked: checked, dimmed: dimmed)
        }, children: children)
    }
    /// A plain surface; a role draws a stripe (a board's column).
    public static func panel(
        _ children: [Block] = [], id: String? = nil, title: String? = nil, symbol: String? = nil, role: Role? = nil, badge: Badge? = nil
    ) -> Block {
        make("panel", { $0.set("id", id); $0.set("title", title); $0.set("symbol", symbol); $0.set("role", role?.rawValue); $0.set("badge", badge?.json) }, children: children)
    }

    private static func item(_ fields: inout JSONFields, action: String?, edit: String?, delete: String?, check: String?, checked: Bool?, dimmed: Bool?) {
        fields.set("action", action)
        fields.set("edit", edit)
        fields.set("delete", delete)
        fields.set("check", check)
        fields.set("checked", checked)
        fields.set("dimmed", dimmed)
    }

    // MARK: Collections

    /// Items (usually rows or cards), drawn lazily. Every item needs an id. `spacing` is the gap between items.
    public static func list(
        _ id: String, _ children: [Block], selection: Selection? = nil, select: String? = nil, selected: [String]? = nil,
        group: String? = nil, move: String? = nil, placeholder: String? = nil, spacing: Double? = nil
    ) -> Block {
        make("list", {
            $0.set("id", id); $0.set("selection", selection?.rawValue); $0.set("select", select); $0.set("selected", selected)
            $0.set("group", group); $0.set("move", move); $0.set("placeholder", placeholder); $0.set("spacing", spacing)
        }, children: children)
    }
    public static func row(
        _ id: String, title: String? = nil, subtitle: String? = nil, symbol: String? = nil, badge: Badge? = nil, buttons: [Control]? = nil,
        cells: [JSONValue]? = nil, action: String? = nil, edit: String? = nil, delete: String? = nil, check: String? = nil, checked: Bool? = nil,
        dimmed: Bool? = nil, children: [Block]? = nil
    ) -> Block {
        make("row", {
            $0.set("id", id); $0.set("title", title); $0.set("subtitle", subtitle); $0.set("symbol", symbol); $0.set("badge", badge?.json)
            $0.set("buttons", buttons.map { JSONValue.array($0.map(\.json)) }); $0.set("cells", cells.map(JSONValue.array))
            item(&$0, action: action, edit: edit, delete: delete, check: check, checked: checked, dimmed: dimmed)
        }, children: children)
    }
    /// Sortable columns; `row` children with `cells`.
    public static func table(
        _ id: String, columns: [Column], rows: [Block], sorted: (column: String, ascending: Bool)? = nil, sort: String? = nil,
        selection: Selection? = nil, select: String? = nil, selected: [String]? = nil
    ) -> Block {
        make("table", {
            $0.set("id", id); $0.set("columns", JSONValue.array(columns.map(\.json)))
            if let sorted { $0.set("sorted", ["column": .string(sorted.column), "ascending": .bool(sorted.ascending)] as JSONValue) }
            $0.set("sort", sort); $0.set("selection", selection?.rawValue); $0.set("select", select); $0.set("selected", selected)
        }, children: rows)
    }
    public static func tree(_ id: String, _ nodes: [Block], selection: Selection? = nil, select: String? = nil, selected: [String]? = nil) -> Block {
        make("tree", { $0.set("id", id); $0.set("selection", selection?.rawValue); $0.set("select", select); $0.set("selected", selected) }, children: nodes)
    }
    public static func node(_ id: String, title: String, _ children: [Block] = [], symbol: String? = nil, expanded: Bool? = nil, action: String? = nil) -> Block {
        make("node", { $0.set("id", id); $0.set("title", title); $0.set("symbol", symbol); $0.set("expanded", expanded); $0.set("action", action) }, children: children)
    }

    // MARK: Content

    public enum TextStyle: String, Sendable { case title, heading, body, caption, mono }
    public static func text(_ text: String, id: String? = nil, style: TextStyle? = nil, selectable: Bool? = nil, link: String? = nil, role: Role? = nil, lineLimit: Int? = nil) -> Block {
        make("text", {
            $0.set("id", id); $0.set("text", text); $0.set("style", style?.rawValue); $0.set("selectable", selectable); $0.set("link", link)
            $0.set("role", role?.rawValue); $0.set("lineLimit", lineLimit)
        })
    }
    public static func symbol(_ name: String, id: String? = nil, role: Role? = nil, label: String? = nil) -> Block {
        make("symbol", { $0.set("id", id); $0.set("symbol", name); $0.set("role", role?.rawValue); $0.set("label", label) })
    }
    /// A word on a tinted capsule. Meaning is in the word, never only in the colour.
    public static func badge(_ text: String, id: String? = nil, role: Role? = nil, label: String? = nil) -> Block {
        make("badge", { $0.set("id", id); $0.set("text", text); $0.set("role", role?.rawValue); $0.set("label", label) })
    }
    public static func count(_ count: Int, id: String? = nil, role: Role? = nil, label: String? = nil) -> Block {
        make("count", { $0.set("id", id); $0.set("count", count); $0.set("role", role?.rawValue); $0.set("label", label) })
    }
    public static func markdown(_ markdown: String, id: String? = nil) -> Block { make("markdown", { $0.set("id", id); $0.set("markdown", markdown) }) }
    private static func note(_ type: String, _ text: String, id: String?, title: String?, symbol: String?, role: Role?, link: String?) -> Block {
        make(type, { $0.set("id", id); $0.set("text", text); $0.set("title", title); $0.set("symbol", symbol); $0.set("role", role?.rawValue); $0.set("link", link) })
    }
    public static func empty(_ text: String, id: String? = nil, title: String? = nil, symbol: String? = nil, role: Role? = nil, link: String? = nil) -> Block {
        note("empty", text, id: id, title: title, symbol: symbol, role: role, link: link)
    }
    public static func banner(_ text: String, id: String? = nil, title: String? = nil, symbol: String? = nil, role: Role? = nil, link: String? = nil) -> Block {
        note("banner", text, id: id, title: title, symbol: symbol, role: role, link: link)
    }
    public static func status(_ text: String, id: String? = nil, title: String? = nil, symbol: String? = nil, role: Role? = nil, link: String? = nil) -> Block {
        note("status", text, id: id, title: title, symbol: symbol, role: role, link: link)
    }
    /// Two texts compared by the Diff Tool's engine, read-only. `keepLeft`/`keepRight` are actions.
    public static func diff(left: String, right: String, id: String? = nil, leftTitle: String? = nil, rightTitle: String? = nil, keepLeft: String? = nil, keepRight: String? = nil) -> Block {
        make("diff", {
            $0.set("id", id); $0.set("left", left); $0.set("right", right); $0.set("leftTitle", leftTitle); $0.set("rightTitle", rightTitle)
            $0.set("keepLeft", keepLeft); $0.set("keepRight", keepRight)
        })
    }

    // MARK: Input

    public enum ButtonStyle: String, Sendable { case primary, plain, destructive, icon }
    /// A button: needs an `action` or a `menu` (`.menu(_:)`). `.icon` shows only the symbol, with the tooltip.
    public static func button(
        id: String? = nil, title: String? = nil, symbol: String? = nil, action: String? = nil, style: ButtonStyle? = nil,
        tooltip: String? = nil, busy: Bool? = nil, enabled: Bool? = nil
    ) -> Block {
        make("button", {
            $0.set("id", id); $0.set("title", title); $0.set("symbol", symbol); $0.set("action", action); $0.set("style", style?.rawValue)
            $0.set("tooltip", tooltip); $0.set("busy", busy); $0.set("enabled", enabled)
        })
    }
    private static func textInput(_ type: String, _ id: String, _ action: String, value: String?, placeholder: String?, title: String?, error: String?) -> Block {
        make(type, { $0.set("id", id); $0.set("action", action); $0.set("value", value); $0.set("placeholder", placeholder); $0.set("title", title); $0.set("error", error) })
    }
    /// Return commits; a click away commits. The action arrives with the text as `value`.
    public static func textField(_ id: String, action: String, value: String? = nil, placeholder: String? = nil, title: String? = nil, error: String? = nil) -> Block {
        textInput("textField", id, action, value: value, placeholder: placeholder, title: title, error: error)
    }
    public static func searchField(_ id: String, action: String, value: String? = nil, placeholder: String? = nil, title: String? = nil, error: String? = nil) -> Block {
        textInput("searchField", id, action, value: value, placeholder: placeholder, title: title, error: error)
    }
    /// ⌘Return commits; a click away commits.
    public static func textArea(_ id: String, action: String, value: String? = nil, placeholder: String? = nil, title: String? = nil, error: String? = nil) -> Block {
        textInput("textArea", id, action, value: value, placeholder: placeholder, title: title, error: error)
    }
    public static func toggle(_ id: String, action: String, value: Bool? = nil, title: String? = nil) -> Block {
        make("toggle", { $0.set("id", id); $0.set("action", action); $0.set("value", value); $0.set("title", title) })
    }
    public static func checkbox(_ id: String, action: String, value: Bool? = nil, title: String? = nil) -> Block {
        make("checkbox", { $0.set("id", id); $0.set("action", action); $0.set("value", value); $0.set("title", title) })
    }
    /// A menu, or `segmented: true`.
    public static func picker(_ id: String, action: String, options: [Option], value: String? = nil, segmented: Bool = false) -> Block {
        make("picker", {
            $0.set("id", id); $0.set("action", action); $0.set("options", JSONValue.array(options.map(\.json))); $0.set("value", value)
            if segmented { $0.set("style", "segmented") }
        })
    }
    public static func stepper(_ id: String, action: String, value: Double? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil) -> Block {
        make("stepper", { $0.set("id", id); $0.set("action", action); $0.set("value", value); $0.set("min", min); $0.set("max", max); $0.set("step", step) })
    }
    /// A "…" (or titled) menu.
    public static func menu(_ entries: [MenuEntry], id: String? = nil, title: String? = nil, symbol: String? = nil) -> Block {
        make("menu", { $0.set("id", id); $0.set("menu", JSONValue.array(entries.map(\.json))); $0.set("title", title); $0.set("symbol", symbol) })
    }
    /// `value` is `yyyy-MM-dd`.
    public static func datePicker(_ id: String, action: String, value: String? = nil) -> Block {
        make("datePicker", { $0.set("id", id); $0.set("action", action); $0.set("value", value) })
    }
    public static func tagPicker(_ id: String, action: String, tags: [String]? = nil, suggestions: [String]? = nil) -> Block {
        make("tagPicker", { $0.set("id", id); $0.set("action", action); $0.set("tags", tags); $0.set("suggestions", suggestions) })
    }
    /// A colour role, never a value. `roles` limits what it offers (sent as options with each role's name).
    public static func rolePicker(_ id: String, action: String, value: Role? = nil, roles: [Role]? = nil) -> Block {
        make("rolePicker", {
            $0.set("id", id); $0.set("action", action); $0.set("value", value?.rawValue)
            if let roles { $0.set("options", JSONValue.array(roles.map { ["value": .string($0.rawValue), "title": .string($0.title)] })) }
        })
    }

    // MARK: Feedback, files, web

    public static func spinner(id: String? = nil, text: String? = nil) -> Block { make("spinner", { $0.set("id", id); $0.set("text", text) }) }
    /// `progress` 0…1; nil: indeterminate.
    public static func progress(_ progress: Double? = nil, id: String? = nil, title: String? = nil, text: String? = nil) -> Block {
        make("progress", { $0.set("id", id); $0.set("progress", progress); $0.set("title", title); $0.set("text", text) })
    }
    /// Files and folders with Vektor's icons. Absolute paths; a folder ends in `/`.
    public static func fileList(_ files: [String], id: String? = nil) -> Block { make("fileList", { $0.set("id", id); $0.set("files", files) }) }
    /// A page of the plugin's own files (`entry`, inside the plugin folder). Inside a vertical scroll it takes `height`.
    public static func web(_ id: String, entry: String, height: Double? = nil) -> Block {
        make("web", { $0.set("id", id); $0.set("entry", entry); $0.set("height", height) })
    }
}

// MARK: - Checking a tree the way Vektor does

public enum BlockLimits {
    public static let maxBlocks = 100_000
    public static let maxDepth = 64
    /// What `width`, `minWidth` and `maxWidth` may be, in points.
    public static let widths: ClosedRange<Double> = 20...4000
    /// The fields that ask for a width (plus `grow`, true or false).
    public static let widthKeys = ["width", "minWidth", "maxWidth"]
    /// Every block type this SDK knows (the reference's table).
    public static let types: Set<String> = [
        "vstack", "hstack", "spacer", "divider", "grid", "scroll", "split", "section", "tabs", "tab", "card", "panel",
        "list", "row", "table", "tree", "node",
        "text", "symbol", "badge", "count", "markdown", "empty", "banner", "status", "diff",
        "button", "textField", "textArea", "searchField", "toggle", "picker", "stepper", "checkbox", "menu", "datePicker", "tagPicker", "rolePicker",
        "spinner", "progress", "fileList", "web",
    ]
    static let collections: Set<String> = ["list", "table", "tree"]
    static let inputs: Set<String> = ["textField", "textArea", "searchField", "toggle", "picker", "stepper", "checkbox", "datePicker", "tagPicker", "rolePicker"]
    static let needID: Set<String> = collections.union(inputs).union(["node", "tabs", "section", "split", "web"])
}

/// What Vektor would refuse in a block tree (one block, or a list read as a vertical stack), in plain words — empty when it
/// would draw it; and what it would ignore (a colour value, an unknown role). The same rules as Vektor's: every block has a
/// `type`; ids are unique; items of a collection, inputs, sections, tabs, splits, nodes and web blocks have an id; a button
/// has an action or a menu; a picker has options, each with a value and a title; a menu has items, each with a title and an
/// action; a table has columns, each with an id and a title; a web block has an entry; tabs hold only tabs; at most 100,000
/// blocks nested at most 64 deep. Like Vektor, it trims these strings: an empty or blank one counts as missing.
public func validateBlocks(_ blocks: JSONValue, existingIDs: Set<String> = []) -> (problems: [String], warnings: [String]) {
    validateBlocks(blocks, taken: existingIDs.isEmpty ? { _ in false } : { existingIDs.contains($0) })
}

/// The same, with the ids already in use asked of `taken` (a patch checks a block against a big tree's index without copying
/// a set of every id it holds).
func validateBlocks(_ blocks: JSONValue, taken: (String) -> Bool) -> (problems: [String], warnings: [String]) {
    var problems: [String] = []
    var warnings: [String] = []
    var seen = Set<String>()
    var nodes = 0
    /// A string with something in it besides white space: Vektor trims a required string and treats an empty one as missing.
    func filled(_ value: JSONValue?) -> Bool { value?.stringValue.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
    func visit(_ value: JSONValue, depth: Int, inCollection: String?) -> Bool {
        guard depth <= BlockLimits.maxDepth else { problems.append("blocks are nested more than \(BlockLimits.maxDepth) deep."); return false }
        nodes += 1
        guard nodes <= BlockLimits.maxBlocks else { problems.append("a view can hold at most \(BlockLimits.maxBlocks) blocks."); return false }
        guard case .object(let block) = value else { problems.append("every block must be an object."); return false }
        guard let type = block["type"]?.stringValue, filled(block["type"]) else { problems.append("every block needs a “type”."); return false }
        let id = filled(block["id"]) ? block["id"]?.stringValue : nil
        if let id {
            guard !taken(id), seen.insert(id).inserted else { problems.append("the block “\(id)” is listed twice."); return false }
        } else if let inCollection {
            problems.append("every item of “\(inCollection)” needs an “id”.")
            return false
        } else if BlockLimits.needID.contains(type) {
            problems.append("a “\(type)” block needs an “id”.")
            return false
        }
        let name = id ?? type
        for key in Role.colourValueKeys where block[key] != nil {
            warnings.append("the block “\(name)” carries a colour value (“\(key)”), which Vektor ignores: name a “role” instead.")
        }
        guard BlockLimits.types.contains(type) else {
            warnings.append("“\(type)” is not a block type this SDK knows; an older Vektor draws it as “needs a newer Vektor”.")
            return true
        }
        if let role = block["role"], Role(rawValue: role.stringValue ?? "") == nil {
            warnings.append("the block “\(name)” names a colour role Vektor does not know (\(role.jsonText)).")
        }
        for key in BlockLimits.widthKeys {
            guard let value = block[key], value != .null else { continue }
            if !(value.numberValue.map { $0.isFinite && BlockLimits.widths.contains($0) } ?? false) {
                warnings.append("the block “\(name)” asks for a “\(key)” of \(value.jsonText), which Vektor ignores: a number of points from 20 to 4000.")
            }
        }
        if let grow = block["grow"], grow != .null, grow.boolValue == nil {
            warnings.append("the block “\(name)” has a “grow” of \(grow.jsonText), which Vektor reads as false: “grow” is true or false.")
        }
        func lacks(_ key: String) -> Bool { block[key] == nil || block[key]?.arrayValue?.isEmpty == true }
        if type == "button", !filled(block["action"]), lacks("menu") { problems.append("the button “\(name)” needs an “action”.") }
        if type == "picker", lacks("options") { problems.append("the picker “\(name)” needs “options”.") }
        if type == "menu", lacks("menu") { problems.append("the menu “\(name)” needs items in “menu”.") }
        if type == "table", lacks("columns") { problems.append("the table “\(name)” needs “columns”.") }
        if type == "web", !filled(block["entry"]) { problems.append("the web block “\(name)” needs an “entry”: the page to show.") }
        if let options = block["options"]?.arrayValue,
            options.contains(where: { !filled($0["value"]) || !filled($0["title"]) })
        {
            problems.append("every option of “\(name)” needs a “value” and a “title”.")
        }
        if let menu = block["menu"]?.arrayValue,
            menu.contains(where: { $0["separator"] != .bool(true) && (!filled($0["title"]) || !filled($0["action"])) })
        {
            problems.append("a menu item of “\(name)” needs a “title” and an “action”.")
        }
        if type == "table", let columns = block["columns"]?.arrayValue, columns.contains(where: { !filled($0["id"]) || !filled($0["title"]) }) {
            problems.append("every column of “\(name)” needs an “id” and a “title”.")
        }
        if let raw = block["children"], raw != .null {
            guard case .array(let children) = raw else { problems.append("the “children” of “\(name)” must be a list."); return false }
            if type == "tabs", children.contains(where: { child in
                guard let childType = child["type"]?.stringValue else { return false }
                return childType != "tab" && BlockLimits.types.contains(childType)
            }) {
                problems.append("every child of the tabs “\(name)” must be a “tab”.")
            }
            let collection = BlockLimits.collections.contains(type) || type == "node" ? name : nil
            for child in children where !visit(child, depth: depth + 1, inCollection: collection) { return false }
        }
        return true
    }
    let root: JSONValue = blocks.arrayValue.map { ["type": "vstack", "children": .array($0)] } ?? blocks
    _ = visit(root, depth: 0, inCollection: nil)
    return (problems, warnings)
}

/// `validateBlocks` for built blocks.
public func validateBlocks(_ blocks: [Block]) -> (problems: [String], warnings: [String]) {
    validateBlocks(.array(blocks.map(\.json)))
}
public func validateBlocks(_ block: Block) -> (problems: [String], warnings: [String]) { validateBlocks(block.json) }
