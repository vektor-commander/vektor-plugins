import type { InvokeTarget, SidebarItem, Workspace } from './messages';
import type { Plugin, RequestContext } from './plugin';
/** At most this many items under one entry (Vektor's protection limit). */
export declare const MAX_SIDEBAR_ITEMS = 2000;
export declare class SidebarItems {
    private readonly plugin;
    readonly entry: string;
    /** What was sent last. */
    items: SidebarItem[];
    private provider?;
    constructor(plugin: Plugin, entry: string);
    /** Sends the items, in this order (`[]` clears them). Checks what Vektor would refuse: ids and titles, no repeated id. */
    set(items: SidebarItem[]): void;
    /** Clears the entry's items. */
    clear(): void;
    /**
     * Where the items come from. They are sent at once if the plugin has started, and again after every workspace change
     * (Vektor keeps one list per workspace).
     */
    provide(provider: (workspace: Workspace | null) => SidebarItem[] | Promise<SidebarItem[]>): this;
    /** Asks the provider again and sends what it says (a provider changed its mind: a board was added). */
    refresh(): Promise<void>;
    /**
     * A command of a `sidebarItem` menu for this entry: the handler gets the item's id. (The manifest's menu with
     * `"target": "sidebarItem"` names the command; Vektor sends it as `invoke` with `target.entry` and `target.item`.)
     */
    onMenu(command: string, handler: (item: string, target: InvokeTarget, context: RequestContext) => unknown): this;
}
