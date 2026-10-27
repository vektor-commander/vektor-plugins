// Card list: a column of cards, each with a symbol, a title, a pill, some lines of text and buttons — the look of the
// `cardList` view kind, built from blocks (so it can also sit beside other blocks, and be patched by id).
//
//     view.show({ blocks: cardList({ cards, empty: { text: 'No tunnels yet.' } }) });
//     routeCardList(view, { menuKeys: ['delete'] }, { onOpen, onButton, onMenu });
//
// Copy and adapt.
import { button, card, empty, hstack, list, menu as menuBlock, spacer, text, vstack, type Block, type MenuEntry, type Role } from '../blocks';
import { PluginError } from '../errors';
import type { ViewEvent, ViewState } from '../view';
import { scoped, unscoped } from './support';

/** A button at a card's right. `key` comes back in `onButton`; it is a word without dots (the card's id may have them). */
export interface CardButton { key: string; title?: string; symbol?: string; tooltip?: string; enabled?: boolean }
export type CardMenuEntry = { key: string; title: string; symbol?: string; destructive?: boolean; enabled?: boolean } | { separator: true };
export interface CardItem {
  id: string;
  symbol?: string;
  title: string;
  /** A word on a tinted capsule beside the title. */
  pill?: { label: string; role?: Role };
  /** Lines of text under the title; one with a `link` opens it in the browser when clicked (needs `openURLs`). */
  lines?: (string | { text: string; link?: string })[];
  /** The card reacts to Return or a double-click (`onOpen`). */
  openable?: boolean;
  /** Buttons at the right. */
  buttons?: CardButton[];
  /** The card's context menu. */
  menu?: CardMenuEntry[];
}

export interface CardListSpec {
  /** Prefix of every block id and action (default `cards`). */
  id?: string;
  cards: CardItem[];
  /** Shown instead of the cards when there are none. */
  empty?: { title?: string; text: string; symbol?: string };
}

function cardBlock(prefix: string, item: CardItem): Block {
  const lines = (item.lines ?? []).map((line, index) => {
    const spec = typeof line === 'string' ? { text: line } : line;
    return text(spec.text, { id: scoped(prefix, 'line', item.id, String(index)), style: 'caption', link: spec.link, lineLimit: 3 });
  });
  // A button's id is `cards.button.<key>.<card id>`, and a card id may contain dots, so the key may not: `open.url` on the card
  // `k1` could not be told apart from `open` on the card `url.k1`.
  const bad = (item.buttons ?? []).find((entry) => entry.key === '' || entry.key.includes('.'));
  if (bad) throw new PluginError(`The button key “${bad.key}” of the card “${item.id}” must be a word without dots.`);
  const buttons = (item.buttons ?? []).map((entry) => button({
    id: scoped(prefix, 'button', entry.key, item.id), title: entry.title, symbol: entry.symbol, tooltip: entry.tooltip,
    style: entry.title === undefined ? 'icon' : 'plain', action: scoped(prefix, 'button'), enabled: entry.enabled,
  }));
  const entries: MenuEntry[] = (item.menu ?? []).map((entry) => 'separator' in entry ? { separator: true } : {
    title: entry.title, action: scoped(prefix, 'menu', entry.key), symbol: entry.symbol, destructive: entry.destructive, enabled: entry.enabled,
  });
  return card([hstack([...(lines.length > 0 ? [vstack(lines, { id: scoped(prefix, 'lines', item.id) })] : []), spacer(), ...buttons, ...(entries.length > 0 ? [menuBlock(entries, { id: scoped(prefix, 'more', item.id) })] : [])],
    { id: scoped(prefix, 'body', item.id) })], {
    id: item.id, title: item.title, symbol: item.symbol,
    badge: item.pill ? { text: item.pill.label, role: item.pill.role } : undefined,
    action: item.openable ? scoped(prefix, 'open') : undefined,
    menu: entries.length > 0 ? entries : undefined,
  });
}

/** The card list as one block. Throws a `PluginError` for a button key that is empty or contains a dot. */
export function cardList(spec: CardListSpec): Block {
  const prefix = spec.id ?? 'cards';
  if (spec.cards.length === 0) {
    const note = spec.empty ?? { text: 'Nothing here.' };
    return empty(note.text, { id: prefix, title: note.title, symbol: note.symbol });
  }
  // A list, not a stack in a scroll: only a collection's items get Return and a double-click (`onOpen`), and a list scrolls
  // by itself. Nothing is selected in it; `spacing` keeps the cards apart.
  return list(prefix, spec.cards.map((item) => cardBlock(prefix, item)), { selection: 'none', spacing: 8 });
}

export interface CardListHandlers {
  onOpen?(card: string, event: ViewEvent): unknown;
  /** A card's button: `key` is the button's key. */
  onButton?(card: string, key: string, event: ViewEvent): unknown;
  /** An entry of a card's menu (the "…" or a right-click): `key` is the entry's key. */
  onMenu?(card: string, key: string, event: ViewEvent): unknown;
}

/**
 * Sends the card list's events to `handlers`. Call once. `menuKeys` lists the keys of every menu entry any card can have
 * (an action is routed by its exact text, so each needs registering).
 */
export function routeCardList(view: ViewState, options: Pick<CardListSpec, 'id'> & { menuKeys?: string[] }, handlers: CardListHandlers): void {
  const prefix = options.id ?? 'cards';
  view.on(scoped(prefix, 'open'), (event) => (event.block === undefined ? undefined : handlers.onOpen?.(event.block, event)));
  view.on(scoped(prefix, 'button'), (event) => {
    // The button's id is `cards.button.<key>.<card id>`; the key has no dot, the card id may.
    const rest = unscoped(prefix, 'button', event.block);
    const dot = rest?.indexOf('.') ?? -1;
    return rest === undefined || dot < 1 ? undefined : handlers.onButton?.(rest.slice(dot + 1), rest.slice(0, dot), event);
  });
  for (const key of options.menuKeys ?? []) {
    // A menu item's event names the block that carries the menu: the card, or its "…" block.
    view.on(scoped(prefix, 'menu', key), (event) => {
      const more = unscoped(prefix, 'more', event.block);
      const card = more ?? event.block;
      return card === undefined ? undefined : handlers.onMenu?.(card, key, event);
    });
  }
}
