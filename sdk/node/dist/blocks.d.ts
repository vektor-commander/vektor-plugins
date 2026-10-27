export type Role = 'accent' | 'positive' | 'warning' | 'danger' | 'neutral' | 'label1' | 'label2' | 'label3' | 'label4' | 'label5' | 'label6' | 'label7' | 'label8';
/** Every colour role, in the order a role picker offers them. */
export declare const ROLES: readonly Role[];
/** What each role is called where a person reads it: the colour is never the only thing that says which one it is. */
export declare const ROLE_TITLES: Readonly<Record<Role, string>>;
/** The fields Vektor ignores (and logs) because they would carry a colour value. */
export declare const COLOUR_VALUE_KEYS: readonly string[];
/** A block: its `type`, its fields, and its children. */
export interface Block {
    type: string;
    id?: string;
    children?: Block[];
    [field: string]: unknown;
}
/** One item of a context menu or a "…" menu, or a separator. */
export type MenuEntry = {
    title: string;
    action: string;
    symbol?: string;
    destructive?: boolean;
    enabled?: boolean;
} | {
    separator: true;
};
/** A small button on a row (`buttons`). */
export interface Control {
    title: string;
    action: string;
    symbol?: string;
    enabled?: boolean;
}
/** A word on a tinted capsule beside a title (a card's, a panel's, a row's `badge`). */
export interface Badge {
    text: string;
    role?: Role;
}
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
    drop?: {
        action: string;
        accepts: string[];
    };
    /** Files and folders dropped from Vektor's panes or Finder (local items only). */
    fileDrop?: {
        action: string;
        accepts?: 'files' | 'folders' | 'both';
        extensions?: string[];
    };
    /** Drawn only while the pointer is over it or it has the keyboard. */
    revealOnHover?: boolean;
    enabled?: boolean;
    /** An inline error under an input. */
    error?: string;
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
export declare const vstack: (children: Block[], options?: Common & {
    spacing?: number;
}) => Block;
export declare const hstack: (children: Block[], options?: Common & {
    spacing?: number;
}) => Block;
export declare const spacer: (options?: Common) => Block;
export declare const divider: (options?: Common) => Block;
/** Tiles: `columns` fixed, or as many as fit at `minWidth`. */
export declare const grid: (children: Block[], options?: Common & {
    columns?: number;
    minWidth?: number;
    spacing?: number;
}) => Block;
export declare const scroll: (children: Block[], options?: Common & {
    axis?: 'vertical' | 'horizontal' | 'both';
    spacing?: number;
}) => Block;
/** Two children with a divider the user drags. Inside a vertical scroll it needs a `height`. */
export declare const split: (id: string, first: Block, second: Block, options?: Common & {
    axis?: 'horizontal' | 'vertical';
    fraction?: number;
    height?: number;
}) => Block;
export declare const section: (id: string, children: Block[], options?: Common & {
    title?: string;
    collapsible?: boolean;
    collapsed?: boolean;
    count?: number;
}) => Block;
/** Tabs over `tab` children; `action` sends the chosen tab's id as `value`. */
export declare const tabs: (id: string, children: Block[], options?: Common & {
    style?: 'tabs' | 'segmented';
    action?: string;
}) => Block;
export declare const tab: (id: string, title: string, children: Block[], options?: Common & {
    symbol?: string;
}) => Block;
/** An elevated surface; a role draws a stripe. As a list's item it needs an id and may be edited, checked, deleted. */
export declare const card: (children: Block[], options?: Common & ItemFields & {
    title?: string;
    symbol?: string;
    role?: Role;
    badge?: Badge;
}) => Block;
/** A plain surface; a role draws a stripe (a board's column). */
export declare const panel: (children: Block[], options?: Common & ItemFields & {
    title?: string;
    symbol?: string;
    role?: Role;
    badge?: Badge;
}) => Block;
export interface CollectionFields {
    /** `none` (default), `single` or `multiple`. */
    selection?: 'none' | 'single' | 'multiple';
    /** Sent with `selected` (the ids) when the selection changes. */
    select?: string;
    /** The ids selected now. */
    selected?: string[];
}
/** Items (usually rows or cards), drawn lazily. Every item needs an id. `spacing` is the gap between items. */
export declare const list: (id: string, children: Block[], options?: Common & CollectionFields & {
    group?: string;
    move?: string;
    placeholder?: string;
    spacing?: number;
}) => Block;
export declare const row: (id: string, options?: Common & ItemFields & {
    title?: string;
    subtitle?: string;
    symbol?: string;
    badge?: Badge;
    buttons?: Control[];
    /** A table row's cells, in the table's column order. */
    cells?: (string | number)[];
}, children?: Block[]) => Block;
export interface Column {
    id: string;
    title: string;
    width?: number;
    sortable?: boolean;
}
/** Sortable columns; `row` children with `cells`. */
export declare const table: (id: string, columns: Column[], rows: Block[], options?: Common & CollectionFields & {
    sorted?: {
        column: string;
        ascending: boolean;
    };
    sort?: string;
}) => Block;
export declare const tree: (id: string, nodes: Block[], options?: Common & CollectionFields) => Block;
export declare const node: (id: string, title: string, children?: Block[], options?: Common & ItemFields & {
    symbol?: string;
    expanded?: boolean;
}) => Block;
export declare const text: (value: string, options?: Common & {
    style?: 'title' | 'heading' | 'body' | 'caption' | 'mono';
    selectable?: boolean;
    link?: string;
    role?: Role;
    lineLimit?: number;
}) => Block;
export declare const symbol: (name: string, options?: Common & {
    role?: Role;
}) => Block;
/** A word on a tinted capsule. Meaning is in the word, never only in the colour. */
export declare const badge: (value: string, options?: Common & {
    role?: Role;
}) => Block;
export declare const count: (value: number, options?: Common & {
    role?: Role;
}) => Block;
export declare const markdown: (value: string, options?: Common) => Block;
type NoteFields = Common & {
    title?: string;
    symbol?: string;
    role?: Role;
    link?: string;
};
export declare const empty: (value: string, options?: NoteFields) => Block;
export declare const banner: (value: string, options?: NoteFields) => Block;
export declare const status: (value: string, options?: NoteFields) => Block;
/** Two texts compared by the Diff Tool's engine, read-only. `keepLeft`/`keepRight` are actions. */
export declare const diff: (left: string, right: string, options?: Common & {
    leftTitle?: string;
    rightTitle?: string;
    keepLeft?: string;
    keepRight?: string;
}) => Block;
/** A button: needs an `action` or a `menu`. `style: 'icon'` shows only the symbol, with the tooltip. */
export declare const button: (options: Common & {
    title?: string;
    symbol?: string;
    action?: string;
    style?: 'primary' | 'plain' | 'destructive' | 'icon';
    busy?: boolean;
}) => Block;
type TextInput = Common & {
    value?: string;
    placeholder?: string;
    title?: string;
};
/** Return commits; a click away commits. The action arrives with the text as `value`. */
export declare const textField: (id: string, action: string, options?: TextInput) => Block;
export declare const searchField: (id: string, action: string, options?: TextInput) => Block;
/** ⌘Return commits; a click away commits. */
export declare const textArea: (id: string, action: string, options?: TextInput) => Block;
export declare const toggle: (id: string, action: string, options?: Common & {
    value?: boolean;
    title?: string;
}) => Block;
export declare const checkbox: (id: string, action: string, options?: Common & {
    value?: boolean;
    title?: string;
}) => Block;
export interface Option {
    value: string;
    title: string;
    symbol?: string;
}
/** A menu, or `style: 'segmented'`. */
export declare const picker: (id: string, action: string, options: Option[], fields?: Common & {
    value?: string;
    style?: 'menu' | 'segmented';
}) => Block;
export declare const stepper: (id: string, action: string, options?: Common & {
    value?: number;
    min?: number;
    max?: number;
    step?: number;
}) => Block;
/** A "…" (or titled) menu. */
export declare const menu: (items: MenuEntry[], options?: Omit<Common, 'menu'> & {
    title?: string;
    symbol?: string;
}) => Block;
/** `value` is `yyyy-MM-dd`. */
export declare const datePicker: (id: string, action: string, options?: Common & {
    value?: string;
}) => Block;
export declare const tagPicker: (id: string, action: string, options?: Common & {
    tags?: string[];
    suggestions?: string[];
}) => Block;
/** A colour role, never a value. `roles` limits what it offers (sent as options with each role's name). */
export declare const rolePicker: (id: string, action: string, options?: Common & {
    value?: Role;
    roles?: Role[];
}) => Block;
export declare const spinner: (options?: Common & {
    text?: string;
}) => Block;
/** `progress` 0…1; none: indeterminate. */
export declare const progress: (options?: Common & {
    progress?: number;
    title?: string;
    text?: string;
}) => Block;
/** Files and folders with Vektor's icons. Absolute paths; a folder ends in `/`. */
export declare const fileList: (files: string[], options?: Common) => Block;
/** A page of the plugin's own files (`entry`, inside the plugin folder). Inside a vertical scroll it takes `height`. */
export declare const web: (id: string, entry: string, options?: Common & {
    height?: number;
}) => Block;
/** Every block type this SDK knows (the reference's table). */
export declare const BLOCK_TYPES: ReadonlySet<string>;
export declare const MAX_BLOCKS = 100000;
export declare const MAX_DEPTH = 64;
/** What `width`, `minWidth` and `maxWidth` may be, in points. */
export declare const WIDTHS: {
    readonly min: 20;
    readonly max: 4000;
};
/**
 * What Vektor would refuse in a block tree (`blocks`: one block or a list), in plain words — empty when it would draw it.
 * `warnings` collects what Vektor would ignore (a colour value, an unknown role). The same rules as Vektor's: every block
 * has a `type`; ids are unique; items of a collection, inputs, sections, tabs, splits, nodes and web blocks have an id;
 * a button has an action or a menu; a picker has options, each with a value and a title; a menu has items, each with a title
 * and an action; a table has columns, each with an id and a title; a web block has an entry; tabs hold only tabs; at most
 * 100,000 blocks nested at most 64 deep. Like Vektor, it trims these strings: an empty or blank one counts as missing.
 */
export declare function validateBlocks(blocks: Block | Block[], existingIDs?: Iterable<string>): {
    problems: string[];
    warnings: string[];
};
export {};
