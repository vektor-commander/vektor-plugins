"use strict";
// View descriptions and the view state helper.
//
// A view is described as data with `view/update` (the whole description) or, for a block view, changed by id with
// `view/patch`. `ViewState` keeps what was last sent and its revision, so you only say what the view should look like now:
// `show(description)` sends a patch when one says it (block views, the same header/toolbar/banner/empty) and the whole
// description otherwise. It also routes `view/event`s to handlers by action and recognises events made against an older
// revision.
Object.defineProperty(exports, "__esModule", { value: true });
exports.ViewState = exports.MAX_PATCH_OPERATIONS = void 0;
exports.sameJSON = sameJSON;
exports.applyPatch = applyPatch;
exports.diffBlocks = diffBlocks;
const blocks_1 = require("./blocks");
const errors_1 = require("./errors");
// --- JSON helpers --------------------------------------------------------------------------------------------------------
/** Two JSON values are the same, whatever the order of object keys. `undefined` fields count as absent. */
function sameJSON(a, b) {
    if (a === b)
        return true;
    if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object')
        return false;
    if (Array.isArray(a) !== Array.isArray(b))
        return false;
    if (Array.isArray(a)) {
        const other = b;
        return a.length === other.length && a.every((value, index) => sameJSON(value, other[index]));
    }
    const left = Object.keys(a).filter((key) => a[key] !== undefined);
    const right = Object.keys(b).filter((key) => b[key] !== undefined);
    // Own fields only: `b.__proto__` read through the prototype would make {"__proto__": {}} equal another one-field object.
    return left.length === right.length
        && left.every((key) => Object.prototype.hasOwnProperty.call(b, key) && sameJSON(a[key], b[key]));
}
function clone(value) {
    return value === undefined ? value : JSON.parse(JSON.stringify(value));
}
/** A block's own fields, without its children (what a `replace` would change). */
function sameOwn(a, b) {
    const { children: _a, ...left } = a;
    const { children: _b, ...right } = b;
    return sameJSON(left, right);
}
const hasID = (block) => !!block && typeof block.id === 'string' && block.id !== '';
function collectIDs(block, into) {
    if (hasID(block))
        into.add(block.id);
    for (const child of block.children ?? [])
        collectIDs(child, into);
    return into;
}
/** `blocks` as one root: a list is read as a vertical stack, as Vektor reads it. */
function asRoot(blocks) {
    return Array.isArray(blocks) ? { type: 'vstack', children: blocks } : blocks;
}
function locate(root, id) {
    if (root.id === id)
        return { block: root, parent: null, index: -1 };
    const stack = [root];
    while (stack.length > 0) {
        const parent = stack.pop();
        const children = parent.children ?? [];
        for (let index = 0; index < children.length; index++) {
            const child = children[index];
            if (child.id === id)
                return { block: child, parent, index };
            if (child.children && child.children.length > 0)
                stack.push(child);
        }
    }
    return null;
}
/**
 * The blocks of a tree by id, and each block's parent, kept up to date as blocks come and go, so finding a block is a lookup
 * instead of a walk of the whole tree (which made comparing two big trees quadratic: minutes for a board of 3,000 cards). A
 * move only changes the block's parent here. A tree that lists an id twice (Vektor refuses one) is searched by walking, so
 * the first in order is found, as before.
 */
