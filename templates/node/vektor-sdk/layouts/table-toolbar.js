"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sortRows = sortRows;
exports.tableWithToolbar = tableWithToolbar;
exports.routeTable = routeTable;
// Table with toolbar: sortable columns, multiple selection and a toolbar of buttons above.
//
//     view.show({ blocks: tableWithToolbar({ columns, rows: sortRows(rows, columns, sorted), sorted, selected, toolbar }) });
//     routeTable(view, {}, { onSort, onSelect, onToolbar, onSearch, onOpen, onDelete });
//
// Vektor does not sort for you: it shows the arrow and tells you which column and direction the user chose (`onSort`); you
// sort your rows (`sortRows` does the usual comparison) and describe the table again. The same goes for the selection: keep
// the ids `onSelect` gives you and pass them back as `selected` (they decide the "N selected" text and which buttons are on,
// and Vektor starts from them when it has no selection of its own: the first time, and after the view is reopened).
//
// Vektor keeps only the selected rows that are still described, without telling you (a search that hides a selected row
// unselects it). The layout does the same: what it draws and what `onToolbar` reports count only the rows shown. Copy and adapt.
const blocks_1 = require("../blocks");
const support_1 = require("./support");
/** Rows in the order a sorted column asks for: numbers as numbers, text the way the user's language orders it. */
function sortRows(rows, columns, sorted) {
    const at = sorted ? columns.findIndex((column) => column.id === sorted.column) : -1;
    if (!sorted || at < 0)
        return [...rows];
    const direction = sorted.ascending ? 1 : -1;
    return [...rows].sort((a, b) => {
        const x = a.cells[at];
        const y = b.cells[at];
        const order = typeof x === 'number' && typeof y === 'number' ? x - y : String(x ?? '').localeCompare(String(y ?? ''), undefined, { numeric: true });
        return direction * Math.sign(order);
    });
}
function tableWithToolbar(spec) {
    const prefix = spec.id ?? 'table';
    const shown = spec.rows.filter((item) => (0, support_1.matches)(spec.search, ...item.cells.map(String)));
    // Only rows still shown can be selected: Vektor drops the others from its selection, silently.
    const shownIDs = new Set(shown.map((item) => item.id));
    const selected = (spec.selected ?? []).filter((id) => shownIDs.has(id));
    const bar = (0, blocks_1.hstack)([
        (0, blocks_1.searchField)((0, support_1.scoped)(prefix, 'search'), (0, support_1.scoped)(prefix, 'search'), { value: spec.search ?? '', placeholder: 'Search' }),
        ...(spec.toolbar ?? []).map((entry) => (0, blocks_1.button)({
            id: (0, support_1.scoped)(prefix, 'tool', entry.key), title: entry.title, symbol: entry.symbol, tooltip: entry.tooltip, style: entry.style,
            action: (0, support_1.scoped)(prefix, 'tool'), enabled: entry.enabled === false ? false : entry.needsSelection && selected.length === 0 ? false : undefined,
        })),
        (0, blocks_1.spacer)(),
        // The count is words, so VoiceOver and a colour-blind reader get it too.
        ...(selected.length > 0 ? [(0, blocks_1.text)(`${selected.length} selected`, { id: (0, support_1.scoped)(prefix, 'count'), style: 'caption' })] : []),
        ...(spec.extra ?? []),
    ], { id: (0, support_1.scoped)(prefix, 'bar') });
    return (0, blocks_1.vstack)([
        bar,
        (0, blocks_1.table)((0, support_1.scoped)(prefix, 'table'), spec.columns, shown.map((item) => (0, blocks_1.row)(item.id, {
            cells: item.cells, dimmed: item.dimmed,
            action: (0, support_1.scoped)(prefix, 'open'), // Return or a double-click
            delete: (0, support_1.scoped)(prefix, 'delete'), // ⌫
        })), {
            selection: 'multiple', select: (0, support_1.scoped)(prefix, 'select'), selected: selected.length > 0 ? selected : undefined,
            sorted: spec.sorted, sort: (0, support_1.scoped)(prefix, 'sort'),
        }),
    ], { id: prefix });
}
/** Sends the table's events to `handlers`. Call once, when the view is set up. */
function routeTable(view, options, handlers) {
    const prefix = options.id ?? 'table';
    // What `select` said last; undefined until it says something after the view opens, because a reopened view starts with no
    // selection of Vektor's own and shows the `selected` it was described with.
    let heard;
    view.onOpen(() => { heard = undefined; });
    // The selection the user sees: what was heard (or described), less the rows the table no longer has.
    const visible = () => {
        const table = (0, support_1.describedBlock)(view, (0, support_1.scoped)(prefix, 'table'));
        const rows = new Set((table?.children ?? []).map((item) => item.id));
        const selected = heard ?? (Array.isArray(table?.selected) ? table.selected : []);
        return selected.filter((id) => rows.has(id));
    };
    view.on((0, support_1.scoped)(prefix, 'sort'), (event) => (event.column === undefined ? undefined : handlers.onSort?.(event.column, event.ascending !== false, event)));
    view.on((0, support_1.scoped)(prefix, 'select'), (event) => {
        heard = event.selected ?? [];
        return handlers.onSelect?.(heard, event);
    });
    view.on((0, support_1.scoped)(prefix, 'tool'), (event) => {
        const key = (0, support_1.unscoped)(prefix, 'tool', event.block);
        return key === undefined ? undefined : handlers.onToolbar?.(key, visible(), event);
    });
    view.on((0, support_1.scoped)(prefix, 'search'), (event) => handlers.onSearch?.((0, support_1.textOf)(event.value), event));
    view.on((0, support_1.scoped)(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
    view.on((0, support_1.scoped)(prefix, 'delete'), (event) => (event.block === undefined ? undefined : handlers.onDelete?.(event.block, event)));
}
