"use strict";
// Typed builders for every block of a block view (plugin API 2; docs/reference.md, "Block views"). Each builder returns
// exactly the JSON object the reference documents: a plain object with `type`, the block's fields and, for containers,
// `children`. Nothing is added that you did not ask for, so what you build is what Vektor receives.
//
// Rules the builders help with:
//   * Ids: collections' items, inputs, sections, tabs, splits, nodes and web blocks need an `id`, unique in the view. Their
//     builders take the id as the first argument. Keep ids STABLE across descriptions (a card's id is the card's own id,
//     never its position): Vektor and the view state helper diff by id.
//   * Colours: you never send a colour value. Name a role (`accent`, `positive`, `warning`, `danger`, `neutral`,
//     `label1` … `label8`). `validateBlocks` reports a `color`/`background`/… field, which Vektor ignores.
Object.defineProperty(exports, "__esModule", { value: true });
exports.WIDTHS = exports.MAX_DEPTH = exports.MAX_BLOCKS = exports.BLOCK_TYPES = exports.web = exports.fileList = exports.progress = exports.spinner = exports.rolePicker = exports.tagPicker = exports.datePicker = exports.menu = exports.stepper = exports.picker = exports.checkbox = exports.toggle = exports.textArea = exports.searchField = exports.textField = exports.button = exports.diff = exports.status = exports.banner = exports.empty = exports.markdown = exports.count = exports.badge = exports.symbol = exports.text = exports.node = exports.tree = exports.table = exports.row = exports.list = exports.panel = exports.card = exports.tab = exports.tabs = exports.section = exports.split = exports.scroll = exports.grid = exports.divider = exports.spacer = exports.hstack = exports.vstack = exports.COLOUR_VALUE_KEYS = exports.ROLE_TITLES = exports.ROLES = void 0;
exports.validateBlocks = validateBlocks;
/** Every colour role, in the order a role picker offers them. */
exports.ROLES = [
    'accent', 'positive', 'warning', 'danger', 'neutral',
    'label1', 'label2', 'label3', 'label4', 'label5', 'label6', 'label7', 'label8',
];
/** What each role is called where a person reads it: the colour is never the only thing that says which one it is. */
exports.ROLE_TITLES = {
    accent: 'Accent', positive: 'Positive', warning: 'Warning', danger: 'Danger', neutral: 'Neutral',
    label1: 'Red', label2: 'Orange', label3: 'Yellow', label4: 'Green', label5: 'Teal', label6: 'Blue', label7: 'Purple', label8: 'Pink',
};
/** The fields Vektor ignores (and logs) because they would carry a colour value. */
exports.COLOUR_VALUE_KEYS = [
    'color', 'colour', 'background', 'backgroundColor', 'foreground', 'foregroundColor', 'tint', 'fill', 'textColor',
];
function make(type, fields, children) {
    const block = { type };
    for (const [key, value] of Object.entries(fields))
        if (value !== undefined)
            block[key] = value;
    if (children !== undefined)
        block.children = children;
    return block;
}
// --- Layout --------------------------------------------------------------------------------------------------------------
const vstack = (children, options = {}) => make('vstack', options, children);
exports.vstack = vstack;
const hstack = (children, options = {}) => make('hstack', options, children);
exports.hstack = hstack;
const spacer = (options = {}) => make('spacer', options);
exports.spacer = spacer;
const divider = (options = {}) => make('divider', options);
exports.divider = divider;
/** Tiles: `columns` fixed, or as many as fit at `minWidth`. */
const grid = (children, options = {}) => make('grid', options, children);
exports.grid = grid;
const scroll = (children, options = {}) => make('scroll', options, children);
exports.scroll = scroll;
/** Two children with a divider the user drags. Inside a vertical scroll it needs a `height`. */
const split = (id, first, second, options = {}) => make('split', { id, ...options }, [first, second]);
exports.split = split;
const section = (id, children, options = {}) => make('section', { id, ...options }, children);
exports.section = section;
/** Tabs over `tab` children; `action` sends the chosen tab's id as `value`. */
const tabs = (id, children, options = {}) => make('tabs', { id, ...options }, children);
exports.tabs = tabs;
const tab = (id, title, children, options = {}) => make('tab', { id, title, ...options }, children);
exports.tab = tab;
/** An elevated surface; a role draws a stripe. As a list's item it needs an id and may be edited, checked, deleted. */
const card = (children, options = {}) => make('card', options, children);
exports.card = card;
/** A plain surface; a role draws a stripe (a board's column). */
const panel = (children, options = {}) => make('panel', options, children);
exports.panel = panel;
/** Items (usually rows or cards), drawn lazily. Every item needs an id. `spacing` is the gap between items. */
const list = (id, children, options = {}) => make('list', { id, ...options }, children);
exports.list = list;
const row = (id, options = {}, children) => make('row', { id, ...options }, children);
exports.row = row;
/** Sortable columns; `row` children with `cells`. */
const table = (id, columns, rows, options = {}) => make('table', { id, columns, ...options }, rows);
exports.table = table;
const tree = (id, nodes, options = {}) => make('tree', { id, ...options }, nodes);
exports.tree = tree;
const node = (id, title, children = [], options = {}) => make('node', { id, title, ...options }, children);
exports.node = node;
// --- Content -------------------------------------------------------------------------------------------------------------
const text = (value, options = {}) => make('text', { text: value, ...options });
exports.text = text;
const symbol = (name, options = {}) => make('symbol', { symbol: name, ...options });
exports.symbol = symbol;
/** A word on a tinted capsule. Meaning is in the word, never only in the colour. */
const badge = (value, options = {}) => make('badge', { text: value, ...options });
exports.badge = badge;
const count = (value, options = {}) => make('count', { count: value, ...options });
exports.count = count;
const markdown = (value, options = {}) => make('markdown', { markdown: value, ...options });
exports.markdown = markdown;
const empty = (value, options = {}) => make('empty', { text: value, ...options });
exports.empty = empty;
const banner = (value, options = {}) => make('banner', { text: value, ...options });
exports.banner = banner;
const status = (value, options = {}) => make('status', { text: value, ...options });
exports.status = status;
/** Two texts compared by the Diff Tool's engine, read-only. `keepLeft`/`keepRight` are actions. */
const diff = (left, right, options = {}) => make('diff', { left, right, ...options });
exports.diff = diff;
// --- Input ---------------------------------------------------------------------------------------------------------------
/** A button: needs an `action` or a `menu`. `style: 'icon'` shows only the symbol, with the tooltip. */
const button = (options) => make('button', options);
exports.button = button;
/** Return commits; a click away commits. The action arrives with the text as `value`. */
const textField = (id, action, options = {}) => make('textField', { id, action, ...options });
exports.textField = textField;
const searchField = (id, action, options = {}) => make('searchField', { id, action, ...options });
exports.searchField = searchField;
/** ⌘Return commits; a click away commits. */
const textArea = (id, action, options = {}) => make('textArea', { id, action, ...options });
exports.textArea = textArea;
const toggle = (id, action, options = {}) => make('toggle', { id, action, ...options });
exports.toggle = toggle;
const checkbox = (id, action, options = {}) => make('checkbox', { id, action, ...options });
exports.checkbox = checkbox;
/** A menu, or `style: 'segmented'`. */
const picker = (id, action, options, fields = {}) => make('picker', { id, action, options, ...fields });
exports.picker = picker;
const stepper = (id, action, options = {}) => make('stepper', { id, action, ...options });
exports.stepper = stepper;
/** A "…" (or titled) menu. */
const menu = (items, options = {}) => make('menu', { menu: items, ...options });
exports.menu = menu;
/** `value` is `yyyy-MM-dd`. */
const datePicker = (id, action, options = {}) => make('datePicker', { id, action, ...options });
exports.datePicker = datePicker;
const tagPicker = (id, action, options = {}) => make('tagPicker', { id, action, ...options });
exports.tagPicker = tagPicker;
/** A colour role, never a value. `roles` limits what it offers (sent as options with each role's name). */
const rolePicker = (id, action, options = {}) => {
    const { roles, ...rest } = options;
    return make('rolePicker', {
        id, action, ...rest,
        options: roles ? roles.map((role) => ({ value: role, title: exports.ROLE_TITLES[role] })) : undefined,
    });
};
exports.rolePicker = rolePicker;
// --- Feedback, files, web ------------------------------------------------------------------------------------------------
const spinner = (options = {}) => make('spinner', options);
exports.spinner = spinner;
/** `progress` 0…1; none: indeterminate. */
const progress = (options = {}) => make('progress', options);
exports.progress = progress;
/** Files and folders with Vektor's icons. Absolute paths; a folder ends in `/`. */
const fileList = (files, options = {}) => make('fileList', { files, ...options });
exports.fileList = fileList;
/** A page of the plugin's own files (`entry`, inside the plugin folder). Inside a vertical scroll it takes `height`. */
const web = (id, entry, options = {}) => make('web', { id, entry, ...options });
exports.web = web;
// --- Checking a tree the way Vektor does ---------------------------------------------------------------------------------
const COLLECTIONS = new Set(['list', 'table', 'tree']);
const INPUTS = new Set(['textField', 'textArea', 'searchField', 'toggle', 'picker', 'stepper', 'checkbox', 'datePicker', 'tagPicker', 'rolePicker']);
const NEEDS_ID = new Set([...COLLECTIONS, ...INPUTS, 'node', 'tabs', 'section', 'split', 'web']);
/** Every block type this SDK knows (the reference's table). */
exports.BLOCK_TYPES = new Set([
    'vstack', 'hstack', 'spacer', 'divider', 'grid', 'scroll', 'split', 'section', 'tabs', 'tab', 'card', 'panel',
    'list', 'row', 'table', 'tree', 'node',
    'text', 'symbol', 'badge', 'count', 'markdown', 'empty', 'banner', 'status', 'diff',
    'button', 'textField', 'textArea', 'searchField', 'toggle', 'picker', 'stepper', 'checkbox', 'menu', 'datePicker', 'tagPicker', 'rolePicker',
    'spinner', 'progress', 'fileList', 'web',
]);
exports.MAX_BLOCKS = 100_000;
exports.MAX_DEPTH = 64;
/** What `width`, `minWidth` and `maxWidth` may be, in points. */
exports.WIDTHS = { min: 20, max: 4000 };
const WIDTH_KEYS = ['width', 'minWidth', 'maxWidth'];
/** A string with something in it besides white space: Vektor trims a required string and treats an empty one as missing. */
const filled = (value) => typeof value === 'string' && value.trim() !== '';
/**
 * What Vektor would refuse in a block tree (`blocks`: one block or a list), in plain words — empty when it would draw it.
 * `warnings` collects what Vektor would ignore (a colour value, an unknown role). The same rules as Vektor's: every block
 * has a `type`; ids are unique; items of a collection, inputs, sections, tabs, splits, nodes and web blocks have an id;
 * a button has an action or a menu; a picker has options, each with a value and a title; a menu has items, each with a title
 * and an action; a table has columns, each with an id and a title; a web block has an entry; tabs hold only tabs; at most
 * 100,000 blocks nested at most 64 deep. Like Vektor, it trims these strings: an empty or blank one counts as missing.
 */