class TreeIndex {
    root;
    byID = new Map();
    parents = new Map();
    unique = true;
    constructor(root) {
        this.root = root;
        this.walk(root, null, (block) => {
            if (!hasID(block))
                return;
            if (this.byID.has(block.id))
                this.unique = false;
            else
                this.byID.set(block.id, block);
        });
    }
    walk(block, parent, visit) {
        if (parent)
            this.parents.set(block, parent);
        visit(block);
        for (const child of block.children ?? [])
            this.walk(child, block, visit);
    }
    locate(id) {
        if (!this.unique)
            return locate(this.root, id);
        const block = this.byID.get(id);
        if (!block)
            return null;
        if (block === this.root)
            return { block, parent: null, index: -1 };
        const parent = this.parents.get(block);
        return parent ? { block, parent, index: parent.children.indexOf(block) } : null;
    }
    /** `block` (with what it holds) joined the tree under `parent` (null: it is the root). */
    added(block, parent) {
        this.walk(block, parent, (each) => { if (hasID(each))
            this.byID.set(each.id, each); });
    }
    /** `block` (with what it holds) left the tree. */
    removed(block) {
        this.walk(block, null, (each) => { if (hasID(each) && this.byID.get(each.id) === each)
            this.byID.delete(each.id); });
        this.parents.delete(block);
    }
    /** `block` now sits under `parent`. */
    moved(block, parent) { this.parents.set(block, parent); }
    /** `block` is `ancestor` or inside it (walking up from `block`). */
    contains(ancestor, block) {
        for (let at = block; at; at = this.parents.get(at))
            if (at === ancestor)
                return true;
        return false;
    }
}
// --- Patches -------------------------------------------------------------------------------------------------------------
/**
 * Applies patch operations to a block tree the way Vektor does: in order and all or nothing. Returns the new tree (the old
 * one is not changed) or throws a `PluginError` naming the operation that cannot apply.
 */
function applyPatch(blocks, ops) {
    const wasList = Array.isArray(blocks);
    const root = clone(asRoot(blocks));
    const tree = new TreeIndex(root);
    const ids = collectIDs(root, new Set());
    ops.forEach((operation, number) => {
        const place = `operation ${number + 1}`;
        const fail = (why) => { throw new errors_1.PluginError(`${place} ${why}`); };
        // The ids in use are checked without copying them: a replace takes its old ids out first (a failure ends the patch).
        const parse = (block) => {
            const { problems } = (0, blocks_1.validateBlocks)(block, ids);
            if (problems.length > 0)
                fail(`: ${problems[0]}`);
        };
        switch (operation.op) {
            case 'replace': {
                const found = tree.locate(operation.id) ?? fail(`replaces “${operation.id}”, which the view does not have.`);
                const old = collectIDs(found.block, new Set());
                for (const id of old)
                    ids.delete(id);
                parse(operation.block);
                const fresh = clone(operation.block);
                tree.removed(found.block);
                if (found.parent) {
                    found.parent.children[found.index] = fresh;
                    tree.added(fresh, found.parent);
                }
                else {
                    for (const key of Object.keys(root))
                        delete root[key];
                    Object.assign(root, fresh);
                    tree.added(root, null);
                }
                collectIDs(fresh, ids);
                break;
            }
            case 'insert': {
                const found = tree.locate(operation.parent) ?? fail(`inserts into “${operation.parent}”, which the view does not have.`);
                const children = (found.block.children ??= []);
                const at = operation.index ?? children.length;
                if (at > children.length)
                    fail(`inserts at ${at}, but “${operation.parent}” has ${children.length} children.`);
                parse(operation.block);
                if (['list', 'table', 'tree'].includes(found.block.type) && !hasID(operation.block))
                    fail(`: every item of “${operation.parent}” needs an “id”.`);
                const fresh = clone(operation.block);
                children.splice(at, 0, fresh);
                tree.added(fresh, found.block);
                collectIDs(fresh, ids);
                break;
            }
            case 'remove': {
                const found = tree.locate(operation.id);
                if (!found || !found.parent)
                    fail(`removes “${operation.id}”, which the view does not have (or is its root).`);
                const gone = collectIDs(found.block, new Set());
                for (const id of gone)
                    ids.delete(id);
                found.parent.children.splice(found.index, 1);
                tree.removed(found.block);
                break;
            }
            case 'move': {
                const found = tree.locate(operation.id);
                if (!found || !found.parent)
                    fail(`moves “${operation.id}”, which the view does not have (or is its root).`);
                const target = tree.locate(operation.parent) ?? fail(`moves into “${operation.parent}”, which the view does not have.`);
                if (tree.contains(found.block, target.block))
                    fail(`moves “${operation.id}” into itself.`);
                found.parent.children.splice(found.index, 1);
                const children = (target.block.children ??= []);
                const at = operation.index ?? children.length;
                if (at > children.length)
                    fail(`moves to ${at}, but “${operation.parent}” has ${children.length} children once it is out.`);
                children.splice(at, 0, found.block);
                tree.moved(found.block, target.block);
                break;
            }
            default:
                fail(`is a “${operation.op}”; a patch can replace, insert, remove or move.`);
        }
    });
    return wasList ? (root.children ?? []) : root;
}
/** At most this many operations in one `view/patch` (Vektor's protection limit). */
exports.MAX_PATCH_OPERATIONS = 10_000;
/**
 * The operations that turn `before` into `after`, by id — or `null` when only the whole description can say it (the root
 * changed, or an id moved somewhere a patch cannot express). A block without an id is looked into when its own fields stay
 * the same; when it changes itself, the nearest block above it with an id is replaced. The result is checked: applying it to
 * `before` gives exactly `after`, or `null` is returned.
 *
 * Items are matched by id, so keep ids stable: a card keeps its id wherever it moves. Its time grows with the size of the
 * trees, not with its square: blocks are found through an index by id and each container's children through a table of
 * positions, so a 3,000-card board (some 30,000 blocks) is compared in a fraction of a second.
 */
