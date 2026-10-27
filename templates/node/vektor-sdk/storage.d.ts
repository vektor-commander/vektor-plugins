import type { StorageEntry, StorageListResult, StorageStatusResult } from './messages';
import type { Plugin } from './plugin';
/** Bytes of content in one message (Vektor's limit). */
export declare const STORAGE_PART_BYTES: number;
/** The largest file the storage service reads or writes. */
export declare const STORAGE_FILE_BYTES: number;
/** A file read: its bytes (or text) and the version they are. */
export interface StoredFile<T> {
    value: T;
    version: string;
}
/** Someone else changed the file since you read it. You decide: merge (see `threeWayMerge`), ask your user, or overwrite. */
export declare class Conflict<T = unknown> {
    readonly path: string;
    /** What you tried to write. */
    readonly mine: T;
    /** The version your write was based on (`null`: you expected no file). */
    readonly baseVersion: string | null;
    /** What the place holds now, and its version — `null` when the file is gone. */
    readonly theirs: StoredFile<T> | null;
    constructor(path: string, 
    /** What you tried to write. */
    mine: T, 
    /** The version your write was based on (`null`: you expected no file). */
    baseVersion: string | null, 
    /** What the place holds now, and its version — `null` when the file is gone. */
    theirs: StoredFile<T> | null);
    /** The version to pass as `ifVersion` once you have merged (`null`: the file is gone, write as new). */
    get currentVersion(): string | null;
}
/** What `writeIfUnchanged` did: written (with the new version), or a conflict. */
export type WriteOutcome<T> = {
    written: true;
    version: string;
    conflict?: undefined;
} | {
    written: false;
    conflict: Conflict<T>;
    version?: undefined;
};
export declare class Storage {
    private readonly plugin;
    readonly place: string;
    constructor(plugin: Plugin, place: string);
    /** `available`, `offline`, `needsSignIn` or `missing`, and what the place promises. */
    status(): Promise<StorageStatusResult>;
    /** One page of a folder's entries; pass `next` back as `cursor` for the following page. */
    listPage(path?: string, options?: {
        cursor?: string;
        limit?: number;
    }): Promise<StorageListResult>;
    /** Every entry of a folder, following `next` until the last page (a page may hold fewer than `limit`, even none). */
    list(path?: string, options?: {
        limit?: number;
    }): Promise<StorageEntry[]>;
    /**
     * A whole file as bytes, read in parts when it is large; every part is checked to be of the same version, to start where
     * the previous one ended, and the whole to be the file's size — a file is never returned shorter than it is.
     */
    readBytes(path: string): Promise<StoredFile<Buffer>>;
    /** A whole file as UTF-8 text. */
    readText(path: string): Promise<StoredFile<string>>;
    /** A JSON document and its version, or `null` when there is no such file. */
    readJSON<T = unknown>(path: string): Promise<StoredFile<T> | null>;
    /**
     * Writes bytes or text, all at once (a reader never sees half a file), in parts when it is large. `ifVersion`: a version
     * means "only if the file is still this version", `null` "only if there is no file", `undefined` "whatever is there".
     * A refusal is a `VektorError` (`code: 'changed'` with `data.currentVersion` when the file changed). Returns the new version.
     */
    write(path: string, content: string | Uint8Array, ifVersion?: string | null): Promise<string>;
    /** Writes a JSON document (pretty-printed, so a person can read it). */
    writeJSON(path: string, value: unknown, ifVersion?: string | null): Promise<string>;
    /**
     * Writes `value` only if the file is still `baseVersion` (`null`: only if there is none). If someone changed it meanwhile,
     * nothing is written and you get a `Conflict` holding what you wanted to write and what is there now — merge, ask your
     * user, then write again with `conflict.currentVersion`.
     */
    writeIfUnchanged<T>(path: string, value: T, baseVersion: string | null): Promise<WriteOutcome<T>>;
    /** Deletes a file or folder. Answers whether it went to the Trash (`true`) or was deleted permanently (`false`). */
    delete(path: string, ifVersion?: string): Promise<boolean>;
    /** Creates one folder (its parent must exist). */
    createFolder(path: string): Promise<void>;
    /** Creates every missing folder of `path` ("a/b/c"), ignoring ones that exist. */
    createFolders(path: string): Promise<void>;
}
