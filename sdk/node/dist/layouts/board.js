"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.BOARD_GROUP = exports.DEFAULT_COLUMN_MENU = void 0;
exports.boardShows = boardShows;
exports.boardFilterAll = boardFilterAll;
exports.board = board;
exports.routeBoard = routeBoard;
exports.moveCard = moveCard;
// Board: columns of cards (a kanban board).
//
// What it draws, per column: a title, a count of the cards shown ("2 of 5" while a search or filter hides some), a "+" button and a "…" menu. Cards can be dragged between
// columns and, with the keyboard, moved with ⌥ + an arrow — Vektor does both (the lists share a drag `group` and have `move`);
// the layout only hears the result as `onMove`. Above the columns: a search field, an optional filter (a picker over the
// cards' tags) and a toolbar slot for your own blocks (a Sync button, say).
//
// Two functions, used together:
//
//     view.show({ header: { title: 'Roadmap' }, blocks: board(state) });     // draw
//     routeBoard(view, {}, { onMove, onAdd, … });                             // listen, once
//
// Copy this file and change it: it is a composition of blocks, not a new kind of block.
//
// Vektor shows a move only when your next description says so, so `onMove` is where you change YOUR data (`moveCard` below
// does it for the usual shape) and call `view.show` again. The SDK turns the difference into one `move` patch.
const blocks_1 = require("../blocks");
const support_1 = require("./support");
exports.DEFAULT_COLUMN_MENU = [
    { key: 'rename', title: 'Rename Column', symbol: 'pencil' },
    { key: 'delete', title: 'Delete Column', symbol: 'trash', destructive: true },
];
/** The drag group every list shares, so cards move between columns. */
exports.BOARD_GROUP = 'cards';
/** Whether a card shows under the spec's search and filter. */
function boardShows(spec, cardItem) {
    const tag = spec.filter?.value ?? '';
    const tagOK = tag === '' || (cardItem.tags ?? []).some((candidate) => candidate.text === tag);
    return tagOK && (0, support_1.matches)(spec.search, cardItem.title, cardItem.subtitle, ...(cardItem.tags ?? []).map((candidate) => candidate.text));
}
function cardBlock(prefix, item) {
    const children = [];
    if (item.subtitle)
        children.push((0, blocks_1.text)(item.subtitle, { id: (0, support_1.scoped)(prefix, 'subtitle', item.id), style: 'caption' }));
    (item.tags ?? []).forEach((tag, index) => children.push((0, blocks_1.badge)(tag.text, { id: (0, support_1.scoped)(prefix, 'tag', item.id, String(index)), role: tag.role })));
    return (0, blocks_1.card)(children, {
        id: item.id, title: item.title, role: item.role,
        edit: (0, support_1.scoped)(prefix, 'rename'), // Return or a double-click: the title edited in place
        delete: (0, support_1.scoped)(prefix, 'remove'), // ⌫ / ⌘⌫
        // Vektor gives `edit` precedence over `action` on Return and a double-click, so a card that can be renamed is opened from
        // its context menu. A menu item's event names the block carrying the menu: the card.
        menu: [{ title: 'Open', action: (0, support_1.scoped)(prefix, 'open') }],
    });
}
function columnBlock(prefix, spec, column) {
    const shown = column.cards.filter((item) => boardShows(spec, item));
    const menuEntries = (spec.columnMenu ?? exports.DEFAULT_COLUMN_MENU).map((entry) => ({
        title: entry.title, action: (0, support_1.scoped)(prefix, 'column', entry.key), symbol: entry.symbol, destructive: entry.destructive,
    }));
    // The count is a block of its own, not the panel's `badge`: a card that moves changes two counts, and a change in a panel's
    // own fields would make the SDK replace the whole column (all its cards) instead of sending one small `move`.
    // With a search or filter on, it also says how many there are.
    const countID = (0, support_1.scoped)(prefix, 'count', column.id);
    const header = (0, blocks_1.hstack)([
        shown.length === column.cards.length
            ? (0, blocks_1.count)(shown.length, { id: countID })
            : (0, blocks_1.badge)(`${shown.length} of ${column.cards.length}`, { id: countID }),
        (0, blocks_1.spacer)(),
        (0, blocks_1.button)({ id: (0, support_1.scoped)(prefix, 'add', column.id), symbol: 'plus', style: 'icon', tooltip: 'Add a card', action: (0, support_1.scoped)(prefix, 'add') }),
        ...(menuEntries.length > 0 ? [(0, blocks_1.menu)(menuEntries, { id: (0, support_1.scoped)(prefix, 'colmenu', column.id), label: `${column.title} actions` })] : []),
    ], { id: (0, support_1.scoped)(prefix, 'head', column.id) });
    return (0, blocks_1.panel)([
        header,
        (0, blocks_1.list)((0, support_1.scoped)(prefix, 'list', column.id), shown.map((item) => cardBlock(prefix, item)), {
            group: exports.BOARD_GROUP, move: (0, support_1.scoped)(prefix, 'move'), placeholder: spec.placeholder ?? 'No cards',
        }),
    ], {
        id: (0, support_1.scoped)(prefix, 'col', column.id), title: column.title, role: column.role,
        ...(spec.columnMinWidth !== undefined ? { grow: true, minWidth: spec.columnMinWidth } : {}),
    });
}
/** Vektor refuses an option whose value is empty, so the "All" option's `''` goes out as this value and comes back as `''`. */
function boardFilterAll(prefix = 'board') {
    return (0, support_1.scoped)(prefix, 'all');
}
const filterOut = (prefix, value) => (value === '' ? boardFilterAll(prefix) : value);
const filterIn = (prefix, value) => (value === boardFilterAll(prefix) ? '' : value);
/** The board as one block: a bar (search, filter, your toolbar) over the columns, which scroll sideways. */
function board(spec) {
    const prefix = spec.id ?? 'board';
    const bar = [(0, blocks_1.searchField)((0, support_1.scoped)(prefix, 'search'), (0, support_1.scoped)(prefix, 'search'), { value: spec.search ?? '', placeholder: 'Search cards' })];
    if (spec.filter) {
        const options = spec.filter.options.map((option) => ({ ...option, value: filterOut(prefix, option.value) }));
        bar.push((0, blocks_1.picker)((0, support_1.scoped)(prefix, 'filter'), (0, support_1.scoped)(prefix, 'filter'), options, { value: filterOut(prefix, spec.filter.value ?? '') }));
    }
    bar.push((0, blocks_1.spacer)(), ...(spec.toolbar ?? []));
    return (0, blocks_1.vstack)([
        (0, blocks_1.hstack)(bar, { id: (0, support_1.scoped)(prefix, 'bar') }),
        (0, blocks_1.scroll)([(0, blocks_1.hstack)(spec.columns.map((column) => columnBlock(prefix, spec, column)), { id: (0, support_1.scoped)(prefix, 'columns') })], { id: (0, support_1.scoped)(prefix, 'scroll'), axis: 'horizontal' }),
    ], { id: prefix });
}
/**
 * Sends the board's events to `handlers`. Call once, when the view is set up. `options` must be the `id` and `columnMenu`
 * you draw the board with.
 *
 * Moves made against an older description are dropped by the view state (the default `ignoreMoves` policy), because "put it
 * at index 3" no longer means what the user saw.
 */
