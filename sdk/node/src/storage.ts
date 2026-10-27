// The storage service (API 2) on one place the user chose: files read and written by Vektor through its own connections.
//
//     const storage = plugin.storage(plugin.settings.boards);         // a `place` setting's value
//     const doc = await storage.readJSON('board.json');              // { value, version } or null
//     const outcome = await storage.writeIfUnchanged('board.json', board, doc?.version ?? null);
//     if (outcome.conflict) { … outcome.conflict.theirs … }          // someone else wrote it meanwhile
//
// Large files go in parts automatically (512 KB per message, files up to 32 MB). Versions are opaque strings: compare them
// for equality only. Never store a place handle: use the latest one Vektor sent.

import { PluginError, VektorError } from './errors';
import type {
  StorageDeleteResult, StorageEntry, StorageListResult, StorageReadResult, StorageStatusResult, StorageWriteParams,
} from './messages';
import type { Plugin } from './plugin';

/** Bytes of content in one message (Vektor's limit). */
export const STORAGE_PART_BYTES = 512 * 1024;
/** The largest file the storage service reads or writes. */
export const STORAGE_FILE_BYTES = 32 * 1024 * 1024;

/** A file read: its bytes (or text) and the version they are. */
export interface StoredFile<T> { value: T; version: string }

/** Someone else changed the file since you read it. You decide: merge (see `threeWayMerge`), ask your user, or overwrite. */
export class Conflict<T = unknown> {
  constructor(
    readonly path: string,
    /** What you tried to write. */
    readonly mine: T,
    /** The version your write was based on (`null`: you expected no file). */
    readonly baseVersion: string | null,
    /** What the place holds now, and its version — `null` when the file is gone. */
    readonly theirs: StoredFile<T> | null,
  ) {}
  /** The version to pass as `ifVersion` once you have merged (`null`: the file is gone, write as new). */
  get currentVersion(): string | null { return this.theirs ? this.theirs.version : null; }
}

/** What `writeIfUnchanged` did: written (with the new version), or a conflict. */
export type WriteOutcome<T> = { written: true; version: string; conflict?: undefined } | { written: false; conflict: Conflict<T>; version?: undefined };

export class Storage {
  constructor(private readonly plugin: Plugin, readonly place: string) {}

  /** `available`, `offline`, `needsSignIn` or `missing`, and what the place promises. */
  status(): Promise<StorageStatusResult> {
    return this.plugin.request('storage/status', { place: this.place })
      .then((answer: StorageStatusResult) => ({ ...answer, label: answer.label ?? '', remote: answer.remote ?? false, writes: answer.writes ?? '', conditional: answer.conditional ?? '' }));
  }

  /** One page of a folder's entries; pass `next` back as `cursor` for the following page. */
  listPage(path = '', options: { cursor?: string; limit?: number } = {}): Promise<StorageListResult> {
    const params: Record<string, unknown> = { place: this.place };
    if (path !== '') params.path = path;
    if (options.cursor !== undefined) params.cursor = options.cursor;
    if (options.limit !== undefined) params.limit = options.limit;
    return this.plugin.request('storage/list', params as any);
  }

  /** Every entry of a folder, following `next` until the last page (a page may hold fewer than `limit`, even none). */
  async list(path = '', options: { limit?: number } = {}): Promise<StorageEntry[]> {
    const entries: StorageEntry[] = [];
    let cursor: string | undefined;
    do {
      const page = await this.listPage(path, { cursor, limit: options.limit });
      entries.push(...(page.entries ?? []));
      cursor = page.next ?? undefined; // `null` ends the listing too; passed back as a cursor, it listed the first page forever
    } while (cursor !== undefined);
    return entries;
  }

  /**
   * A whole file as bytes, read in parts when it is large; every part is checked to be of the same version, to start where
   * the previous one ended, and the whole to be the file's size — a file is never returned shorter than it is.
   */
  async readBytes(path: string): Promise<StoredFile<Buffer>> {
    const parts: Buffer[] = [];
    let offset = 0;
    let version: string | undefined;
    const notWhole = () => new PluginError(`“${path}” was not read whole.`, 'failed');
    for (;;) {
      const params: Record<string, unknown> = { place: this.place, path, offset, length: STORAGE_PART_BYTES };
      if (version !== undefined) params.ifVersion = version;
      const part: StorageReadResult = await this.plugin.request('storage/read', params as any);
      if (part.offset !== offset) throw notWhole();
      const bytes = part.encoding === 'base64' ? Buffer.from(part.content, 'base64') : Buffer.from(part.content, 'utf8');
      parts.push(bytes);
      version ??= part.version;
      offset += bytes.length;
      if (part.eof) {
        if (offset !== part.size) throw notWhole();
        break;
      }
      // An empty part before the end would never get further: ending here returned a truncated file as if it were whole.
      if (bytes.length === 0) throw notWhole();
    }
    return { value: Buffer.concat(parts), version: version! };
  }