function diffBlocks(before, after) {
    if (Array.isArray(before) !== Array.isArray(after))
        return null;
    const oldRoot = asRoot(before);
    const newRoot = asRoot(after);
    if (oldRoot.type !== newRoot.type || oldRoot.id !== newRoot.id || !sameOwn(oldRoot, newRoot))
        return null;
    const work = clone(oldRoot);
    const tree = new TreeIndex(work);
    const ops = [];
    const wanted = collectIDs(newRoot, new Set());
    const leftovers = [];
    // A block can be a patch's parent when it has an id (the stack a list of blocks is read as has none).
    const canParent = (block) => hasID(block) && !(block === work && Array.isArray(before));
    const collides = (subtree, except) => {
        for (const id of collectIDs(subtree, new Set())) {
            const found = tree.locate(id);
            if (found && !(except && tree.contains(except, found.block)))
                return true;
        }
        return false;
    };
    // 1. Blocks gone from the new tree (with nothing wanted inside them) whose parent stays are removed first, so nothing
    //    has to move to close their gaps.
    const holdsWanted = new Set();
    const mark = (block) => {
        let holds = hasID(block) && wanted.has(block.id);
        for (const child of block.children ?? [])
            if (mark(child))
                holds = true;
        if (holds)
            holdsWanted.add(block);
        return holds;
    };
    mark(work);
    const early = [];
    const scan = (block) => {
        for (const child of block.children ?? []) {
            if (hasID(child) && !wanted.has(child.id) && hasID(block) && wanted.has(block.id) && !holdsWanted.has(child))
                early.push(child);
            else
                scan(child);
        }
    };
    scan(work);
    for (const block of early) {
        const found = tree.locate(block.id);
        if (!found || !found.parent)
            continue;
        found.parent.children.splice(found.index, 1);
        tree.removed(found.block);
        ops.push({ op: 'remove', id: block.id });
    }
    // Puts `block` (already out of its old place, or new) into `node` right after the wanted sibling before it.
    const place = (node, next, at, block) => {
        const children = (node.children ??= []);
        let index = 0;
        for (let back = at - 1; back >= 0; back--) {
            const sibling = hasID(next[back]) ? tree.locate(next[back].id) : null;
            if (sibling && sibling.parent === node) {
                index = sibling.index + 1;
                break;
            }
        }
        children.splice(index, 0, block);
        return index;
    };
    // 2. Blocks that changed parent are moved there (one `move` each: a card to another column).
    const crossMoves = (target) => {
        const next = target.children ?? [];
        if (hasID(target) && next.every(hasID)) {
            const node = tree.locate(target.id);
            if (node && canParent(node.block)) {
                for (let at = 0; at < next.length; at++) {
                    const found = tree.locate(next[at].id);
                    if (!found || !found.parent || found.parent === node.block)
                        continue;
                    if (tree.contains(found.block, node.block))
                        return false;
                    found.parent.children.splice(found.index, 1);
                    const index = place(node.block, next, at, found.block);
                    tree.moved(found.block, node.block);
                    ops.push({ op: 'move', id: next[at].id, parent: target.id, index });
                }
            }
        }
        return next.every(crossMoves);
    };
    if (!crossMoves(newRoot))
        return null;
    // `node.children[index]` is the block wanted there (same id): make it equal to `wantedChild`, by recursing into it or
    // by replacing it whole. False: only the whole description will do.
    const settle = (node, index, wantedChild) => {
        const child = node.children[index];
        let outcome = 'replace';
        if (child.type === wantedChild.type && sameOwn(child, wantedChild))
            outcome = reconcile(child, wantedChild);
        if (outcome === 'fail')
            return false;
        if (outcome === 'replace') {
            if (!hasID(wantedChild) || collides(wantedChild, child))
                return false;
            const fresh = clone(wantedChild);
            tree.removed(child);
            node.children[index] = fresh;
            tree.added(fresh, node);
            ops.push({ op: 'replace', id: wantedChild.id, block: clone(wantedChild) });
        }
        return true;
    };
    // 3. Each container: the longest run of children already in the right order stays; the others move (or are inserted)
    //    right after their wanted neighbour. Then each child is settled.
    // 'ok': `node` now matches `target`; 'replace': it must be replaced whole; 'fail': only the whole description will do.
    const reconcile = (node, target) => {
        const next = target.children ?? [];
        const current = node.children ?? [];
        if (sameJSON(current, next) || (current.length === 0 && next.length === 0))
            return 'ok';
        const byID = next.every(hasID) && new Set(next.map((child) => child.id)).size === next.length;
        if (!byID || !canParent(node)) {
            // Children may still change inside, but must stay the same blocks in the same order. A child without an id is "the
            // same block" when its type and own fields match: it is reconciled in turn, so a change below an id-less `scroll`
            // still patches the nearest block with an id. When that cannot be said, this block is replaced whole (or, at the
            // root, the whole description is sent).
            const sameShape = current.length === next.length && next.every((wantedChild, index) => hasID(wantedChild)
                ? current[index].id === wantedChild.id
                : !hasID(current[index]) && current[index].type === wantedChild.type && sameOwn(current[index], wantedChild));
            if (!sameShape)
                return hasID(node) && node !== work ? 'replace' : 'fail';
            for (let index = 0; index < next.length; index++) {
                if (hasID(next[index])) {
                    if (!settle(node, index, next[index]))
                        return 'fail';
                }
                else if (!sameJSON(current[index], next[index]) && reconcile(current[index], next[index]) !== 'ok') {
                    return hasID(node) && node !== work ? 'replace' : 'fail';
                }
            }
            return 'ok';
        }
        const rank = new Map(next.map((child, index) => [child.id, index]));
        const present = current.filter((child) => hasID(child) && rank.has(child.id));
        const keep = longestIncreasing(present.map((child) => rank.get(child.id))).map((at) => present[at].id);
        const kept = new Set(keep);
        for (let at = 0; at < next.length; at++) {
            const wantedChild = next[at];
            if (kept.has(wantedChild.id))
                continue;
            const found = tree.locate(wantedChild.id);
            if (found && !found.parent)
                return 'fail'; // the root's id reused for an item
            if (found) {
                if (tree.contains(found.block, node))
                    return 'fail';
                found.parent.children.splice(found.index, 1);
                const index = place(node, next, at, found.block);
                tree.moved(found.block, node);
                ops.push({ op: 'move', id: wantedChild.id, parent: node.id, index });
            }
            else {
                if (collides(wantedChild, null))
                    return 'fail';
                const fresh = clone(wantedChild);
                const index = place(node, next, at, fresh);
                tree.added(fresh, node);
                ops.push({ op: 'insert', parent: node.id, index, block: clone(wantedChild) });
            }
        }
        // Positions once (a settle replaces in place); checked before use, in case a block reconciled below took one out.
        const position = new Map();
        node.children.forEach((child, index) => { if (hasID(child))
            position.set(child.id, index); });
        for (const wantedChild of next) {
            let index = position.get(wantedChild.id) ?? -1;
            if (index < 0 || node.children[index]?.id !== wantedChild.id)
                index = node.children.findIndex((child) => child.id === wantedChild.id);
            if (index < 0 || !settle(node, index, wantedChild))
                return 'fail';
        }
        leftovers.push(...node.children.filter((child) => !(hasID(child) && rank.has(child.id))));
        return 'ok';
    };
    if (reconcile(work, newRoot) !== 'ok')
        return null;
    // 4. What is left over: blocks no longer wanted that held something wanted (moved out by now).
    for (const block of leftovers) {
        if (!hasID(block))
            return null;
        if (wanted.has(block.id))
            continue;
        const found = tree.locate(block.id);
        if (!found || !found.parent)
            continue; // inside another leftover that is already gone
        found.parent.children.splice(found.index, 1);
        tree.removed(found.block);
        ops.push({ op: 'remove', id: block.id });
    }
    if (ops.length > exports.MAX_PATCH_OPERATIONS)
        return null;
    // The check: the patch must give exactly the new tree.
    try {
        if (!sameJSON(asRoot(applyPatch(before, ops)), newRoot))
            return null;
    }
    catch {
        return null;
    }
    return ops;
}
/** The positions of a longest strictly increasing run in `values` (patience sorting). */
function longestIncreasing(values) {
    const tails = [];
    const previous = new Array(values.length).fill(-1);
    for (let index = 0; index < values.length; index++) {
        let low = 0;
        let high = tails.length;
        while (low < high) {
            const middle = (low + high) >> 1;
            if (values[tails[middle]] < values[index])
                low = middle + 1;
            else
                high = middle;
        }
        if (low > 0)
            previous[index] = tails[low - 1];
        tails[low] = index;
    }
    const result = [];
    for (let at = tails.length > 0 ? tails[tails.length - 1] : -1; at >= 0; at = previous[at])
        result.unshift(at);
    return result;
}
class ViewState {
    plugin;
    view;
    options;
    /** The revision of the description sent last (0: nothing sent yet). */
    revision = 0;
    /** The description sent last (with its revision). */
    description;
    /** The sidebar item the view was opened for (API 2), while it is open. */
    item;
    /** Whether Vektor shows the view now (between `view/opened` and `view/closed`). */
    isOpen = false;
    /** API 2: the last `view/refused` Vektor sent for this view, until it shows something sent after it. */
    refusal;
    handlers = new Map();
    fallback;
    openHandlers = [];
    closeHandlers = [];
    refusedHandlers = [];
    needsWhole = true;
    /** The revision of the last whole description sent (0: none). */
    wholeRevision = 0;
    constructor(plugin, view, options = {}) {
        this.plugin = plugin;
        this.view = view;
        this.options = options;
    }
    /** Runs on `view/opened`: describe the view here (`show`). `item` is the sidebar item it was opened for. */
    onOpen(handler) {
        this.openHandlers.push(handler);
        return this;
    }
    onClose(handler) {
        this.closeHandlers.push(handler);
        return this;
    }
    /**
     * API 2: Vektor refused a description or a patch of this view (`view/refused`); `refusal.problem` says why in plain words.
     * When the handler runs, the next `show` already sends the whole description; after a refused patch the SDK resends the kept
     * description by itself if the handler sent nothing (`resendAfterRefusal`).
     */
    onRefused(handler) {
        this.refusedHandlers.push(handler);
        return this;
    }
    /** Routes `view/event`s with this `action` (the string your description carried) to `handler`. */
    on(action, handler, options = {}) {
        this.handlers.set(action, { handler, stale: options.stale ?? 'ignoreMoves' });
        return this;
    }
    /** Receives events whose action has no handler of its own. */
    onAnyEvent(handler, options = {}) {
        this.fallback = { handler, stale: options.stale ?? 'ignoreMoves' };
        return this;
    }
    /**
     * Shows `description`: as a patch when the previous one was a block view with the same header, banner, toolbar and empty
     * state and a patch can say the change; as the whole description otherwise. Returns what was sent (`'unchanged'`: nothing,
     * the view already shows exactly this).
     */
    show(description) {
        const next = clone({ ...description, revision: undefined });
        const previous = this.description;
        if (!this.needsWhole && previous && next.blocks !== undefined && previous.blocks !== undefined) {
            const { revision: _r, blocks: oldBlocks, ...oldRest } = previous;
            const { revision: _n, blocks: newBlocks, ...newRest } = next;
            if (sameJSON(oldRest, newRest)) {
                if (sameJSON(oldBlocks, newBlocks))
                    return 'unchanged';
                const ops = this.options.patches === false ? null : diffBlocks(oldBlocks, newBlocks);
                // A patch is sent when it is smaller than the whole description (it always is for a change in a large view).
                if (ops && ops.length > 0 && JSON.stringify(ops).length < JSON.stringify(next).length) {
                    this.check(newBlocks);
                    this.revision += 1;
                    this.description = { ...next, revision: this.revision };
                    this.plugin.notify('view/patch', { view: this.view, revision: this.revision, ops });
                    return 'patch';
                }
            }
        }
        this.update(next);
        return 'update';
    }
    /** Sends the whole description (a new revision). */
    update(description) {
        const next = clone({ ...description, revision: undefined });
        if (next.blocks !== undefined)
            this.check(next.blocks);
        this.revision += 1;
        this.description = { ...next, revision: this.revision };
        this.needsWhole = false;
        this.wholeRevision = this.revision;
        this.plugin.notify('view/update', { view: this.view, description: this.description });
    }
    /** Sends patch operations you built yourself, after applying them to the kept description (so they must apply). */
    patch(ops) {
        if (!this.description || this.description.blocks === undefined || this.needsWhole) {
            throw new errors_1.PluginError(`The view “${this.view}” has no block description yet: send the whole description first.`);
        }
        if (ops.length > exports.MAX_PATCH_OPERATIONS)
            throw new errors_1.PluginError(`A patch can hold at most ${exports.MAX_PATCH_OPERATIONS} operations: send the whole view instead.`);
        const blocks = applyPatch(this.description.blocks, ops);
        this.revision += 1;
        this.description = { ...this.description, blocks, revision: this.revision };
        this.plugin.notify('view/patch', { view: this.view, revision: this.revision, ops });
    }
    /** The next `show` sends the whole description (after Vektor may have lost it: the view was reopened). */
    invalidate() {
        this.needsWhole = true;
    }
    check(blocks) {
        if (this.options.validate === false)
            return;
        const { problems } = (0, blocks_1.validateBlocks)(blocks);
        if (problems.length > 0)
            throw new errors_1.PluginError(`The view “${this.view}” cannot be shown: ${problems[0]}`);
    }
    /** Called by the plugin for this view's `view/opened`, `view/closed` and `view/event`. */
    async receive(method, params) {
        if (method === 'view/opened') {
            this.isOpen = true;
            this.item = params.item;
            this.needsWhole = true;
            this.refusal = undefined;
            for (const handler of this.openHandlers)
                await handler(params);
        }
        else if (method === 'view/closed') {
            this.isOpen = false;
            for (const handler of this.closeHandlers)
                await handler(params);
            this.item = undefined;
        }
        else if (method === 'view/refused') {
            await this.refused(params);
        }
        else if (method === 'view/event') {
            await this.dispatch(params);
        }
    }
    async refused(refusal) {
        this.refusal = refusal;
        // Vektor keeps what it showed: whatever comes next must be the whole description.
        this.needsWhole = true;
        const before = this.revision;
        for (const handler of this.refusedHandlers)
            await handler(refusal);
        // A refused patch: send the whole description again, once — not when a handler sent something already, and not when a
        // whole description went out after the refused patch (Vektor refuses the patches in between one by one).
        const after = typeof refusal.refusedRevision !== 'number' || refusal.refusedRevision > this.wholeRevision;
        if (this.options.resendAfterRefusal !== false && refusal.kind === 'patch' && this.revision === before && this.description && after) {
            this.update(this.description);
        }
    }
    async dispatch(params) {
        // An event made against the revision Vektor still shows after a refusal is not stale: Vektor never showed anything newer.
        // Once an event carries a newer revision, Vektor shows that one.
        const shown = this.refusal?.revision;
        if (typeof shown === 'number' && typeof params.revision === 'number' && params.revision > shown)
            this.refusal = undefined;
        const shownAfterRefusal = typeof shown === 'number' && this.refusal !== undefined && params.revision === shown;
        const stale = !shownAfterRefusal && typeof params.revision === 'number' && this.revision > 0 && params.revision < this.revision;
        const route = this.handlers.get(params.action) ?? this.fallback;
        if (!route)
            return;
        if (stale) {
            const isMove = params.target !== undefined || params.item !== undefined || params.before !== undefined || params.index !== undefined;
            if (route.stale === 'ignore' || (route.stale === 'ignoreMoves' && isMove))
                return;
        }
        await route.handler({ ...params, stale });
    }
}
exports.ViewState = ViewState;
