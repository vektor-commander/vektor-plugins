import type { Block, Control, MenuEntry, Role } from './blocks';
import type { JSONValue, PatchOperation, Tone, ViewClosedParams, ViewEventParams, ViewOpenedParams, ViewRefusedParams } from './messages';
import type { Plugin } from './plugin';
export interface Header {
    title?: string;
    primary?: {
        title: string;
        symbol?: string;
        action: string;
    };
    search?: boolean;
}
export interface BannerNote {
    text: string;
    tone?: Tone;
    symbol?: string;
    linkTitle?: string;
    link?: string;
}
export interface Toolbar {
    buttons?: {
        title: string;
        symbol?: string;
        action: string;
        enabled?: boolean;
    }[];
    search?: {
        placeholder?: string;
        action?: string;
    };
    message?: string;
}
export interface EmptyState {
    title: string;
    message?: string;
    symbol?: string;
    button?: {
        title: string;
        action: string;
    };
}
export interface Pill {
    label: string;
    tone?: Tone;
}
export interface CardListCard {
    id: string;
    symbol?: string;
    title: string;
    pill?: Pill;
    lines?: (string | {
        text: string;
        link?: string;
    })[];
    action?: string;
    buttons?: Control[];
    menu?: MenuEntry[];
}
export interface ListRow {
    id: string;
    title: string;
    subtitle?: string;
    symbol?: string;
    checkbox?: {
        checked: boolean;
        action: string;
    };
    badge?: Pill;
    edit?: string;
    action?: string;
    delete?: string;
    dimmed?: boolean;
    buttons?: Control[];
    menu?: MenuEntry[];
}
export interface ListGroup {
    id: string;
    title?: string;
    collapsible?: boolean;
    startsCollapsed?: boolean;
    rows: ListRow[];
}
export interface ListBody {
    input?: {
        placeholder?: string;
        action: string;
    };
    reorder?: string;
    groups: ListGroup[];
}
export interface FormField {
    key: string;
    kind: 'text' | 'toggle' | 'choice' | 'label' | 'button';
    label: string;
    value?: JSONValue;
    options?: {
        value: string;
        title: string;
    }[];
    help?: string;
    placeholder?: string;
    enabled?: boolean;
    action?: string;
}
export interface FormBody {
    buttons?: Control[];
    sections: {
        id: string;
        title?: string;
        description?: string;
        fields: FormField[];
    }[];
}
export interface DetailBody {
    heading?: {
        title: string;
        subtitle?: string;
        symbol?: string;
    };
    rows?: {
        label: string;
        value: string;
        link?: string;
    }[];
    markdown?: string;
    actions?: Control[];
}
/** A view's description. `revision` is filled in by `ViewState`. */
export interface ViewDescription {
    revision?: number;
    header?: Header;
    banner?: BannerNote;
    toolbar?: Toolbar;
    empty?: EmptyState;
    /** A block view (API 2): one block, or a list read as a vertical stack. */
    blocks?: Block | Block[];
    cards?: CardListCard[];
    list?: ListBody;
    form?: FormBody;
    detail?: DetailBody;
    [field: string]: unknown;
}
/** Two JSON values are the same, whatever the order of object keys. `undefined` fields count as absent. */
export declare function sameJSON(a: unknown, b: unknown): boolean;
/**
 * Applies patch operations to a block tree the way Vektor does: in order and all or nothing. Returns the new tree (the old
 * one is not changed) or throws a `PluginError` naming the operation that cannot apply.
 */
