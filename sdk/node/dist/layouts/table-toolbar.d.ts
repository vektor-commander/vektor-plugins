import { type Block, type Column } from '../blocks';
import type { ViewEvent, ViewState } from '../view';
export interface TableRow {
    id: string;
    cells: (string | number)[];
    dimmed?: boolean;
}
/** A toolbar button. With `needsSelection` it is disabled while nothing is selected. The `key` comes back in `onToolbar`. */
export interface ToolbarButton {
    key: string;
    title?: string;
    symbol?: string;
    tooltip?: string;
    style?: 'primary' | 'plain' | 'destructive' | 'icon';
    needsSelection?: boolean;
    enabled?: boolean;
}
export interface TableSpec {
    /** Prefix of every block id and action (default `table`). */
    id?: string;
    columns: Column[];
    rows: TableRow[];
    sorted?: {
        column: string;
        ascending: boolean;
    };
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
export declare function sortRows(rows: TableRow[], columns: Column[], sorted?: {
    column: string;
    ascending: boolean;
}): TableRow[];
export declare function tableWithToolbar(spec: TableSpec): Block;
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
export declare function routeTable(view: ViewState, options: Pick<TableSpec, 'id'>, handlers: TableHandlers): void;
