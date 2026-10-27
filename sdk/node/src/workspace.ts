// Per-workspace state. `Plugin.workspace` is always the active workspace (from `startup`, `settingsChanged` and
// `workspace/changed`); `plugin.onWorkspaceChanged` runs on a switch. `WorkspaceState` keeps one value per workspace in the
// plugin's data folder, written atomically, so "the board this workspace had open" survives a restart.
//
//     const opened = new WorkspaceState(plugin, 'opened', { board: null });
//     opened.current.board = 'b1'; opened.save();

import * as fs from 'fs';
import * as path from 'path';
import type { Workspace } from './messages';
import type { Plugin } from './plugin';

/** The key used when there is no active workspace. */
export const NO_WORKSPACE = '';

export class WorkspaceState<T> {
  private values: Record<string, T> = {};
  private loaded = false;

  /**
   * `name` becomes the file `<data folder>/<name>.workspaces.json`; `initial` is a workspace's value until one is saved
   * (copied, never shared between workspaces).
   */
  constructor(private readonly plugin: Plugin, readonly name: string, private readonly initial: T, private readonly folder?: string) {
    if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error('A workspace state name is letters, digits, “.”, “-” and “_”.');
  }

  private get file(): string | undefined {
    const folder = this.folder ?? this.plugin.dataFolder;
    return folder ? path.join(folder, `${this.name}.workspaces.json`) : undefined;
  }

  private load(): void {
    if (this.loaded) return;
    this.loaded = true;
    const file = this.file;
    if (!file) return;
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (parsed && typeof parsed === 'object' && parsed.workspaces && typeof parsed.workspaces === 'object') this.values = parsed.workspaces;
    } catch {
      // No file yet, or one this version cannot read: start from the initial values.
    }
  }

  private key(workspace: Workspace | null | undefined): string {
    return workspace?.id ?? NO_WORKSPACE;
  }

  /** The value of `workspace` (default: the active one). Changes to it are kept in memory; `save()` writes them. */
  get(workspace: Workspace | null = this.plugin.workspace): T {
    this.load();
    const key = this.key(workspace);
    if (!(key in this.values)) this.values[key] = JSON.parse(JSON.stringify(this.initial));
    return this.values[key];
  }

  /** The active workspace's value. */
  get current(): T {
    return this.get();
  }

  set(value: T, workspace: Workspace | null = this.plugin.workspace): void {
    this.load();
    this.values[this.key(workspace)] = value;
    this.save();
  }

  /** Forgets a workspace's value (a workspace that was deleted). */
  forget(workspace: Workspace): void {
    this.load();
    delete this.values[this.key(workspace)];
    this.save();
  }

  /** Writes every workspace's value: to a temporary file, then renamed over the real one, so a crash never leaves half. */
  save(): void {
    const file = this.file;
    if (!file) return;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const temporary = `${file}.new`;
    fs.writeFileSync(temporary, `${JSON.stringify({ version: 1, workspaces: this.values }, null, 2)}\n`);
    fs.renameSync(temporary, file);
  }
}
