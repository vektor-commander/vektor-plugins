import type { Workspace } from './messages';
import type { Plugin } from './plugin';
/** The key used when there is no active workspace. */
export declare const NO_WORKSPACE = "";
export declare class WorkspaceState<T> {
    private readonly plugin;
    readonly name: string;
    private readonly initial;
    private readonly folder?;
    private values;
    private loaded;
    /**
     * `name` becomes the file `<data folder>/<name>.workspaces.json`; `initial` is a workspace's value until one is saved
     * (copied, never shared between workspaces).
     */
    constructor(plugin: Plugin, name: string, initial: T, folder?: string | undefined);
    private get file();
    private load;
    private key;
    /** The value of `workspace` (default: the active one). Changes to it are kept in memory; `save()` writes them. */
    get(workspace?: Workspace | null): T;
    /** The active workspace's value. */
    get current(): T;
    set(value: T, workspace?: Workspace | null): void;
    /** Forgets a workspace's value (a workspace that was deleted). */
    forget(workspace: Workspace): void;
    /** Writes every workspace's value: to a temporary file, then renamed over the real one, so a crash never leaves half. */
    save(): void;
}
