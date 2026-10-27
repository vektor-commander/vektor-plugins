import type { Block } from '../blocks';
import type { ViewState } from '../view';
/** `scoped('board', 'add', 'todo')` is `board.add.todo`. */
export declare function scoped(prefix: string, ...parts: string[]): string;
/** The part of `value` after `prefix.kind.` — or undefined when `value` is not of that kind. */
export declare function unscoped(prefix: string, kind: string, value: string | undefined): string | undefined;
/** The block with this id in what `view` described last (with any patches since), or undefined. */
export declare function describedBlock(view: ViewState, id: string): Block | undefined;
/** A text event value, or `''` when the event carried something else. */
export declare function textOf(value: unknown): string;
/** Case-insensitive "contains", the way a search box means it. An empty query matches everything. */
export declare function matches(query: string | undefined, ...fields: (string | undefined)[]): boolean;
