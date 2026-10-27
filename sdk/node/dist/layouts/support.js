"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.scoped = scoped;
exports.unscoped = unscoped;
exports.describedBlock = describedBlock;
exports.textOf = textOf;
exports.matches = matches;
/** `scoped('board', 'add', 'todo')` is `board.add.todo`. */
function scoped(prefix, ...parts) {
    return [prefix, ...parts].join('.');
}
/** The part of `value` after `prefix.kind.` — or undefined when `value` is not of that kind. */
function unscoped(prefix, kind, value) {
    const start = `${prefix}.${kind}.`;
    return value !== undefined && value.startsWith(start) && value.length > start.length ? value.slice(start.length) : undefined;
}
/** The block with this id in what `view` described last (with any patches since), or undefined. */
function describedBlock(view, id) {
    const find = (block) => (block.id === id ? block : (block.children ?? []).map(find).find(Boolean));
    const blocks = view.description?.blocks;
    return (Array.isArray(blocks) ? blocks : blocks ? [blocks] : []).map(find).find(Boolean);
}
/** A text event value, or `''` when the event carried something else. */
function textOf(value) {
    return typeof value === 'string' ? value : '';
}
/** Case-insensitive "contains", the way a search box means it. An empty query matches everything. */
function matches(query, ...fields) {
    const needle = (query ?? '').trim().toLowerCase();
    return needle === '' || fields.some((field) => (field ?? '').toLowerCase().includes(needle));
}
