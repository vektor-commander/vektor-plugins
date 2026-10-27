import { type Badge, type Block } from '../blocks';
import type { ViewEvent, ViewState } from '../view';
export interface ListDetailItem {
    id: string;
    title: string;
    subtitle?: string;
    symbol?: string;
    badge?: Badge;
    dimmed?: boolean;
}
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
    emptyDetail?: {
        title?: string;
        text: string;
        symbol?: string;
    };
    /** Your own blocks beside the search field (a "New" button, a Sync button …). */
    toolbar?: Block[];
    /** Where the divider starts: the list's share of the width (0…1). */
    fraction?: number;
    /** Shown when no item matches. */
    placeholder?: string;
}
/** The two panes as one block. */
export declare function listDetail(spec: ListDetailSpec): Block;
/** One button under the detail. The `key` comes back in `onDetailAction`. */
export interface DetailAction {
    key: string;
    title: string;
    symbol?: string;
    style?: 'primary' | 'plain' | 'destructive';
    enabled?: boolean;
}
export interface DetailPanelSpec {
    id?: string;
    title: string;
    subtitle?: string;
    symbol?: string;
    /** Label/value rows. */
    fields?: {
        label: string;
        value: string;
    }[];
    markdown?: string;
    actions?: DetailAction[];
}
/** The usual right-hand side: heading, fields, Markdown, buttons. Pass the same `id` as the layout's. */
export declare function detailPanel(spec: DetailPanelSpec): Block[];
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
export declare function routeListDetail(view: ViewState, options: Pick<ListDetailSpec, 'id'>, handlers: ListDetailHandlers): void;
