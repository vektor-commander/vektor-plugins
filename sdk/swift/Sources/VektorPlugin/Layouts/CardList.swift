import Foundation

// Card list: a column of cards, each with a symbol, a title, a pill, some lines of text and buttons — the look of the
// `cardList` view kind, built from blocks (so it can also sit beside other blocks, and be patched by id).
//
//     try view.show(ViewDescription(root: cards.block))
//     cards.route(on: view, menuKeys: ["delete"], CardListHandlers(onOpen: { card in … }))
//
// Copy and adapt.

/// A button at a card's right. `key` comes back in `onButton`; it is a word without dots (the card's id may have them).
public struct CardButton: Equatable, Sendable {
    public var key: String
    public var title: String?
    public var symbol: String?
    public var tooltip: String?
    public var enabled: Bool?
    public init(key: String, title: String? = nil, symbol: String? = nil, tooltip: String? = nil, enabled: Bool? = nil) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.tooltip = tooltip
        self.enabled = enabled
    }
}

public enum CardMenuEntry: Equatable, Sendable {
    case item(key: String, title: String, symbol: String? = nil, destructive: Bool? = nil, enabled: Bool? = nil)
    case separator
}

/// A line of text under a card's title; one with a `link` opens it in the browser when clicked (needs `openURLs`).
public struct CardLine: Equatable, Sendable, ExpressibleByStringLiteral {
    public var text: String
    public var link: String?
    public init(_ text: String, link: String? = nil) {
        self.text = text
        self.link = link
    }
    public init(stringLiteral value: String) { text = value }
}

public struct CardItem: Equatable, Sendable {
    public var id: String
    public var symbol: String?
    public var title: String
    /// A word on a tinted capsule beside the title.
    public var pill: Badge?
    public var lines: [CardLine]
    /// The card reacts to Return or a double-click (`onOpen`).
    public var openable: Bool
    /// Buttons at the right.
    public var buttons: [CardButton]
    /// The card's context menu.
    public var menu: [CardMenuEntry]
    public init(id: String, title: String, symbol: String? = nil, pill: Badge? = nil, lines: [CardLine] = [], openable: Bool = false,
                buttons: [CardButton] = [], menu: [CardMenuEntry] = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.pill = pill
        self.lines = lines
        self.openable = openable
        self.buttons = buttons
        self.menu = menu
    }
}

public struct CardListHandlers {
    public var onOpen: LayoutAction<String>?
    /// A card's button: the card, the button's key.
    public var onButton: LayoutAction2<String, String>?
    /// An entry of a card's menu (the "…" or a right-click): the card, the entry's key.
    public var onMenu: LayoutAction2<String, String>?
    public init(onOpen: LayoutAction<String>? = nil, onButton: LayoutAction2<String, String>? = nil, onMenu: LayoutAction2<String, String>? = nil) {
        self.onOpen = onOpen
        self.onButton = onButton
        self.onMenu = onMenu
    }
}

public struct CardList {
    /// Prefix of every block id and action (default `cards`).
    public var id = "cards"
    public var cards: [CardItem]
    /// Shown instead of the cards when there are none.
    public var empty: (title: String?, text: String, symbol: String?) = (nil, "Nothing here.", nil)
    public init(cards: [CardItem]) { self.cards = cards }

    private var names: LayoutNames { LayoutNames(id) }

    private func cardBlock(_ item: CardItem) throws -> Block {
        let names = self.names
        // A button's id is `cards.button.<key>.<card id>`, and a card id may contain dots, so the key may not: `open.url` on the
        // card `k1` could not be told apart from `open` on the card `url.k1`.
        if let bad = item.buttons.first(where: { $0.key.isEmpty || $0.key.contains(".") }) {
            throw PluginError("The button key “\(bad.key)” of the card “\(item.id)” must be a word without dots.")
        }
        let lines = item.lines.enumerated().map { index, line in
            Block.text(line.text, id: names.id("line", item.id, String(index)), style: .caption, link: line.link, lineLimit: 3)
        }
        let buttons = item.buttons.map {
            Block.button(
                id: names.id("button", $0.key, item.id), title: $0.title, symbol: $0.symbol, action: names.id("button"),
                style: $0.title == nil ? .icon : .plain, tooltip: $0.tooltip, enabled: $0.enabled)
        }
        let entries: [MenuEntry] = item.menu.map {
            switch $0 {
            case .separator: return .separator
            case .item(let key, let title, let symbol, let destructive, let enabled):
                return .item(title: title, action: names.id("menu", key), symbol: symbol, destructive: destructive, enabled: enabled)
            }
        }
        var body: [Block] = lines.isEmpty ? [] : [.vstack(lines, id: names.id("lines", item.id))]
        body.append(.spacer())
        body += buttons
        if !entries.isEmpty { body.append(.menu(entries, id: names.id("more", item.id))) }
        var block = Block.card(
            [.hstack(body, id: names.id("body", item.id))], id: item.id, title: item.title, symbol: item.symbol, badge: item.pill,
            action: item.openable ? names.id("open") : nil)
        if !entries.isEmpty { block = block.menu(entries) }
        return block
    }

    /// The card list as one block. Throws for a button key that is empty or contains a dot.
    public var block: Block {
        get throws {
            if cards.isEmpty { return .empty(empty.text, id: id, title: empty.title, symbol: empty.symbol) }
            // A list, not a stack in a scroll: only a collection's items get Return and a double-click (`onOpen`), and a list
            // scrolls by itself. Nothing is selected in it; `spacing` keeps the cards apart.
            return .list(id, try cards.map(cardBlock), selection: Selection.none, spacing: 8)
        }
    }

    /// Sends the card list's events to `handlers`. Call once. `menuKeys` lists the keys of every menu entry any card can have
    /// (an action is routed by its exact text, so each needs registering).
    @MainActor
    public func route(on view: ViewState, menuKeys: [String] = [], _ handlers: CardListHandlers) {
        let names = self.names
        view.on(names.id("open")) { event in
            if let card = event.block { try await handlers.onOpen?(card) }
        }
        view.on(names.id("button")) { event in
            // The button's id is `cards.button.<key>.<card id>`; the key has no dot, the card id may.
            guard let rest = names.rest("button", of: event.block), let dot = rest.firstIndex(of: "."), dot != rest.startIndex else { return }
            try await handlers.onButton?(String(rest[rest.index(after: dot)...]), String(rest[..<dot]))
        }
        for key in menuKeys {
            // A menu item's event names the block that carries the menu: the card, or its "…" block.
            view.on(names.id("menu", key)) { event in
                if let card = names.rest("more", of: event.block) ?? event.block { try await handlers.onMenu?(card, key) }
            }
        }
    }
}
