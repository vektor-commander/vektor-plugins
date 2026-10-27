// Shared by the layouts. Read this first: every layout names its blocks and actions the same way.
//
// A layout draws blocks and, separately, routes the events those blocks cause. The two meet in names:
//
//   * every block id and every action starts with the layout's own `id` (default: the layout's name), so two layouts in
//     one view never collide;
//   * the part after the prefix says what the block is: `board.add.todo` is the "+" button of the column `todo`;
//   * routing reads that part back, so the plugin only ever sees the ids IT chose (a column id, a card id).
//
// Every container that holds changing content has an id too (even a scroll): the SDK patches a view by id. It looks inside
// a block without one, but when such a block's own fields change it must replace the nearest block above that has an id.
//
// Nothing here is clever on purpose. Copy a layout into your plugin and rename things; this file goes with it.
import type { Block } from '../blocks';
import type { ViewState } from '../view';

/** `scoped('board', 'add', 'todo')` is `board.add.todo`. */
export function scoped(prefix: string, ...parts: string[]): string {
  return [prefix, ...parts].join('.');
}

/** The part of `value` after `prefix.kind.` — or undefined when `value` is not of that kind. */
export function unscoped(prefix: string, kind: string, value: string | undefined): string | undefined {
  const start = `${prefix}.${kind}.`;
  return value !== undefined && value.startsWith(start) && value.length > start.length ? value.slice(start.length) : undefined;
}

/** The block with this id in what `view` described last (with any patches since), or undefined. */
export function describedBlock(view: ViewState, id: string): Block | undefined {
  const find = (block: Block): Block | undefined => (block.id === id ? block : (block.children ?? []).map(find).find(Boolean));
  const blocks = view.description?.blocks;
  return (Array.isArray(blocks) ? blocks : blocks ? [blocks] : []).map(find).find(Boolean);
}

/** A text event value, or `''` when the event carried something else. */
export function textOf(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

/** Case-insensitive "contains", the way a search box means it. An empty query matches everything. */
export function matches(query: string | undefined, ...fields: (string | undefined)[]): boolean {
  const needle = (query ?? '').trim().toLowerCase();
  return needle === '' || fields.some((field) => (field ?? '').toLowerCase().includes(needle));
}
