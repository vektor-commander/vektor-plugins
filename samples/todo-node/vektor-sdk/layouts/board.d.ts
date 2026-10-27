import { type Block, type Option, type Role } from '../blocks';
import type { ViewState, ViewEvent } from '../view';
export interface BoardTag {
    text: string;
    role?: Role;
}
export interface BoardCard {
    /** The card's own id, stable for as long as the card exists (never its position): Vektor and the SDK diff by id. */
    id: string;
    title: string;
    /** A second line under the title. */
    subtitle?: string;
    /** A colour role for the stripe. */
    role?: Role;
    /** Words on tinted capsules. The filter offers these. */
    tags?: BoardTag[];
}
export interface BoardColumn {
    id: string;
    title: string;
    role?: Role;
    cards: BoardCard[];
}
/** An entry of a column's "…" menu. The `key` comes back in `onColumnAction`. */
export interface BoardColumnAction {
    key: string;
    title: string;
    symbol?: string;
    destructive?: boolean;
}
export declare const DEFAULT_COLUMN_MENU: readonly BoardColumnAction[];
export interface BoardSpec {
    /** Prefix of every block id and action (default `board`). */
    id?: string;
    columns: BoardColumn[];
    /** The search text shown in the search field; cards that do not contain it (in title, subtitle or a tag) are hidden. */
    search?: string;
    /** A filter over tags: `options` (include an "All" option with value `''`), and the one chosen (`''`: all). */
    filter?: {
        options: Option[];
        value?: string;
        title?: string;
    };
    /** Your own blocks, in the bar above the columns (a Sync button, a "New column" button …). */
    toolbar?: Block[];
    /** What a column's "…" menu offers. Default: rename and delete. `[]` shows no menu. */
    columnMenu?: readonly BoardColumnAction[];
    /** Shown in an empty column. */
    placeholder?: string;
    /** Columns fill the pane, sharing its width, and scroll sideways once they would be narrower than this (points, 20…4000).
     *  Without it a column is as wide as its widest card. */
    columnMinWidth?: number;
}
/** The drag group every list shares, so cards move between columns. */
export declare const BOARD_GROUP = "cards";
/** Whether a card shows under the spec's search and filter. */
export declare function boardShows(spec: Pick<BoardSpec, 'search' | 'filter'>, cardItem: BoardCard): boolean;
/** Vektor refuses an option whose value is empty, so the "All" option's `''` goes out as this value and comes back as `''`. */
export declare function boardFilterAll(prefix?: string): string;
/** The board as one block: a bar (search, filter, your toolbar) over the columns, which scroll sideways. */
export declare function board(spec: BoardSpec): Block;
/** A card dropped, or moved with the keyboard. `index` is its position among the cards SHOWN in `to` once it is out of its old place. */
export interface BoardMove {
    card: string;
    from?: string;
    to: string;
    index: number;
}
export interface BoardHandlers {
    /** The "+" of a column. */
    onAdd?(column: string, event: ViewEvent): unknown;
    /** "Open" in a card's context menu (Return and a double-click edit the title). */
    onOpen?(card: string, event: ViewEvent): unknown;
    /** A card's title edited in place. */
    onRename?(card: string, title: string, event: ViewEvent): unknown;
    /** ⌫ on a card. Ask first if you like (`plugin.confirm`). */
    onRemove?(card: string, event: ViewEvent): unknown;
    onMove?(move: BoardMove, event: ViewEvent): unknown;
    /** An entry of a column's "…" menu: `key` is the entry's key. */
    onColumnAction?(column: string, key: string, event: ViewEvent): unknown;
    onSearch?(text: string, event: ViewEvent): unknown;
    /** The filter changed: the option's value, `''` for "All". */
    onFilter?(value: string, event: ViewEvent): unknown;
}
/**
 * Sends the board's events to `handlers`. Call once, when the view is set up. `options` must be the `id` and `columnMenu`
 * you draw the board with.
 *
 * Moves made against an older description are dropped by the view state (the default `ignoreMoves` policy), because "put it
 * at index 3" no longer means what the user saw.
 */
export declare function routeBoard(view: ViewState, options: Pick<BoardSpec, 'id' | 'columnMenu'>, handlers: BoardHandlers): void;
/**
 * Applies a move to your columns: the card leaves its column and goes into `to` at the position `index` counts among the
 * cards that are shown (a search or filter may hide some; they keep their place). Returns false when the card or the column
 * is unknown. This is the usual `onMove`:
 *
 *     onMove: (move) => { if (moveCard(columns, move, (c) => boardShows(spec, c))) draw(); }
 */
export declare function moveCard(columns: BoardColumn[], move: BoardMove, isShown?: (card: BoardCard) => boolean): boolean;
