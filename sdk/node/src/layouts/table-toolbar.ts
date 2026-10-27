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
import { button, hstack, row, searchField, spacer, table, text, vstack, type Block, type Column } from '../blocks';
import type { ViewEvent, ViewState } from '../view';
import { describedBlock, matches, scoped, textOf, unscoped } from './support';

export interface TableRow { id: string; cells: (string | number)[]; dimmed?: boolean }

/** A toolbar button. With `needsSelection` it is disabled while nothing is selected. The `key` comes back in `onToolbar`. */
export interface ToolbarButton {
  key: string; title?: string; symbol?: string; tooltip?: string; style?: 'primary' | 'plain' | 'destructive' | 'icon';
  needsSelection?: boolean; enabled?: boolean;
}

export interface TableSpec {
  /** Prefix of every block id and action (default `table`). */
  id?: string;
  columns: Column[];
  rows: TableRow[];
  sorted?: { column: string; ascending: boolean };
  /** The ids of the selected rows, as you last heard them from `onSelect`. Those shown drive the "N selected" text and the
   *  buttons that need a selection, and are sent as the table's `selected`: Vektor starts from them when it has no selection
   *  of its own (it never overrides one the user made). */
  selected?: string[];
  /** The search text; rows with no cell containing it are hidden. */
  search?: string;
  toolbar?: ToolbarButton[];
  /** Your own blocks at the end of the toolbar. */
  extra?: Block[];
}

/** Rows in the order a sorted column asks for: numbers as numbers, text the way the user's language orders it. */
export function sortRows(rows: TableRow[], columns: Column[], sorted?: { column: string; ascending: boolean }): TableRow[] {
  const at = sorted ? columns.findIndex((column) => column.id === sorted.column) : -1;
  if (!sorted || at < 0) return [...rows];
  const direction = sorted.ascending ? 1 : -1;
  return [...rows].sort((a, b) => {
    const x = a.cells[at];
    const y = b.cells[at];
    const order = typeof x === 'number' && typeof y === 'number' ? x - y : String(x ?? '').localeCompare(String(y ?? ''), undefined, { numeric: true });
    return direction * Math.sign(order);
  });
}

export function tableWithToolbar(spec: TableSpec): Block {
  const prefix = spec.id ?? 'table';
  const shown = spec.rows.filter((item) => matches(spec.search, ...item.cells.map(String)));
  // Only rows still shown can be selected: Vektor drops the others from its selection, silently.
  const shownIDs = new Set(shown.map((item) => item.id));
  const selected = (spec.selected ?? []).filter((id) => shownIDs.has(id));
  const bar = hstack([
    searchField(scoped(prefix, 'search'), scoped(prefix, 'search'), { value: spec.search ?? '', placeholder: 'Search' }),
    ...(spec.toolbar ?? []).map((entry) => button({
      id: scoped(prefix, 'tool', entry.key), title: entry.title, symbol: entry.symbol, tooltip: entry.tooltip, style: entry.style,
      action: scoped(prefix, 'tool'), enabled: entry.enabled === false ? false : entry.needsSelection && selected.length === 0 ? false : undefined,
    })),
    spacer(),
    // The count is words, so VoiceOver and a colour-blind reader get it too.
    ...(selected.length > 0 ? [text(`${selected.length} selected`, { id: scoped(prefix, 'count'), style: 'caption' })] : []),
    ...(spec.extra ?? []),
  ], { id: scoped(prefix, 'bar') });
  return vstack([
    bar,
    table(scoped(prefix, 'table'), spec.columns, shown.map((item) => row(item.id, {
      cells: item.cells, dimmed: item.dimmed,
      action: scoped(prefix, 'open'),       // Return or a double-click
      delete: scoped(prefix, 'delete'),     // ⌫
    })), {
      selection: 'multiple', select: scoped(prefix, 'select'), selected: selected.length > 0 ? selected : undefined,
      sorted: spec.sorted, sort: scoped(prefix, 'sort'),
    }),
  ], { id: prefix });
}

export interface TableHandlers {
  /** The user clicked a sortable column's header. */
  onSort?(column: string, ascending: boolean, event: ViewEvent): unknown;
  onSelect?(selected: string[], event: ViewEvent): unknown;
  /** A toolbar button; `selected` is the selection the layout heard last, without rows no longer shown. */
  onToolbar?(key: string, selected: string[], event: ViewEvent): unknown;
  onSearch?(text: string, event: ViewEvent): unknown;
  /** Return or a double-click on a row. */
  onOpen?(row: string, event: ViewEvent): unknown;
  /** ⌫ on a row. */
  onDelete?(row: string, event: ViewEvent): unknown;
}

/** Sends the table's events to `handlers`. Call once, when the view is set up. */
export function routeTable(view: ViewState, options: Pick<TableSpec, 'id'>, handlers: TableHandlers): void {
  const prefix = options.id ?? 'table';
  // What `select` said last; undefined until it says something after the view opens, because a reopened view starts with no
  // selection of Vektor's own and shows the `selected` it was described with.
  let heard: string[] | undefined;
  view.onOpen(() => { heard = undefined; });
  // The selection the user sees: what was heard (or described), less the rows the table no longer has.
  const visible = (): string[] => {
    const table = describedBlock(view, scoped(prefix, 'table'));
    const rows = new Set((table?.children ?? []).map((item) => item.id));
    const selected = heard ?? (Array.isArray(table?.selected) ? (table.selected as string[]) : []);
    return selected.filter((id) => rows.has(id));
  };
  view.on(scoped(prefix, 'sort'), (event) => (event.column === undefined ? undefined : handlers.onSort?.(event.column, event.ascending !== false, event)));
  view.on(scoped(prefix, 'select'), (event) => {
    heard = event.selected ?? [];
    return handlers.onSelect?.(heard, event);
  });
  view.on(scoped(prefix, 'tool'), (event) => {
    const key = unscoped(prefix, 'tool', event.block);
    return key === undefined ? undefined : handlers.onToolbar?.(key, visible(), event);
  });
  view.on(scoped(prefix, 'search'), (event) => handlers.onSearch?.(textOf(event.value), event));
  view.on(scoped(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
  view.on(scoped(prefix, 'delete'), (event) => (event.block === undefined ? undefined : handlers.onDelete?.(event.block, event)));
}
