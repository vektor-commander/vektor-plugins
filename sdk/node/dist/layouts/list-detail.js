"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.listDetail = listDetail;
exports.detailPanel = detailPanel;
exports.routeListDetail = routeListDetail;
// List with detail: a split view — a searchable list on the left, the chosen item on the right.
//
//     view.show({ blocks: listDetail({ items, selected, search, detail: detailPanel(…) }) });
//     routeListDetail(view, {}, { onSelect, onSearch, onDetailAction });
//
// The layout owns the arrangement (the draggable divider, the search field, the list with single selection); YOU own what the
// right side shows: `detail` is any blocks you like. `detailPanel` below builds the usual one (a heading, label/value rows,
// Markdown, buttons) so you can start from it. Copy and adapt.
const blocks_1 = require("../blocks");
const support_1 = require("./support");
/** The two panes as one block. */
function listDetail(spec) {
    const prefix = spec.id ?? 'listDetail';
    const shown = spec.items.filter((item) => (0, support_1.matches)(spec.search, item.title, item.subtitle));
    const left = (0, blocks_1.vstack)([
        (0, blocks_1.hstack)([
            (0, blocks_1.searchField)((0, support_1.scoped)(prefix, 'search'), (0, support_1.scoped)(prefix, 'search'), { value: spec.search ?? '', placeholder: 'Search' }),
            ...(spec.toolbar ?? []),
        ], { id: (0, support_1.scoped)(prefix, 'bar') }),
        (0, blocks_1.list)((0, support_1.scoped)(prefix, 'list'), shown.map((item) => (0, blocks_1.row)(item.id, {
            title: item.title, subtitle: item.subtitle, symbol: item.symbol, badge: item.badge, dimmed: item.dimmed,
            action: (0, support_1.scoped)(prefix, 'open'), // Return or a double-click
        })), {
            selection: 'single', select: (0, support_1.scoped)(prefix, 'select'),
            selected: spec.selected !== undefined && shown.some((item) => item.id === spec.selected) ? [spec.selected] : undefined,
            placeholder: spec.placeholder ?? 'Nothing found',
        }),
    ], { id: (0, support_1.scoped)(prefix, 'left') });
    const empty_ = spec.emptyDetail ?? { text: 'Choose an item.' };
    const right = (0, blocks_1.vstack)(spec.selected !== undefined && spec.detail ? spec.detail : [(0, blocks_1.empty)(empty_.text, { id: (0, support_1.scoped)(prefix, 'nothing'), title: empty_.title, symbol: empty_.symbol })], { id: (0, support_1.scoped)(prefix, 'right') });
    return (0, blocks_1.split)((0, support_1.scoped)(prefix, 'split'), left, right, { axis: 'horizontal', fraction: spec.fraction ?? 0.38 });
}
/** The usual right-hand side: heading, fields, Markdown, buttons. Pass the same `id` as the layout's. */
function detailPanel(spec) {
    const prefix = spec.id ?? 'listDetail';
    const out = [
        (0, blocks_1.hstack)([
            ...(spec.symbol ? [(0, blocks_1.symbol)(spec.symbol, { id: (0, support_1.scoped)(prefix, 'detail', 'symbol') })] : []),
            (0, blocks_1.vstack)([
                (0, blocks_1.text)(spec.title, { id: (0, support_1.scoped)(prefix, 'detail', 'title'), style: 'title', selectable: true }),
                ...(spec.subtitle ? [(0, blocks_1.text)(spec.subtitle, { id: (0, support_1.scoped)(prefix, 'detail', 'subtitle'), style: 'caption' })] : []),
            ]),
        ], { id: (0, support_1.scoped)(prefix, 'detail', 'heading') }),
    ];
    (spec.fields ?? []).forEach((field, index) => out.push((0, blocks_1.hstack)([
        (0, blocks_1.text)(field.label, { id: (0, support_1.scoped)(prefix, 'field', String(index), 'label'), style: 'caption' }),
        (0, blocks_1.spacer)(),
        (0, blocks_1.text)(field.value, { id: (0, support_1.scoped)(prefix, 'field', String(index), 'value'), selectable: true }),
    ], { id: (0, support_1.scoped)(prefix, 'field', String(index)) })));
    if (spec.markdown)
        out.push((0, blocks_1.markdown)(spec.markdown, { id: (0, support_1.scoped)(prefix, 'detail', 'markdown') }));
    if ((spec.actions ?? []).length > 0) {
        out.push((0, blocks_1.hstack)((spec.actions ?? []).map((action) => (0, blocks_1.button)({
            id: (0, support_1.scoped)(prefix, 'action', action.key), title: action.title, symbol: action.symbol, style: action.style,
            enabled: action.enabled, action: (0, support_1.scoped)(prefix, 'action'),
        })), { id: (0, support_1.scoped)(prefix, 'actions') }));
    }
    return out;
}
/** Sends the layout's events to `handlers`. Call once, when the view is set up. */
function routeListDetail(view, options, handlers) {
    const prefix = options.id ?? 'listDetail';
    view.on((0, support_1.scoped)(prefix, 'select'), (event) => handlers.onSelect?.((event.selected ?? [])[0], event));
    view.on((0, support_1.scoped)(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
    view.on((0, support_1.scoped)(prefix, 'search'), (event) => handlers.onSearch?.((0, support_1.textOf)(event.value), event));
    view.on((0, support_1.scoped)(prefix, 'action'), (event) => {
        const key = (0, support_1.unscoped)(prefix, 'action', event.block);
        return key === undefined ? undefined : handlers.onDetailAction?.(key, event);
    });
}
