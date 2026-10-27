"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.cardList = cardList;
exports.routeCardList = routeCardList;
// Card list: a column of cards, each with a symbol, a title, a pill, some lines of text and buttons — the look of the
// `cardList` view kind, built from blocks (so it can also sit beside other blocks, and be patched by id).
//
//     view.show({ blocks: cardList({ cards, empty: { text: 'No tunnels yet.' } }) });
//     routeCardList(view, { menuKeys: ['delete'] }, { onOpen, onButton, onMenu });
//
// Copy and adapt.
const blocks_1 = require("../blocks");
const errors_1 = require("../errors");
const support_1 = require("./support");
function cardBlock(prefix, item) {
    const lines = (item.lines ?? []).map((line, index) => {
        const spec = typeof line === 'string' ? { text: line } : line;
        return (0, blocks_1.text)(spec.text, { id: (0, support_1.scoped)(prefix, 'line', item.id, String(index)), style: 'caption', link: spec.link, lineLimit: 3 });
    });
    // A button's id is `cards.button.<key>.<card id>`, and a card id may contain dots, so the key may not: `open.url` on the card
    // `k1` could not be told apart from `open` on the card `url.k1`.
    const bad = (item.buttons ?? []).find((entry) => entry.key === '' || entry.key.includes('.'));
    if (bad)
        throw new errors_1.PluginError(`The button key “${bad.key}” of the card “${item.id}” must be a word without dots.`);
    const buttons = (item.buttons ?? []).map((entry) => (0, blocks_1.button)({
        id: (0, support_1.scoped)(prefix, 'button', entry.key, item.id), title: entry.title, symbol: entry.symbol, tooltip: entry.tooltip,
        style: entry.title === undefined ? 'icon' : 'plain', action: (0, support_1.scoped)(prefix, 'button'), enabled: entry.enabled,
    }));
    const entries = (item.menu ?? []).map((entry) => 'separator' in entry ? { separator: true } : {
        title: entry.title, action: (0, support_1.scoped)(prefix, 'menu', entry.key), symbol: entry.symbol, destructive: entry.destructive, enabled: entry.enabled,
    });
    return (0, blocks_1.card)([(0, blocks_1.hstack)([...(lines.length > 0 ? [(0, blocks_1.vstack)(lines, { id: (0, support_1.scoped)(prefix, 'lines', item.id) })] : []), (0, blocks_1.spacer)(), ...buttons, ...(entries.length > 0 ? [(0, blocks_1.menu)(entries, { id: (0, support_1.scoped)(prefix, 'more', item.id) })] : [])], { id: (0, support_1.scoped)(prefix, 'body', item.id) })], {
        id: item.id, title: item.title, symbol: item.symbol,
        badge: item.pill ? { text: item.pill.label, role: item.pill.role } : undefined,
        action: item.openable ? (0, support_1.scoped)(prefix, 'open') : undefined,
        menu: entries.length > 0 ? entries : undefined,
    });
}
/** The card list as one block. Throws a `PluginError` for a button key that is empty or contains a dot. */
function cardList(spec) {
    const prefix = spec.id ?? 'cards';
    if (spec.cards.length === 0) {
        const note = spec.empty ?? { text: 'Nothing here.' };
        return (0, blocks_1.empty)(note.text, { id: prefix, title: note.title, symbol: note.symbol });
    }
    // A list, not a stack in a scroll: only a collection's items get Return and a double-click (`onOpen`), and a list scrolls
    // by itself. Nothing is selected in it; `spacing` keeps the cards apart.
    return (0, blocks_1.list)(prefix, spec.cards.map((item) => cardBlock(prefix, item)), { selection: 'none', spacing: 8 });
}
/**
 * Sends the card list's events to `handlers`. Call once. `menuKeys` lists the keys of every menu entry any card can have
 * (an action is routed by its exact text, so each needs registering).
 */
function routeCardList(view, options, handlers) {
    const prefix = options.id ?? 'cards';
    view.on((0, support_1.scoped)(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
    view.on((0, support_1.scoped)(prefix, 'button'), (event) => {
        // The button's id is `cards.button.<key>.<card id>`; the key has no dot, the card id may.
        const rest = (0, support_1.unscoped)(prefix, 'button', event.block);
        const dot = rest?.indexOf('.') ?? -1;
        return rest === undefined || dot < 1 ? undefined : handlers.onButton?.(rest.slice(dot + 1), rest.slice(0, dot), event);
    });
    for (const key of options.menuKeys ?? []) {
        // A menu item's event names the block that carries the menu: the card, or its "…" block.
        view.on((0, support_1.scoped)(prefix, 'menu', key), (event) => {
            const more = (0, support_1.unscoped)(prefix, 'more', event.block);
            const card = more ?? event.block;
            return card === undefined ? undefined : handlers.onMenu?.(card, key, event);
        });
    }
}
