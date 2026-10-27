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

export type Role =
  | 'accent' | 'positive' | 'warning' | 'danger' | 'neutral'
  | 'label1' | 'label2' | 'label3' | 'label4' | 'label5' | 'label6' | 'label7' | 'label8';

/** Every colour role, in the order a role picker offers them. */
export const ROLES: readonly Role[] = [
  'accent', 'positive', 'warning', 'danger', 'neutral',
  'label1', 'label2', 'label3', 'label4', 'label5', 'label6', 'label7', 'label8',
];

/** What each role is called where a person reads it: the colour is never the only thing that says which one it is. */
export const ROLE_TITLES: Readonly<Record<Role, string>> = {
  accent: 'Accent', positive: 'Positive', warning: 'Warning', danger: 'Danger', neutral: 'Neutral',
  label1: 'Red', label2: 'Orange', label3: 'Yellow', label4: 'Green', label5: 'Teal', label6: 'Blue', label7: 'Purple', label8: 'Pink',
};

/** The fields Vektor ignores (and logs) because they would carry a colour value. */
export const COLOUR_VALUE_KEYS: readonly string[] = [
  'color', 'colour', 'background', 'backgroundColor', 'foreground', 'foregroundColor', 'tint', 'fill', 'textColor',
];

/** A block: its `type`, its fields, and its children. */
export interface Block {
  type: string;
  id?: string;
  children?: Block[];
  [field: string]: unknown;
}

/** One item of a context menu or a "…" menu, or a separator. */
export type MenuEntry =
  | { title: string; action: string; symbol?: string; destructive?: boolean; enabled?: boolean }
  | { separator: true };

/** A small button on a row (`buttons`). */
export interface Control { title: string; action: string; symbol?: string; enabled?: boolean }

/** A word on a tinted capsule beside a title (a card's, a panel's, a row's `badge`). */
export interface Badge { text: string; role?: Role }

/** Fields every block may carry. */
export interface Common {
  id?: string;
  /** A context menu. */
  menu?: MenuEntry[];
  tooltip?: string;
  /** What VoiceOver reads. */
  label?: string;
  /** The block can be dragged; the value is its group. */
  drag?: string;
  /** Blocks of these drag groups may be dropped here; `action` is sent with `item`, `target`, `index`. */
  drop?: { action: string; accepts: string[] };
  /** Files and folders dropped from Vektor's panes or Finder (local items only). */
  fileDrop?: { action: string; accepts?: 'files' | 'folders' | 'both'; extensions?: string[] };
  /** Drawn only while the pointer is over it or it has the keyboard. */
  revealOnHover?: boolean;
  enabled?: boolean;
  /** An inline error under an input. */
  error?: string;
  // Widths (API 2): structural numbers in points, never a theme's, from 20 to 4000 (`WIDTHS`; Vektor ignores another value
  // and the Log says so — `validateBlocks` warns). A block without them is drawn as before.
  /** The width the block asks for; never wider than its row offers, so it cannot push the view past the pane. */
  width?: number;
  /** The narrowest it is drawn: honoured inside a horizontal `scroll` only, which shows the rest by scrolling. On a `grid`,
   *  `minWidth` keeps its own meaning: the tile minimum. */
  minWidth?: number;
  /** The widest it is drawn. */
  maxWidth?: number;
  /** The block takes a share of the width its row leaves; growing siblings share it equally. Inside a horizontal `scroll`, a
   *  growing child makes the row at least as wide as the scroll is shown (a board whose columns fill the pane). */
  grow?: boolean;
}

/** What an item of a collection (a row, a card) can do. */
export interface ItemFields {
  /** Sent on Return or a double-click. */
  action?: string;
  /** The title can be edited in place; this action is sent with the new `value`. */
  edit?: string;
  /** ⌫ or ⌘⌫ sends this action. */
  delete?: string;
  /** A checkbox: this action is sent with the new state as `value`. */
  check?: string;
  checked?: boolean;
  dimmed?: boolean;
}

function make(type: string, fields: object, children?: Block[]): Block {
  const block: Block = { type };
  for (const [key, value] of Object.entries(fields)) if (value !== undefined) block[key] = value;
  if (children !== undefined) block.children = children;
  return block;
}