function validateBlocks(blocks, existingIDs = []) {
    const problems = [];
    const warnings = [];
    // A set is read as it is, never copied (a patch checks each block against every id of a big tree).
    const taken = existingIDs instanceof Set ? existingIDs : new Set(existingIDs);
    const seen = new Set();
    let nodes = 0;
    const visit = (value, depth, inCollection) => {
        if (depth > exports.MAX_DEPTH)
            return problems.push(`blocks are nested more than ${exports.MAX_DEPTH} deep.`), false;
        if (++nodes > exports.MAX_BLOCKS)
            return problems.push(`a view can hold at most ${exports.MAX_BLOCKS} blocks.`), false;
        if (value === null || typeof value !== 'object' || Array.isArray(value))
            return problems.push('every block must be an object.'), false;
        const block = value;
        if (!filled(block.type))
            return problems.push('every block needs a “type”.'), false;
        const id = filled(block.id) ? block.id : undefined;
        if (id !== undefined) {
            if (seen.has(id) || taken.has(id))
                return problems.push(`the block “${id}” is listed twice.`), false;
            seen.add(id);
        }
        else if (inCollection !== null) {
            return problems.push(`every item of “${inCollection}” needs an “id”.`), false;
        }
        else if (NEEDS_ID.has(block.type)) {
            return problems.push(`a “${block.type}” block needs an “id”.`), false;
        }
        const name = id ?? block.type;
        for (const key of exports.COLOUR_VALUE_KEYS) {
            if (key in block)
                warnings.push(`the block “${name}” carries a colour value (“${key}”), which Vektor ignores: name a “role” instead.`);
        }
        if (!exports.BLOCK_TYPES.has(block.type)) {
            warnings.push(`“${block.type}” is not a block type this SDK knows; an older Vektor draws it as “needs a newer Vektor”.`);
            return true;
        }
        if (block.role !== undefined && !exports.ROLES.includes(block.role)) {
            warnings.push(`the block “${name}” names a colour role Vektor does not know (${JSON.stringify(block.role)}).`);
        }
        for (const key of WIDTH_KEYS) {
            const value = block[key];
            if (value === undefined || value === null)
                continue;
            if (typeof value !== 'number' || !Number.isFinite(value) || value < exports.WIDTHS.min || value > exports.WIDTHS.max) {
                warnings.push(`the block “${name}” asks for a “${key}” of ${JSON.stringify(value)}, which Vektor ignores: a number of points from 20 to 4000.`);
            }
        }
        if (block.grow !== undefined && block.grow !== null && typeof block.grow !== 'boolean') {
            warnings.push(`the block “${name}” has a “grow” of ${JSON.stringify(block.grow)}, which Vektor reads as false: “grow” is true or false.`);
        }
        const lacks = (field) => block[field] === undefined || (Array.isArray(block[field]) && block[field].length === 0);
        if (block.type === 'button' && !filled(block.action) && lacks('menu'))
            problems.push(`the button “${name}” needs an “action”.`);
        if (block.type === 'picker' && lacks('options'))
            problems.push(`the picker “${name}” needs “options”.`);
        if (block.type === 'menu' && lacks('menu'))
            problems.push(`the menu “${name}” needs items in “menu”.`);
        if (block.type === 'table' && lacks('columns'))
            problems.push(`the table “${name}” needs “columns”.`);
        if (block.type === 'web' && !filled(block.entry))
            problems.push(`the web block “${name}” needs an “entry”: the page to show.`);
        if (Array.isArray(block.options)) {
            for (const option of block.options) {
                if (!option || !filled(option.value) || !filled(option.title)) {
                    problems.push(`every option of “${name}” needs a “value” and a “title”.`);
                    break;
                }
            }
        }
        for (const entry of (Array.isArray(block.menu) ? block.menu : [])) {
            if (entry && entry.separator === true)
                continue;
            if (!entry || !filled(entry.title) || !filled(entry.action)) {
                problems.push(`a menu item of “${name}” needs a “title” and an “action”.`);
                break;
            }
        }
        if (block.type === 'table' && Array.isArray(block.columns)) {
            for (const column of block.columns) {
                if (!column || !filled(column.id) || !filled(column.title)) {
                    problems.push(`every column of “${name}” needs an “id” and a “title”.`);
                    break;
                }
            }
        }
        if (block.children !== undefined && block.children !== null) {
            if (!Array.isArray(block.children))
                return problems.push(`the “children” of “${name}” must be a list.`), false;
            if (block.type === 'tabs' && block.children.some((child) => child && child.type !== 'tab' && exports.BLOCK_TYPES.has(child.type))) {
                problems.push(`every child of the tabs “${name}” must be a “tab”.`);
            }
            const collection = COLLECTIONS.has(block.type) || block.type === 'node' ? name : null;
            for (const child of block.children)
                if (!visit(child, depth + 1, collection))
                    return false;
        }
        return true;
    };
    visit(Array.isArray(blocks) ? { type: 'vstack', children: blocks } : blocks, 0, null);
    return { problems, warnings };
}
