// Items under one of the plugin's sidebar entries (API 2): boards, projects. Vektor remembers them per workspace and draws
// them without starting the plugin; send them again when they change and after a workspace switch. With a provider set,
// the SDK does the second part for you: it asks the provider again on every workspace change.
//
//     plugin.sidebar('boards').provide((workspace) => boards.map((b) => ({ id: b.id, title: b.name, symbol: 'rectangle.split.3x1' })));
//     plugin.sidebar('boards').onMenu('rename', (item, target) => …);   // a `sidebarItem` menu's command

import { PluginError } from './errors';
import type { InvokeTarget, SidebarItem, Workspace } from './messages';
import type { Plugin, RequestContext } from './plugin';

/** At most this many items under one entry (Vektor's protection limit). */
export const MAX_SIDEBAR_ITEMS = 2000;

export class SidebarItems {
  /** What was sent last. */
  items: SidebarItem[] = [];
  private provider?: (workspace: Workspace | null) => SidebarItem[] | Promise<SidebarItem[]>;

  constructor(private readonly plugin: Plugin, readonly entry: string) {}

  /** Sends the items, in this order (`[]` clears them). Checks what Vektor would refuse: ids and titles, no repeated id. */
  set(items: SidebarItem[]): void {
    if (items.length > MAX_SIDEBAR_ITEMS) throw new PluginError(`A sidebar entry can list at most ${MAX_SIDEBAR_ITEMS} items.`);
    const seen = new Set<string>();
    for (const item of items) {
      if (!item || typeof item.id !== 'string' || item.id === '' || typeof item.title !== 'string' || item.title === '') {
        throw new PluginError('Every sidebar item needs an “id” and a “title”.');
      }
      if (seen.has(item.id)) throw new PluginError(`The sidebar item “${item.id}” is listed twice.`);
      seen.add(item.id);
    }
    this.items = items.map((item) => ({ ...item }));
    this.plugin.notify('sidebar/items', { entry: this.entry, items: this.items });
  }

  /** Clears the entry's items. */
  clear(): void {
    this.set([]);
  }

  /**
   * Where the items come from. They are sent at once if the plugin has started, and again after every workspace change
   * (Vektor keeps one list per workspace).
   */
  provide(provider: (workspace: Workspace | null) => SidebarItem[] | Promise<SidebarItem[]>): this {
    this.provider = provider;
    this.plugin.onReady(() => this.refresh());
    if (this.plugin.startupParams) void this.refresh().catch((error) => process.stderr.write(`vektor-sdk: sidebar items: ${error}\n`));
    return this;
  }

  /** Asks the provider again and sends what it says (a provider changed its mind: a board was added). */
  async refresh(): Promise<void> {
    if (this.provider) this.set(await this.provider(this.plugin.workspace));
  }

  /**
   * A command of a `sidebarItem` menu for this entry: the handler gets the item's id. (The manifest's menu with
   * `"target": "sidebarItem"` names the command; Vektor sends it as `invoke` with `target.entry` and `target.item`.)
   */
  onMenu(command: string, handler: (item: string, target: InvokeTarget, context: RequestContext) => unknown): this {
    this.plugin.command(command, (target, context) => {
      if (target.entry !== undefined && target.entry !== this.entry) {
        throw new PluginError(`“${command}” is not a command of the sidebar entry “${target.entry}”.`);
      }
      if (typeof target.item !== 'string') throw new PluginError(`“${command}” needs a sidebar item.`);
      return handler(target.item, target, context);
    });
    return this;
  }
}