// --- Layout --------------------------------------------------------------------------------------------------------------

export const vstack = (children: Block[], options: Common & { spacing?: number } = {}): Block => make('vstack', options, children);
export const hstack = (children: Block[], options: Common & { spacing?: number } = {}): Block => make('hstack', options, children);
export const spacer = (options: Common = {}): Block => make('spacer', options);
export const divider = (options: Common = {}): Block => make('divider', options);
/** Tiles: `columns` fixed, or as many as fit at `minWidth`. */
export const grid = (children: Block[], options: Common & { columns?: number; minWidth?: number; spacing?: number } = {}): Block =>
  make('grid', options, children);
export const scroll = (children: Block[], options: Common & { axis?: 'vertical' | 'horizontal' | 'both'; spacing?: number } = {}): Block =>
  make('scroll', options, children);
/** Two children with a divider the user drags. Inside a vertical scroll it needs a `height`. */
export const split = (
  id: string, first: Block, second: Block,
  options: Common & { axis?: 'horizontal' | 'vertical'; fraction?: number; height?: number } = {},
): Block => make('split', { id, ...options }, [first, second]);
export const section = (
  id: string, children: Block[],
  options: Common & { title?: string; collapsible?: boolean; collapsed?: boolean; count?: number } = {},
): Block => make('section', { id, ...options }, children);
/** Tabs over `tab` children; `action` sends the chosen tab's id as `value`. */
export const tabs = (id: string, children: Block[], options: Common & { style?: 'tabs' | 'segmented'; action?: string } = {}): Block =>
  make('tabs', { id, ...options }, children);
export const tab = (id: string, title: string, children: Block[], options: Common & { symbol?: string } = {}): Block =>
  make('tab', { id, title, ...options }, children);
/** An elevated surface; a role draws a stripe. As a list's item it needs an id and may be edited, checked, deleted. */
export const card = (
  children: Block[],
  options: Common & ItemFields & { title?: string; symbol?: string; role?: Role; badge?: Badge } = {},
): Block => make('card', options, children);
/** A plain surface; a role draws a stripe (a board's column). */
export const panel = (
  children: Block[],
  options: Common & ItemFields & { title?: string; symbol?: string; role?: Role; badge?: Badge } = {},
): Block => make('panel', options, children);

// --- Collections ---------------------------------------------------------------------------------------------------------

export interface CollectionFields {
  /** `none` (default), `single` or `multiple`. */
  selection?: 'none' | 'single' | 'multiple';
  /** Sent with `selected` (the ids) when the selection changes. */
  select?: string;
  /** The ids selected now. */
  selected?: string[];
}

/** Items (usually rows or cards), drawn lazily. Every item needs an id. `spacing` is the gap between items. */
export const list = (
  id: string, children: Block[],
  options: Common & CollectionFields & { group?: string; move?: string; placeholder?: string; spacing?: number } = {},
): Block => make('list', { id, ...options }, children);
export const row = (
  id: string,
  options: Common & ItemFields & {
    title?: string; subtitle?: string; symbol?: string; badge?: Badge; buttons?: Control[];
    /** A table row's cells, in the table's column order. */
    cells?: (string | number)[];
  } = {},
  children?: Block[],
): Block => make('row', { id, ...options }, children);
export interface Column { id: string; title: string; width?: number; sortable?: boolean }
/** Sortable columns; `row` children with `cells`. */
export const table = (
  id: string, columns: Column[], rows: Block[],
  options: Common & CollectionFields & { sorted?: { column: string; ascending: boolean }; sort?: string } = {},
): Block => make('table', { id, columns, ...options }, rows);
export const tree = (id: string, nodes: Block[], options: Common & CollectionFields = {}): Block => make('tree', { id, ...options }, nodes);
export const node = (
  id: string, title: string, children: Block[] = [],
  options: Common & ItemFields & { symbol?: string; expanded?: boolean } = {},
): Block => make('node', { id, title, ...options }, children);

// --- Content -------------------------------------------------------------------------------------------------------------