function routeBoard(view, options, handlers) {
    const prefix = options.id ?? 'board';
    view.on((0, support_1.scoped)(prefix, 'add'), (event) => {
        const column = (0, support_1.unscoped)(prefix, 'add', event.block);
        return column === undefined ? undefined : handlers.onAdd?.(column, event);
    });
    view.on((0, support_1.scoped)(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
    view.on((0, support_1.scoped)(prefix, 'rename'), (event) => (event.block === undefined ? undefined : handlers.onRename?.(event.block, (0, support_1.textOf)(event.value), event)));
    view.on((0, support_1.scoped)(prefix, 'remove'), (event) => (event.block === undefined ? undefined : handlers.onRemove?.(event.block, event)));
    view.on((0, support_1.scoped)(prefix, 'move'), (event) => {
        const to = (0, support_1.unscoped)(prefix, 'list', event.target);
        if (event.item === undefined || to === undefined)
            return undefined;
        return handlers.onMove?.({ card: event.item, from: (0, support_1.unscoped)(prefix, 'list', event.from), to, index: event.index ?? 0 }, event);
    });
    for (const entry of options.columnMenu ?? exports.DEFAULT_COLUMN_MENU) {
        // A menu item's event names the block that carries the menu: the column's "…" block.
        view.on((0, support_1.scoped)(prefix, 'column', entry.key), (event) => {
            const column = (0, support_1.unscoped)(prefix, 'colmenu', event.block);
            return column === undefined ? undefined : handlers.onColumnAction?.(column, entry.key, event);
        });
    }
    view.on((0, support_1.scoped)(prefix, 'search'), (event) => handlers.onSearch?.((0, support_1.textOf)(event.value), event));
    view.on((0, support_1.scoped)(prefix, 'filter'), (event) => handlers.onFilter?.(filterIn(prefix, (0, support_1.textOf)(event.value)), event));
}
/**
 * Applies a move to your columns: the card leaves its column and goes into `to` at the position `index` counts among the
 * cards that are shown (a search or filter may hide some; they keep their place). Returns false when the card or the column
 * is unknown. This is the usual `onMove`:
 *
 *     onMove: (move) => { if (moveCard(columns, move, (c) => boardShows(spec, c))) draw(); }
 */
function moveCard(columns, move, isShown = () => true) {
    const source = columns.find((column) => column.cards.some((item) => item.id === move.card));
    const target = columns.find((column) => column.id === move.to);
    if (!source || !target)
        return false;
    const [moving] = source.cards.splice(source.cards.findIndex((item) => item.id === move.card), 1);
    // `index` counts shown cards only: find the shown card that must come right after, and insert before it.
    const shown = target.cards.filter(isShown);
    const next = shown[move.index];
    const at = next === undefined ? target.cards.length : target.cards.indexOf(next);
    target.cards.splice(at, 0, moving);
    return true;
}