export declare function applyPatch(blocks: Block | Block[], ops: PatchOperation[]): Block | Block[];
/** At most this many operations in one `view/patch` (Vektor's protection limit). */
export declare const MAX_PATCH_OPERATIONS = 10000;
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
export declare function diffBlocks(before: Block | Block[], after: Block | Block[]): PatchOperation[] | null;
/** What an event handler receives: the `view/event` parameters, plus whether it was made against an older description. */
export type ViewEvent = ViewEventParams & {
    /** The event was made against an older revision than the one sent last: the user saw something that has changed since. */
    stale: boolean;
};
export interface ViewStateOptions {
    /** Send `view/patch` when a patch says it (block views only). Default true. */
    patches?: boolean;
    /** Check block trees before sending, the way Vektor does, and throw a `PluginError` for one it would refuse. Default true. */
    validate?: boolean;
    /**
     * After Vektor refused a **patch** (`view/refused`), send the whole description kept here again, numbered above anything sent,
     * as the reference asks — unless an `onRefused` handler already sent something. Default true. A refused whole description is
     * not sent again (it would be refused again): `onRefused` decides; the next `show` sends the whole description.
     */
    resendAfterRefusal?: boolean;
}
/** Which stale events a handler still receives. Default `'ignoreMoves'`: a move (`item`/`target`/`index`, or a list's
 *  `before`/`index`) against an older revision is dropped, because "put this at index 3" no longer means what the user saw;
 *  any other event is delivered with `stale: true`, so text typed in quick succession is never lost. */
export type StalePolicy = 'ignoreMoves' | 'ignore' | 'deliver';
type EventHandler = (event: ViewEvent) => unknown;
export declare class ViewState {
    private readonly plugin;
    readonly view: string;
    private readonly options;
    /** The revision of the description sent last (0: nothing sent yet). */
    revision: number;
    /** The description sent last (with its revision). */
    description?: ViewDescription;
    /** The sidebar item the view was opened for (API 2), while it is open. */
    item?: string;
    /** Whether Vektor shows the view now (between `view/opened` and `view/closed`). */
    isOpen: boolean;
    /** API 2: the last `view/refused` Vektor sent for this view, until it shows something sent after it. */
    refusal?: ViewRefusedParams;
    private readonly handlers;
    private fallback?;
    private openHandlers;
    private closeHandlers;
    private refusedHandlers;
    private needsWhole;
    /** The revision of the last whole description sent (0: none). */
    private wholeRevision;
    constructor(plugin: Plugin, view: string, options?: ViewStateOptions);
    /** Runs on `view/opened`: describe the view here (`show`). `item` is the sidebar item it was opened for. */
    onOpen(handler: (params: ViewOpenedParams) => unknown): this;
    onClose(handler: (params: ViewClosedParams) => unknown): this;
    /**
     * API 2: Vektor refused a description or a patch of this view (`view/refused`); `refusal.problem` says why in plain words.
     * When the handler runs, the next `show` already sends the whole description; after a refused patch the SDK resends the kept
     * description by itself if the handler sent nothing (`resendAfterRefusal`).
     */
    onRefused(handler: (refusal: ViewRefusedParams) => unknown): this;
    /** Routes `view/event`s with this `action` (the string your description carried) to `handler`. */
    on(action: string, handler: EventHandler, options?: {
        stale?: StalePolicy;
    }): this;
    /** Receives events whose action has no handler of its own. */
    onAnyEvent(handler: EventHandler, options?: {
        stale?: StalePolicy;
    }): this;
    /**
     * Shows `description`: as a patch when the previous one was a block view with the same header, banner, toolbar and empty
     * state and a patch can say the change; as the whole description otherwise. Returns what was sent (`'unchanged'`: nothing,
     * the view already shows exactly this).
     */
    show(description: ViewDescription): 'update' | 'patch' | 'unchanged';
    /** Sends the whole description (a new revision). */
    update(description: ViewDescription): void;
    /** Sends patch operations you built yourself, after applying them to the kept description (so they must apply). */
    patch(ops: PatchOperation[]): void;
    /** The next `show` sends the whole description (after Vektor may have lost it: the view was reopened). */
    invalidate(): void;
    private check;
    /** Called by the plugin for this view's `view/opened`, `view/closed` and `view/event`. */
    receive(method: string, params: any): Promise<void>;
    private refused;
    private dispatch;
}
export type { Role };