export const text = (
  value: string,
  options: Common & { style?: 'title' | 'heading' | 'body' | 'caption' | 'mono'; selectable?: boolean; link?: string; role?: Role; lineLimit?: number } = {},
): Block => make('text', { text: value, ...options });
export const symbol = (name: string, options: Common & { role?: Role } = {}): Block => make('symbol', { symbol: name, ...options });
/** A word on a tinted capsule. Meaning is in the word, never only in the colour. */
export const badge = (value: string, options: Common & { role?: Role } = {}): Block => make('badge', { text: value, ...options });
export const count = (value: number, options: Common & { role?: Role } = {}): Block => make('count', { count: value, ...options });
export const markdown = (value: string, options: Common = {}): Block => make('markdown', { markdown: value, ...options });
type NoteFields = Common & { title?: string; symbol?: string; role?: Role; link?: string };
export const empty = (value: string, options: NoteFields = {}): Block => make('empty', { text: value, ...options });
export const banner = (value: string, options: NoteFields = {}): Block => make('banner', { text: value, ...options });
export const status = (value: string, options: NoteFields = {}): Block => make('status', { text: value, ...options });
/** Two texts compared by the Diff Tool's engine, read-only. `keepLeft`/`keepRight` are actions. */
export const diff = (
  left: string, right: string,
  options: Common & { leftTitle?: string; rightTitle?: string; keepLeft?: string; keepRight?: string } = {},
): Block => make('diff', { left, right, ...options });

// --- Input ---------------------------------------------------------------------------------------------------------------

/** A button: needs an `action` or a `menu`. `style: 'icon'` shows only the symbol, with the tooltip. */
export const button = (
  options: Common & { title?: string; symbol?: string; action?: string; style?: 'primary' | 'plain' | 'destructive' | 'icon'; busy?: boolean },
): Block => make('button', options);
type TextInput = Common & { value?: string; placeholder?: string; title?: string };
/** Return commits; a click away commits. The action arrives with the text as `value`. */
export const textField = (id: string, action: string, options: TextInput = {}): Block => make('textField', { id, action, ...options });
export const searchField = (id: string, action: string, options: TextInput = {}): Block => make('searchField', { id, action, ...options });
/** ⌘Return commits; a click away commits. */
export const textArea = (id: string, action: string, options: TextInput = {}): Block => make('textArea', { id, action, ...options });
export const toggle = (id: string, action: string, options: Common & { value?: boolean; title?: string } = {}): Block =>
  make('toggle', { id, action, ...options });
export const checkbox = (id: string, action: string, options: Common & { value?: boolean; title?: string } = {}): Block =>
  make('checkbox', { id, action, ...options });
export interface Option { value: string; title: string; symbol?: string }
/** A menu, or `style: 'segmented'`. */
export const picker = (id: string, action: string, options: Option[], fields: Common & { value?: string; style?: 'menu' | 'segmented' } = {}): Block =>
  make('picker', { id, action, options, ...fields });
export const stepper = (id: string, action: string, options: Common & { value?: number; min?: number; max?: number; step?: number } = {}): Block =>
  make('stepper', { id, action, ...options });
/** A "…" (or titled) menu. */
export const menu = (items: MenuEntry[], options: Omit<Common, 'menu'> & { title?: string; symbol?: string } = {}): Block =>
  make('menu', { menu: items, ...options });
/** `value` is `yyyy-MM-dd`. */
export const datePicker = (id: string, action: string, options: Common & { value?: string } = {}): Block =>
  make('datePicker', { id, action, ...options });
export const tagPicker = (id: string, action: string, options: Common & { tags?: string[]; suggestions?: string[] } = {}): Block =>
  make('tagPicker', { id, action, ...options });
/** A colour role, never a value. `roles` limits what it offers (sent as options with each role's name). */
export const rolePicker = (id: string, action: string, options: Common & { value?: Role; roles?: Role[] } = {}): Block => {
  const { roles, ...rest } = options;
  return make('rolePicker', {
    id, action, ...rest,
    options: roles ? roles.map((role) => ({ value: role, title: ROLE_TITLES[role] })) : undefined,
  });
};