  /** A whole file as UTF-8 text. */
  async readText(path: string): Promise<StoredFile<string>> {
    const file = await this.readBytes(path);
    return { value: file.value.toString('utf8'), version: file.version };
  }

  /** A JSON document and its version, or `null` when there is no such file. */
  async readJSON<T = unknown>(path: string): Promise<StoredFile<T> | null> {
    let file: StoredFile<string>;
    try {
      file = await this.readText(path);
    } catch (error) {
      if (error instanceof VektorError && error.code === 'notFound') return null;
      throw error;
    }
    try {
      return { value: JSON.parse(file.value) as T, version: file.version };
    } catch {
      throw new PluginError(`“${path}” is not a JSON document.`, 'badDocument');
    }
  }

  /**
   * Writes bytes or text, all at once (a reader never sees half a file), in parts when it is large. `ifVersion`: a version
   * means "only if the file is still this version", `null` "only if there is no file", `undefined` "whatever is there".
   * A refusal is a `VektorError` (`code: 'changed'` with `data.currentVersion` when the file changed). Returns the new version.
   */
  async write(path: string, content: string | Uint8Array, ifVersion?: string | null): Promise<string> {
    const bytes = typeof content === 'string' ? Buffer.from(content, 'utf8') : Buffer.from(content);
    if (bytes.length > STORAGE_FILE_BYTES) throw new PluginError(`“${path}” is larger than the storage service takes (32 MB).`, 'tooLarge');
    const base: Record<string, unknown> = { place: this.place, path };
    if (ifVersion !== undefined) base.ifVersion = ifVersion;
    if (bytes.length <= STORAGE_PART_BYTES) {
      const params = typeof content === 'string' ? { ...base, content } : { ...base, content: bytes.toString('base64'), encoding: 'base64' };
      const result = await this.plugin.request('storage/write', params as unknown as StorageWriteParams);
      return result.version!;
    }
    // In parts: base64, so a part never splits a character. Only the last part writes.
    let upload: string | undefined;
    for (let offset = 0; offset < bytes.length; offset += STORAGE_PART_BYTES) {
      const chunk = bytes.subarray(offset, Math.min(offset + STORAGE_PART_BYTES, bytes.length));
      const more = offset + STORAGE_PART_BYTES < bytes.length;
      const params: Record<string, unknown> = { ...base, content: chunk.toString('base64'), encoding: 'base64' };
      if (upload !== undefined) params.upload = upload;
      if (more) params.more = true;
      const result = await this.plugin.request('storage/write', params as unknown as StorageWriteParams);
      if (more) upload = result.upload;
      else return result.version!;
    }
    throw new PluginError('The upload ended without its last part.');
  }

  /** Writes a JSON document (pretty-printed, so a person can read it). */
  writeJSON(path: string, value: unknown, ifVersion?: string | null): Promise<string> {
    return this.write(path, `${JSON.stringify(value, null, 2)}\n`, ifVersion);
  }

  /**
   * Writes `value` only if the file is still `baseVersion` (`null`: only if there is none). If someone changed it meanwhile,
   * nothing is written and you get a `Conflict` holding what you wanted to write and what is there now — merge, ask your
   * user, then write again with `conflict.currentVersion`.
   */
  async writeIfUnchanged<T>(path: string, value: T, baseVersion: string | null): Promise<WriteOutcome<T>> {
    try {
      return { written: true, version: await this.writeJSON(path, value, baseVersion) };
    } catch (error) {
      if (!(error instanceof VektorError) || error.code !== 'changed') throw error;
      const theirs = await this.readJSON<T>(path);
      return { written: false, conflict: new Conflict<T>(path, value, baseVersion, theirs) };
    }
  }

  /** Deletes a file or folder. Answers whether it went to the Trash (`true`) or was deleted permanently (`false`). */
  async delete(path: string, ifVersion?: string): Promise<boolean> {
    const params: Record<string, unknown> = { place: this.place, path };
    if (ifVersion !== undefined) params.ifVersion = ifVersion;
    const result: StorageDeleteResult = await this.plugin.request('storage/delete', params as any);
    return result.trashed === true;
  }

  /** Creates one folder (its parent must exist). */
  async createFolder(path: string): Promise<void> {
    await this.plugin.request('storage/createFolder', { place: this.place, path });
  }

  /** Creates every missing folder of `path` ("a/b/c"), ignoring ones that exist. */
  async createFolders(path: string): Promise<void> {
    let sofar = '';
    for (const name of path.split('/').filter((part) => part !== '')) {
      sofar = sofar === '' ? name : `${sofar}/${name}`;
      try {
        await this.createFolder(sofar);
      } catch (error) {
        if (!(error instanceof VektorError) || error.code !== 'exists') throw error;
      }
    }
  }
}
