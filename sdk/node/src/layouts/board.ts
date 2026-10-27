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
import {
  badge, button, card, count, hstack, list, menu, panel, picker, scroll, searchField, spacer, text, vstack,
  type Block, type MenuEntry, type Option, type Role,
} from '../blocks';
import type { ViewState, ViewEvent } from '../view';
import { matches, scoped, textOf, unscoped } from './support';

export interface BoardTag { text: string; role?: Role }
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
export interface BoardColumn { id: string; title: string; role?: Role; cards: BoardCard[] }

/** An entry of a column's "…" menu. The `key` comes back in `onColumnAction`. */
export interface BoardColumnAction { key: string; title: string; symbol?: string; destructive?: boolean }
export const DEFAULT_COLUMN_MENU: readonly BoardColumnAction[] = [
  { key: 'rename', title: 'Rename Column', symbol: 'pencil' },
  { key: 'delete', title: 'Delete Column', symbol: 'trash', destructive: true },
];

export interface BoardSpec {
  /** Prefix of every block id and action (default `board`). */
  id?: string;
  columns: BoardColumn[];
  /** The search text shown in the search field; cards that do not contain it (in title, subtitle or a tag) are hidden. */
  search?: string;
  /** A filter over tags: `options` (include an "All" option with value `''`), and the one chosen (`''`: all). */
  filter?: { options: Option[]; value?: string; title?: string };
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
export const BOARD_GROUP = 'cards';

/** Whether a card shows under the spec's search and filter. */
export function boardShows(spec: Pick<BoardSpec, 'search' | 'filter'>, cardItem: BoardCard): boolean {
  const tag = spec.filter?.value ?? '';
  const tagOK = tag === '' || (cardItem.tags ?? []).some((candidate) => candidate.text === tag);
  return tagOK && matches(spec.search, cardItem.title, cardItem.subtitle, ...(cardItem.tags ?? []).map((candidate) => candidate.text));
}

function cardBlock(prefix: string, item: BoardCard): Block {
  const children: Block[] = [];
  if (item.subtitle) children.push(text(item.subtitle, { id: scoped(prefix, 'subtitle', item.id), style: 'caption' }));
  (item.tags ?? []).forEach((tag, index) => children.push(badge(tag.text, { id: scoped(prefix, 'tag', item.id, String(index)), role: tag.role })));
  return card(children, {
    id: item.id, title: item.title, role: item.role,
    edit: scoped(prefix, 'rename'),          // Return or a double-click: the title edited in place
    delete: scoped(prefix, 'remove'),        // ⌫ / ⌘⌫
    // Vektor gives `edit` precedence over `action` on Return and a double-click, so a card that can be renamed is opened from
    // its context menu. A menu item's event names the block carrying the menu: the card.
    menu: [{ title: 'Open', action: scoped(prefix, 'open') }],
  });
}

function columnBlock(prefix: string, spec: BoardSpec, column: BoardColumn): Block {
  const shown = column.cards.filter((item) => boardShows(spec, item));
  const menuEntries: MenuEntry[] = (spec.columnMenu ?? DEFAULT_COLUMN_MENU).map((entry) => ({
    title: entry.title, action: scoped(prefix, 'column', entry.key), symbol: entry.symbol, destructive: entry.destructive,
  }));
  // The count is a block of its own, not the panel's `badge`: a card that moves changes two counts, and a change in a panel's
  // own fields would make the SDK replace the whole column (all its cards) instead of sending one small `move`.
  // With a search or filter on, it also says how many there are.
  const countID = scoped(prefix, 'count', column.id);
  const header = hstack([
    shown.length === column.cards.length
      ? count(shown.length, { id: countID })
      : badge(`${shown.length} of ${column.cards.length}`, { id: countID }),
    spacer(),
    button({ id: scoped(prefix, 'add', column.id), symbol: 'plus', style: 'icon', tooltip: 'Add a card', action: scoped(prefix, 'add') }),
    ...(menuEntries.length > 0 ? [menu(menuEntries, { id: scoped(prefix, 'colmenu', column.id), label: `${column.title} actions` })] : []),
  ], { id: scoped(prefix, 'head', column.id) });
  return panel([
    header,
    list(scoped(prefix, 'list', column.id), shown.map((item) => cardBlock(prefix, item)), {
      group: BOARD_GROUP, move: scoped(prefix, 'move'), placeholder: spec.placeholder ?? 'No cards',
    }),
  ], {
    id: scoped(prefix, 'col', column.id), title: column.title, role: column.role,
    ...(spec.columnMinWidth !== undefined ? { grow: true, minWidth: spec.columnMinWidth } : {}),
  });
}

/** Vektor refuses an option whose value is empty, so the "All" option's `''` goes out as this value and comes back as `''`. */
export function boardFilterAll(prefix = 'board'): string {
  return scoped(prefix, 'all');
}
const filterOut = (prefix: string, value: string) => (value === '' ? boardFilterAll(prefix) : value);
const filterIn = (prefix: string, value: string) => (value === boardFilterAll(prefix) ? '' : value);

/** The board as one block: a bar (search, filter, your toolbar) over the columns, which scroll sideways. */
export function board(spec: BoardSpec): Block {
  const prefix = spec.id ?? 'board';
  const bar: Block[] = [searchField(scoped(prefix, 'search'), scoped(prefix, 'search'), { value: spec.search ?? '', placeholder: 'Search cards' })];
  if (spec.filter) {
    const options = spec.filter.options.map((option) => ({ ...option, value: filterOut(prefix, option.value) }));
    bar.push(picker(scoped(prefix, 'filter'), scoped(prefix, 'filter'), options, { value: filterOut(prefix, spec.filter.value ?? '') }));
  }
  bar.push(spacer(), ...(spec.toolbar ?? []));
  return vstack([
    hstack(bar, { id: scoped(prefix, 'bar') }),
    scroll([hstack(spec.columns.map((column) => columnBlock(prefix, spec, column)), { id: scoped(prefix, 'columns') })], { id: scoped(prefix, 'scroll'), axis: 'horizontal' }),
  ], { id: prefix });
}

// --- Events --------------------------------------------------------------------------------------------------------------

/** A card dropped, or moved with the keyboard. `index` is its position among the cards SHOWN in `to` once it is out of its old place. */
export interface BoardMove { card: string; from?: string; to: string; index: number }

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
export function routeBoard(view: ViewState, options: Pick<BoardSpec, 'id' | 'columnMenu'>, handlers: BoardHandlers): void {
  const prefix = options.id ?? 'board';
  view.on(scoped(prefix, 'add'), (event) => {
    const column = unscoped(prefix, 'add', event.block);
    return column === undefined ? undefined : handlers.onAdd?.(column, event);
  });
  view.on(scoped(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
  view.on(scoped(prefix, 'rename'), (event) => (event.block === undefined ? undefined : handlers.onRename?.(event.block, textOf(event.value), event)));
  view.on(scoped(prefix, 'remove'), (event) => (event.block === undefined ? undefined : handlers.onRemove?.(event.block, event)));
  view.on(scoped(prefix, 'move'), (event) => {
    const to = unscoped(prefix, 'list', event.target);
    if (event.item === undefined || to === undefined) return undefined;
    return handlers.onMove?.({ card: event.item, from: unscoped(prefix, 'list', event.from), to, index: event.index ?? 0 }, event);
  });
  for (const entry of options.columnMenu ?? DEFAULT_COLUMN_MENU) {
    // A menu item's event names the block that carries the menu: the column's "…" block.
    view.on(scoped(prefix, 'column', entry.key), (event) => {
      const column = unscoped(prefix, 'colmenu', event.block);
      return column === undefined ? undefined : handlers.onColumnAction?.(column, entry.key, event);
    });
  }
  view.on(scoped(prefix, 'search'), (event) => handlers.onSearch?.(textOf(event.value), event));
  view.on(scoped(prefix, 'filter'), (event) => handlers.onFilter?.(filterIn(prefix, textOf(event.value)), event));
}

/**
 * Applies a move to your columns: the card leaves its column and goes into `to` at the position `index` counts among the
 * cards that are shown (a search or filter may hide some; they keep their place). Returns false when the card or the column
 * is unknown. This is the usual `onMove`:
 *
 *     onMove: (move) => { if (moveCard(columns, move, (c) => boardShows(spec, c))) draw(); }
 */
export function moveCard(columns: BoardColumn[], move: BoardMove, isShown: (card: BoardCard) => boolean = () => true): boolean {
  const source = columns.find((column) => column.cards.some((item) => item.id === move.card));
  const target = columns.find((column) => column.id === move.to);
  if (!source || !target) return false;
  const [moving] = source.cards.splice(source.cards.findIndex((item) => item.id === move.card), 1);
  // `index` counts shown cards only: find the shown card that must come right after, and insert before it.
  const shown = target.cards.filter(isShown);
  const next = shown[move.index];
  const at = next === undefined ? target.cards.length : target.cards.indexOf(next);
  target.cards.splice(at, 0, moving);
  return true;
}