// --- Feedback, files, web ------------------------------------------------------------------------------------------------

export const spinner = (options: Common & { text?: string } = {}): Block => make('spinner', options);
/** `progress` 0…1; none: indeterminate. */
export const progress = (options: Common & { progress?: number; title?: string; text?: string } = {}): Block => make('progress', options);
/** Files and folders with Vektor's icons. Absolute paths; a folder ends in `/`. */
export const fileList = (files: string[], options: Common = {}): Block => make('fileList', { files, ...options });
/** A page of the plugin's own files (`entry`, inside the plugin folder). Inside a vertical scroll it takes `height`. */
export const web = (id: string, entry: string, options: Common & { height?: number } = {}): Block => make('web', { id, entry, ...options });

// --- Checking a tree the way Vektor does ---------------------------------------------------------------------------------

const COLLECTIONS = new Set(['list', 'table', 'tree']);
const INPUTS = new Set(['textField', 'textArea', 'searchField', 'toggle', 'picker', 'stepper', 'checkbox', 'datePicker', 'tagPicker', 'rolePicker']);
const NEEDS_ID = new Set([...COLLECTIONS, ...INPUTS, 'node', 'tabs', 'section', 'split', 'web']);
/** Every block type this SDK knows (the reference's table). */
export const BLOCK_TYPES: ReadonlySet<string> = new Set([
  'vstack', 'hstack', 'spacer', 'divider', 'grid', 'scroll', 'split', 'section', 'tabs', 'tab', 'card', 'panel',
  'list', 'row', 'table', 'tree', 'node',
  'text', 'symbol', 'badge', 'count', 'markdown', 'empty', 'banner', 'status', 'diff',
  'button', 'textField', 'textArea', 'searchField', 'toggle', 'picker', 'stepper', 'checkbox', 'menu', 'datePicker', 'tagPicker', 'rolePicker',
  'spinner', 'progress', 'fileList', 'web',
]);
export const MAX_BLOCKS = 100_000;
export const MAX_DEPTH = 64;
/** What `width`, `minWidth` and `maxWidth` may be, in points. */
export const WIDTHS = { min: 20, max: 4000 } as const;
const WIDTH_KEYS = ['width', 'minWidth', 'maxWidth'] as const;

/** A string with something in it besides white space: Vektor trims a required string and treats an empty one as missing. */
const filled = (value: unknown): value is string => typeof value === 'string' && value.trim() !== '';

/**
 * What Vektor would refuse in a block tree (`blocks`: one block or a list), in plain words — empty when it would draw it.
 * `warnings` collects what Vektor would ignore (a colour value, an unknown role). The same rules as Vektor's: every block
 * has a `type`; ids are unique; items of a collection, inputs, sections, tabs, splits, nodes and web blocks have an id;
 * a button has an action or a menu; a picker has options, each with a value and a title; a menu has items, each with a title
 * and an action; a table has columns, each with an id and a title; a web block has an entry; tabs hold only tabs; at most
 * 100,000 blocks nested at most 64 deep. Like Vektor, it trims these strings: an empty or blank one counts as missing.
 */
