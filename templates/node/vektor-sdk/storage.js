"use strict";
// The storage service (API 2) on one place the user chose: files read and written by Vektor through its own connections.
//
//     const storage = plugin.storage(plugin.settings.boards);         // a `place` setting's value
//     const doc = await storage.readJSON('board.json');              // { value, version } or null
//     const outcome = await storage.writeIfUnchanged('board.json', board, doc?.version ?? null);
//     if (outcome.conflict) { … outcome.conflict.theirs … }          // someone else wrote it meanwhile
//
// Large files go in parts automatically (512 KB per message, files up to 32 MB). Versions are opaque strings: compare them
// for equality only. Never store a place handle: use the latest one Vektor sent.
Object.defineProperty(exports, "__esModule", { value: true });
exports.Storage = exports.Conflict = exports.STORAGE_FILE_BYTES = exports.STORAGE_PART_BYTES = void 0;
const errors_1 = require("./errors");
/** Bytes of content in one message (Vektor's limit). */
exports.STORAGE_PART_BYTES = 512 * 1024;
/** The largest file the storage service reads or writes. */
exports.STORAGE_FILE_BYTES = 32 * 1024 * 1024;
/** Someone else changed the file since you read it. You decide: merge (see `threeWayMerge`), ask your user, or overwrite. */
class Conflict {
    path;
    mine;
    baseVersion;
    theirs;
    constructor(path, 
    /** What you tried to write. */
    mine, 
    /** The version your write was based on (`null`: you expected no file). */
    baseVersion, 
    /** What the place holds now, and its version — `null` when the file is gone. */
    theirs) {
        this.path = path;
        this.mine = mine;
        this.baseVersion = baseVersion;
        this.theirs = theirs;
    }
    /** The version to pass as `ifVersion` once you have merged (`null`: the file is gone, write as new). */
    get currentVersion() { return this.theirs ? this.theirs.version : null; }
}
exports.Conflict = Conflict;
class Storage {
    plugin;
    place;
    constructor(plugin, place) {
        this.plugin = plugin;
        this.place = place;
    }
    /** `available`, `offline`, `needsSignIn` or `missing`, and what the place promises. */
    status() {
        return this.plugin.request('storage/status', { place: this.place })
            .then((answer) => ({ ...answer, label: answer.label ?? '', remote: answer.remote ?? false, writes: answer.writes ?? '', conditional: answer.conditional ?? '' }));
    }
    /** One page of a folder's entries; pass `next` back as `cursor` for the following page. */
    listPage(path = '', options = {}) {
        const params = { place: this.place };
        if (path !== '')
            params.path = path;
        if (options.cursor !== undefined)
            params.cursor = options.cursor;
        if (options.limit !== undefined)
            params.limit = options.limit;
        return this.plugin.request('storage/list', params);
    }
    /** Every entry of a folder, following `next` until the last page (a page may hold fewer than `limit`, even none). */
    async list(path = '', options = {}) {
        const entries = [];
        let cursor;
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
    async readBytes(path) {
        const parts = [];
        let offset = 0;
        let version;
        const notWhole = () => new errors_1.PluginError(`“${path}” was not read whole.`, 'failed');
        for (;;) {
            const params = { place: this.place, path, offset, length: exports.STORAGE_PART_BYTES };
            if (version !== undefined)
                params.ifVersion = version;
            const part = await this.plugin.request('storage/read', params);
            if (part.offset !== offset)
                throw notWhole();
            const bytes = part.encoding === 'base64' ? Buffer.from(part.content, 'base64') : Buffer.from(part.content, 'utf8');
            parts.push(bytes);
            version ??= part.version;
            offset += bytes.length;
            if (part.eof) {
                if (offset !== part.size)
                    throw notWhole();
                break;
            }
            // An empty part before the end would never get further: ending here returned a truncated file as if it were whole.
            if (bytes.length === 0)
                throw notWhole();
        }
        return { value: Buffer.concat(parts), version: version };
    }
    /** A whole file as UTF-8 text. */
    async readText(path) {
        const file = await this.readBytes(path);
        return { value: file.value.toString('utf8'), version: file.version };
    }
    /** A JSON document and its version, or `null` when there is no such file. */
    async readJSON(path) {
        let file;
        try {
            file = await this.readText(path);
        }
        catch (error) {
            if (error instanceof errors_1.VektorError && error.code === 'notFound')
                return null;
            throw error;
        }
        try {
            return { value: JSON.parse(file.value), version: file.version };
        }
        catch {
            throw new errors_1.PluginError(`“${path}” is not a JSON document.`, 'badDocument');
        }
    }
    /**
     * Writes bytes or text, all at once (a reader never sees half a file), in parts when it is large. `ifVersion`: a version
     * means "only if the file is still this version", `null` "only if there is no file", `undefined` "whatever is there".
     * A refusal is a `VektorError` (`code: 'changed'` with `data.currentVersion` when the file changed). Returns the new version.
     */
    async write(path, content, ifVersion) {
        const bytes = typeof content === 'string' ? Buffer.from(content, 'utf8') : Buffer.from(content);
        if (bytes.length > exports.STORAGE_FILE_BYTES)
            throw new errors_1.PluginError(`“${path}” is larger than the storage service takes (32 MB).`, 'tooLarge');
        const base = { place: this.place, path };
        if (ifVersion !== undefined)
            base.ifVersion = ifVersion;
        if (bytes.length <= exports.STORAGE_PART_BYTES) {
            const params = typeof content === 'string' ? { ...base, content } : { ...base, content: bytes.toString('base64'), encoding: 'base64' };
            const result = await this.plugin.request('storage/write', params);
            return result.version;
        }
        // In parts: base64, so a part never splits a character. Only the last part writes.
        let upload;
        for (let offset = 0; offset < bytes.length; offset += exports.STORAGE_PART_BYTES) {
            const chunk = bytes.subarray(offset, Math.min(offset + exports.STORAGE_PART_BYTES, bytes.length));
            const more = offset + exports.STORAGE_PART_BYTES < bytes.length;
            const params = { ...base, content: chunk.toString('base64'), encoding: 'base64' };
            if (upload !== undefined)
                params.upload = upload;
            if (more)
                params.more = true;
            const result = await this.plugin.request('storage/write', params);
            if (more)
                upload = result.upload;
            else
                return result.version;
        }
        throw new errors_1.PluginError('The upload ended without its last part.');
    }
    /** Writes a JSON document (pretty-printed, so a person can read it). */
    writeJSON(path, value, ifVersion) {
        return this.write(path, `${JSON.stringify(value, null, 2)}\n`, ifVersion);
    }
    /**
     * Writes `value` only if the file is still `baseVersion` (`null`: only if there is none). If someone changed it meanwhile,
     * nothing is written and you get a `Conflict` holding what you wanted to write and what is there now — merge, ask your
     * user, then write again with `conflict.currentVersion`.
     */
    async writeIfUnchanged(path, value, baseVersion) {
        try {
            return { written: true, version: await this.writeJSON(path, value, baseVersion) };
        }
        catch (error) {
            if (!(error instanceof errors_1.VektorError) || error.code !== 'changed')
                throw error;
            const theirs = await this.readJSON(path);
            return { written: false, conflict: new Conflict(path, value, baseVersion, theirs) };
        }
    }
    /** Deletes a file or folder. Answers whether it went to the Trash (`true`) or was deleted permanently (`false`). */
    async delete(path, ifVersion) {
        const params = { place: this.place, path };
        if (ifVersion !== undefined)
            params.ifVersion = ifVersion;
        const result = await this.plugin.request('storage/delete', params);
        return result.trashed === true;
    }
    /** Creates one folder (its parent must exist). */
    async createFolder(path) {
        await this.plugin.request('storage/createFolder', { place: this.place, path });
    }
    /** Creates every missing folder of `path` ("a/b/c"), ignoring ones that exist. */
    async createFolders(path) {
        let sofar = '';
        for (const name of path.split('/').filter((part) => part !== '')) {
            sofar = sofar === '' ? name : `${sofar}/${name}`;
            try {
                await this.createFolder(sofar);
            }
            catch (error) {
                if (!(error instanceof errors_1.VektorError) || error.code !== 'exists')
                    throw error;
            }
        }
    }
}
exports.Storage = Storage;
