// List with detail: a split view — a searchable list on the left, the chosen item on the right.
//
//     view.show({ blocks: listDetail({ items, selected, search, detail: detailPanel(…) }) });
//     routeListDetail(view, {}, { onSelect, onSearch, onDetailAction });
//
// The layout owns the arrangement (the draggable divider, the search field, the list with single selection); YOU own what the
// right side shows: `detail` is any blocks you like. `detailPanel` below builds the usual one (a heading, label/value rows,
// Markdown, buttons) so you can start from it. Copy and adapt.
import {
  button, empty, hstack, list, markdown, row, searchField, spacer, split, symbol, text, vstack,
  type Badge, type Block,
} from '../blocks';
import type { ViewEvent, ViewState } from '../view';
import { matches, scoped, textOf, unscoped } from './support';

export interface ListDetailItem { id: string; title: string; subtitle?: string; symbol?: string; badge?: Badge; dimmed?: boolean }

export interface ListDetailSpec {
  /** Prefix of every block id and action (default `listDetail`). */
  id?: string;
  items: ListDetailItem[];
  /** The id of the chosen item, if any (what you heard from `onSelect`). It decides whether the right side shows `detail`, and
   *  while the item is shown it is sent as the list's `selected`: Vektor starts from it when it has no selection of its own
   *  (the first time, after the view is reopened, after the selected item was hidden); it never overrides the user's. */
  selected?: string;
  /** The search text; items that do not contain it (title or subtitle) are hidden. */
  search?: string;
  /** What the right side shows for the chosen item. With no item chosen it shows `emptyDetail`. */
  detail?: Block[];
  emptyDetail?: { title?: string; text: string; symbol?: string };
  /** Your own blocks beside the search field (a "New" button, a Sync button …). */
  toolbar?: Block[];
  /** Where the divider starts: the list's share of the width (0…1). */
  fraction?: number;
  /** Shown when no item matches. */
  placeholder?: string;
}

/** The two panes as one block. */
export function listDetail(spec: ListDetailSpec): Block {
  const prefix = spec.id ?? 'listDetail';
  const shown = spec.items.filter((item) => matches(spec.search, item.title, item.subtitle));
  const left = vstack([
    hstack([
      searchField(scoped(prefix, 'search'), scoped(prefix, 'search'), { value: spec.search ?? '', placeholder: 'Search' }),
      ...(spec.toolbar ?? []),
    ], { id: scoped(prefix, 'bar') }),
    list(scoped(prefix, 'list'), shown.map((item) => row(item.id, {
      title: item.title, subtitle: item.subtitle, symbol: item.symbol, badge: item.badge, dimmed: item.dimmed,
      action: scoped(prefix, 'open'),   // Return or a double-click
    })), {
      selection: 'single', select: scoped(prefix, 'select'),
      selected: spec.selected !== undefined && shown.some((item) => item.id === spec.selected) ? [spec.selected] : undefined,
      placeholder: spec.placeholder ?? 'Nothing found',
    }),
  ], { id: scoped(prefix, 'left') });
  const empty_ = spec.emptyDetail ?? { text: 'Choose an item.' };
  const right = vstack(
    spec.selected !== undefined && spec.detail ? spec.detail : [empty(empty_.text, { id: scoped(prefix, 'nothing'), title: empty_.title, symbol: empty_.symbol })],
    { id: scoped(prefix, 'right') },
  );
  return split(scoped(prefix, 'split'), left, right, { axis: 'horizontal', fraction: spec.fraction ?? 0.38 });
}

/** One button under the detail. The `key` comes back in `onDetailAction`. */
export interface DetailAction { key: string; title: string; symbol?: string; style?: 'primary' | 'plain' | 'destructive'; enabled?: boolean }

export interface DetailPanelSpec {
  id?: string;
  title: string;
  subtitle?: string;
  symbol?: string;
  /** Label/value rows. */
  fields?: { label: string; value: string }[];
  markdown?: string;
  actions?: DetailAction[];
}

/** The usual right-hand side: heading, fields, Markdown, buttons. Pass the same `id` as the layout's. */
export function detailPanel(spec: DetailPanelSpec): Block[] {
  const prefix = spec.id ?? 'listDetail';
  const out: Block[] = [
    hstack([
      ...(spec.symbol ? [symbol(spec.symbol, { id: scoped(prefix, 'detail', 'symbol') })] : []),
      vstack([
        text(spec.title, { id: scoped(prefix, 'detail', 'title'), style: 'title', selectable: true }),
        ...(spec.subtitle ? [text(spec.subtitle, { id: scoped(prefix, 'detail', 'subtitle'), style: 'caption' })] : []),
      ]),
    ], { id: scoped(prefix, 'detail', 'heading') }),
  ];
  (spec.fields ?? []).forEach((field, index) => out.push(hstack([
    text(field.label, { id: scoped(prefix, 'field', String(index), 'label'), style: 'caption' }),
    spacer(),
    text(field.value, { id: scoped(prefix, 'field', String(index), 'value'), selectable: true }),
  ], { id: scoped(prefix, 'field', String(index)) })));
  if (spec.markdown) out.push(markdown(spec.markdown, { id: scoped(prefix, 'detail', 'markdown') }));
  if ((spec.actions ?? []).length > 0) {
    out.push(hstack((spec.actions ?? []).map((action) => button({
      id: scoped(prefix, 'action', action.key), title: action.title, symbol: action.symbol, style: action.style,
      enabled: action.enabled, action: scoped(prefix, 'action'),
    })), { id: scoped(prefix, 'actions') }));
  }
  return out;
}

export interface ListDetailHandlers {
  /** The chosen item changed; `undefined`: nothing is chosen any more. */
  onSelect?(item: string | undefined, event: ViewEvent): unknown;
  /** Return or a double-click on an item. */
  onOpen?(item: string, event: ViewEvent): unknown;
  onSearch?(text: string, event: ViewEvent): unknown;
  /** A button of `detailPanel`. */
  onDetailAction?(key: string, event: ViewEvent): unknown;
}

/** Sends the layout's events to `handlers`. Call once, when the view is set up. */
export function routeListDetail(view: ViewState, options: Pick<ListDetailSpec, 'id'>, handlers: ListDetailHandlers): void {
  const prefix = options.id ?? 'listDetail';
  view.on(scoped(prefix, 'select'), (event) => handlers.onSelect?.((event.selected ?? [])[0], event));
  view.on(scoped(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
  view.on(scoped(prefix, 'search'), (event) => handlers.onSearch?.(textOf(event.value), event));
  view.on(scoped(prefix, 'action'), (event) => {
    const key = unscoped(prefix, 'action', event.block);
    return key === undefined ? undefined : handlers.onDetailAction?.(key, event);
  });
}