export function validateBlocks(blocks: Block | Block[], existingIDs: Iterable<string> = []): { problems: string[]; warnings: string[] } {
  const problems: string[] = [];
  const warnings: string[] = [];
  // A set is read as it is, never copied (a patch checks each block against every id of a big tree).
  const taken: ReadonlySet<string> = existingIDs instanceof Set ? existingIDs : new Set<string>(existingIDs);
  const seen = new Set<string>();
  let nodes = 0;
  const visit = (value: unknown, depth: number, inCollection: string | null): boolean => {
    if (depth > MAX_DEPTH) return problems.push(`blocks are nested more than ${MAX_DEPTH} deep.`), false;
    if (++nodes > MAX_BLOCKS) return problems.push(`a view can hold at most ${MAX_BLOCKS} blocks.`), false;
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return problems.push('every block must be an object.'), false;
    const block = value as Block;
    if (!filled(block.type)) return problems.push('every block needs a “type”.'), false;
    const id = filled(block.id) ? block.id : undefined;
    if (id !== undefined) {
      if (seen.has(id) || taken.has(id)) return problems.push(`the block “${id}” is listed twice.`), false;
      seen.add(id);
    } else if (inCollection !== null) {
      return problems.push(`every item of “${inCollection}” needs an “id”.`), false;
    } else if (NEEDS_ID.has(block.type)) {
      return problems.push(`a “${block.type}” block needs an “id”.`), false;
    }
    const name = id ?? block.type;
    for (const key of COLOUR_VALUE_KEYS) {
      if (key in block) warnings.push(`the block “${name}” carries a colour value (“${key}”), which Vektor ignores: name a “role” instead.`);
    }
    if (!BLOCK_TYPES.has(block.type)) {
      warnings.push(`“${block.type}” is not a block type this SDK knows; an older Vektor draws it as “needs a newer Vektor”.`);
      return true;
    }
    if (block.role !== undefined && !ROLES.includes(block.role as Role)) {
      warnings.push(`the block “${name}” names a colour role Vektor does not know (${JSON.stringify(block.role)}).`);
    }
    for (const key of WIDTH_KEYS) {
      const value = block[key];
      if (value === undefined || value === null) continue;
      if (typeof value !== 'number' || !Number.isFinite(value) || value < WIDTHS.min || value > WIDTHS.max) {
        warnings.push(`the block “${name}” asks for a “${key}” of ${JSON.stringify(value)}, which Vektor ignores: a number of points from 20 to 4000.`);
      }
    }
    if (block.grow !== undefined && block.grow !== null && typeof block.grow !== 'boolean') {
      warnings.push(`the block “${name}” has a “grow” of ${JSON.stringify(block.grow)}, which Vektor reads as false: “grow” is true or false.`);
    }
    const lacks = (field: string) => block[field] === undefined || (Array.isArray(block[field]) && (block[field] as unknown[]).length === 0);
    if (block.type === 'button' && !filled(block.action) && lacks('menu')) problems.push(`the button “${name}” needs an “action”.`);
    if (block.type === 'picker' && lacks('options')) problems.push(`the picker “${name}” needs “options”.`);
    if (block.type === 'menu' && lacks('menu')) problems.push(`the menu “${name}” needs items in “menu”.`);
    if (block.type === 'table' && lacks('columns')) problems.push(`the table “${name}” needs “columns”.`);
    if (block.type === 'web' && !filled(block.entry)) problems.push(`the web block “${name}” needs an “entry”: the page to show.`);
    if (Array.isArray(block.options)) {
      for (const option of block.options as Record<string, unknown>[]) {
        if (!option || !filled(option.value) || !filled(option.title)) {
          problems.push(`every option of “${name}” needs a “value” and a “title”.`);
          break;
        }
      }
    }
    for (const entry of (Array.isArray(block.menu) ? block.menu : []) as Record<string, unknown>[]) {
      if (entry && entry.separator === true) continue;
      if (!entry || !filled(entry.title) || !filled(entry.action)) {
        problems.push(`a menu item of “${name}” needs a “title” and an “action”.`);
        break;
      }
    }
    if (block.type === 'table' && Array.isArray(block.columns)) {
      for (const column of block.columns as Record<string, unknown>[]) {
        if (!column || !filled(column.id) || !filled(column.title)) {
          problems.push(`every column of “${name}” needs an “id” and a “title”.`);
          break;
        }
      }
    }
    if (block.children !== undefined && block.children !== null) {
      if (!Array.isArray(block.children)) return problems.push(`the “children” of “${name}” must be a list.`), false;
      if (block.type === 'tabs' && block.children.some((child) => child && child.type !== 'tab' && BLOCK_TYPES.has(child.type))) {
        problems.push(`every child of the tabs “${name}” must be a “tab”.`);
      }
      const collection = COLLECTIONS.has(block.type) || block.type === 'node' ? name : null;
      for (const child of block.children) if (!visit(child, depth + 1, collection)) return false;
    }
    return true;
  };
  visit(Array.isArray(blocks) ? { type: 'vstack', children: blocks } : blocks, 0, null);
  return { problems, warnings };
}
