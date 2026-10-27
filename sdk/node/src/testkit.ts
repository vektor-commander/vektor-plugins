// The test kit: a Vektor stand-in that drives a plugin through `startup`, view events, storage calls and `shutdown`, from
// any test runner (node:test, Jest, Mocha) — with no Vektor and no window.
//
// It answers the way `vektor-plugin test` does: the same `startup` parameters (setting defaults from plugin.json under your
// settings), `{}` to the plugin's requests unless `autoReply` says otherwise, fake places (`{"$place": "boards"}` in the
// settings) backed by a temporary folder with the storage service's path rules, versions, refusal codes, pages and a
// stand-in Trash. `runScript` even plays a `test/checks.json`, so one script can run here and in `vektor-plugin test`.
//
// Two ways to run the plugin:
//   * in memory: `TestHost.start({ folder, setup })`, where `setup(plugin)` registers your handlers. Your run.js exports it:
//         function setup(plugin) { … return plugin; }
//         module.exports = { setup };
//         if (require.main === module) setup(new Plugin()).start();
//     Use `plugin.dataFolder` (not process.env) so the test's data folder is used.
//   * as a process: `TestHost.start({ folder, spawn: true })` starts the program the way Vektor does (the fixed PATH, the
//     minimal environment), for a plugin in any language.

import * as childProcess from 'child_process';
import * as crypto from 'crypto';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { validateBlocks } from './blocks';
import { encodeMessage, MessageReader } from './framing';
import { VEKTOR_NOTIFICATIONS, type JSONObject, type JSONValue, type ViewRefusedParams } from './messages';
import { Plugin } from './plugin';
import type { Transport } from './transport';

/** The PATH Vektor gives a plugin. */
export const PLUGIN_PATH = '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin';

/** A message as the test host sees it: `{kind, id?, method?, params?, result?, error?}` — the shape scripts match against. */
export interface Envelope {
  kind: 'request' | 'notification' | 'response' | 'failure';
  id?: number | string;
  method?: string;
  params?: any;
  result?: any;
  error?: any;
}

export interface Expectation {
  kind?: Envelope['kind'];
  method?: string;
  /** Paths (`params.description.blocks.children.0.title`) to a value, or a test: `{exists}`, `{contains}`, `{matches}`, `{count}`. */
  match?: Record<string, JSONValue>;
}

export interface TestHostOptions {
  /** The plugin folder (its plugin.json gives the setting defaults, the id and the program). */
  folder: string;
  /** In memory: registers the plugin's handlers on the SDK `Plugin` it is given. */
  setup?: (plugin: Plugin) => unknown;
  /** Start the folder's program as a process instead. */
  spawn?: boolean;
  /** Extra environment for a spawned program (e.g. a PATH for an interpreter elsewhere — Vektor would not find it). */
  environment?: Record<string, string>;
  settings?: JSONObject;
  workspace?: { id: string; name: string } | null;
  previousSessionEndedUncleanly?: boolean;
  /** Answers to the plugin's requests by method; `{"$error": "words"}` refuses. Default `{}`. */
  autoReply?: Record<string, JSONValue>;
  /** Keep the temporary folder (to look at what the plugin wrote). */
  keep?: boolean;
}

// --- Matching (the test host's language) ---------------------------------------------------------------------------------

export function valueAt(root: unknown, dotted: string): unknown {
  let current: any = root;
  for (const part of dotted.split('.').filter((piece) => piece !== '')) {
    if (Array.isArray(current)) {
      if (!/^\d+$/.test(part)) return undefined;
      current = current[Number(part)];
    } else if (current !== null && typeof current === 'object') {
      if (!Object.prototype.hasOwnProperty.call(current, part)) return undefined;
      current = current[part];
    } else {
      return undefined;
    }
    if (current === undefined) return undefined;
  }
  return current;
}

function sameValue(a: unknown, b: unknown): boolean {
  return JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
}
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical((value as any)[key])]));
  }
  return value;
}

function characters(text: string): number {
  const Segmenter = (Intl as any).Segmenter;
  return Segmenter ? [...new Segmenter('en', { granularity: 'grapheme' }).segment(text)].length : Array.from(text).length;
}

export function valueMatches(actual: unknown, expected: JSONValue): boolean {
  if (expected !== null && typeof expected === 'object' && !Array.isArray(expected) && Object.keys(expected).length === 1) {
    const [key, argument] = Object.entries(expected)[0];
    switch (key) {
      case 'exists': return (actual !== undefined) === (argument === null ? true : argument !== false);
      case 'contains':
        if (typeof actual === 'string') return typeof argument === 'string' && actual.includes(argument);
        if (Array.isArray(actual)) return actual.some((item) => sameValue(item, argument));
        return false;
      case 'matches':
        if (typeof actual !== 'string' || typeof argument !== 'string') return false;
        try { return new RegExp(argument).test(actual); } catch { return false; }
      case 'count':
        if (typeof argument !== 'number') return false;
        if (Array.isArray(actual)) return actual.length === argument;
        if (typeof actual === 'string') return characters(actual) === argument;
        if (actual !== null && typeof actual === 'object') return Object.keys(actual).length === argument;
        return false;
    }
  }
  return actual !== undefined && sameValue(actual, expected);
}

export function envelopeMatches(envelope: Envelope, expectation: Expectation, requestID?: number): boolean {
  if (expectation.kind && expectation.kind !== envelope.kind) return false;
  if (expectation.method && envelope.method !== expectation.method) return false;
  if ((expectation.kind === 'response' || expectation.kind === 'failure') && requestID !== undefined && envelope.id !== requestID) return false;
  for (const [dotted, expected] of Object.entries(expectation.match ?? {})) {
    if (!valueMatches(valueAt(envelope, dotted), expected)) return false;
  }
  return true;
}

export function describeExpectation(expectation: Expectation): string {
  const parts = [expectation.kind ?? 'message'];
  if (expectation.method) parts.push(expectation.method);
  const match = Object.entries(expectation.match ?? {});
  if (match.length > 0) parts.push('with ' + match.sort(([a], [b]) => (a < b ? -1 : 1)).map(([key, value]) => `${key} = ${JSON.stringify(value)}`).join(', '));
  return parts.join(' ');
}

// --- Fake places: the storage service on a temporary folder --------------------------------------------------------------

class StorageRefusal extends Error {
  constructor(readonly code: string, message: string, readonly data?: Record<string, unknown>) { super(message); }
}

const DISGUISED_SLASHES = ['\\', '∕', '⁄', '／', '⧸', '⧵', '﹨'];
const PART_BYTES = 512 * 1024;
const FILE_BYTES = 32 * 1024 * 1024;

function pathProblem(part: string): string | undefined {
  if (part === '') return 'it has an empty name (two “/” in a row, or one at the end).';
  if (part === '.' || part === '..') return '“.” and “..” are not names.';
  if (Buffer.byteLength(part, 'utf8') > 255) return 'a name is longer than 255 bytes.';
  if ([...part].some((c) => { const v = c.codePointAt(0)!; return v < 0x20 || v === 0x7f || (v >= 0x80 && v <= 0x9f); })) return 'a name contains a control character.';
  if (DISGUISED_SLASHES.some((slash) => part.includes(slash))) return 'a name contains a character that looks like a slash.';
  const folded = part.normalize('NFKC');
  if (folded === '.' || folded === '..' || folded.includes('/') || DISGUISED_SLASHES.some((slash) => folded.includes(slash))) {
    return 'a name reads as “.”, “..” or a slash once its characters are normalised.';
  }
  if (part.toLowerCase().startsWith('.vektor-') || folded.toLowerCase().startsWith('.vektor-')) return 'names starting with “.vektor-” are Vektor\'s own.';
  if (['.trash', '.trashes'].includes(part.toLowerCase()) || ['.trash', '.trashes'].includes(folded.toLowerCase())) return `“${part}” is the Trash's own folder.`;
  return undefined;
}

function parsePath(text: unknown, allowRoot: boolean): string[] {
  const raw = typeof text === 'string' ? text : '';
  const bad = (reason: string) => new StorageRefusal('badPath', `That path cannot be used: ${reason}`);
  if (raw === '' || raw === '.') {
    if (allowRoot) return [];
    throw bad('a file or folder name is needed.');
  }
  if (Buffer.byteLength(raw, 'utf8') > 1024) throw bad('it is longer than 1024 bytes.');
  if (raw.startsWith('/') || raw.startsWith('~')) throw bad('paths are relative to the place, so they cannot start with “/” or “~”.');
  const parts = raw.split('/');
  if (parts.length > 32) throw bad('it is more than 32 folders deep.');
  for (const part of parts) { const problem = pathProblem(part); if (problem) throw bad(problem); }
  return parts;
}

const listable = (name: string) => !name.toLowerCase().startsWith('.vektor-') && !['.trash', '.trashes'].includes(name.toLowerCase());

/** The storage service of the test host, on folders under a temporary folder. */
export class TestPlaces {
  private readonly places = new Map<string, { name: string; folder: string }>();
  private readonly uploads = new Map<string, { place: string; path: string; bytes: Buffer }>();
  private readonly cursors = new Map<string, { place: string; path: string; names: string[]; offset: number; created: number }>();
  readonly trash: string;

  constructor(readonly work: string) {
    this.trash = path.join(work, 'trash');
  }

  /** Replaces each `{"$place": name}` setting with a handle; answers `place.<name>` variables (the folders). */
  substitute(settings: JSONObject): { settings: JSONObject; variables: Record<string, string> } {
    const result: JSONObject = { ...settings };
    const variables: Record<string, string> = {};
    for (const [key, value] of Object.entries(settings)) {
      if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 1) continue;
      const name = (value as JSONObject).$place;
      if (typeof name !== 'string' || name === '' || name.includes('/') || name === '.' || name === '..') continue;
      const folder = path.join(this.work, 'places', name);
      fs.mkdirSync(folder, { recursive: true });
      const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
      const token = 'pl-' + [...crypto.randomBytes(26)].map((byte) => alphabet[byte % 32]).join('');
      this.places.set(token, { name, folder: fs.realpathSync(folder) });
      result[key] = { place: token, label: `Test place ▸ ${name}`, remote: false };
      variables[`place.${name}`] = folder;
    }
    return { settings: result, variables };
  }

  static isStorageMethod(method: string): boolean {
    return method.startsWith('storage/');
  }

  /** The answer to one storage request: a result, or an error object with message, code and data. */
  answer(method: string, params: any): { result?: JSONValue; error?: JSONObject } {
    try {
      return { result: this.respond(method, params ?? {}) };
    } catch (error) {
      if (error instanceof StorageRefusal) {
        const body: JSONObject = { message: error.message, code: error.code };
        if (error.data) body.data = error.data as JSONObject;
        return { error: body };
      }
      return { error: { message: String((error as Error).message ?? error), code: 'failed' } };
    }
  }

  private version(file: string): string {
    const info = fs.lstatSync(file, { bigint: true });
    return `v1.l.${info.dev}.${info.ino}.${info.mtimeNs ?? info.mtimeMs}.${info.size}`;
  }

  private respond(method: string, params: any): JSONValue {
    const known = ['storage/status', 'storage/list', 'storage/read', 'storage/write', 'storage/delete', 'storage/createFolder'];
    if (!known.includes(method)) throw new StorageRefusal('badRequest', `The request cannot be used: Vektor does not offer “${method}”.`);
    const place = this.places.get(params.place);
    if (!place) throw new StorageRefusal('badPlace', 'That place is not one Vektor gave this plugin. Use the value of the place setting as it was sent.', { state: 'missing' });
    const label = `Test place ▸ ${place.name}`;
    if (!fs.existsSync(place.folder)) throw new StorageRefusal('missing', `The folder “${label}” no longer exists.`, { state: 'missing' });
    const shown = (parts: string[]) => (parts.length === 0 ? '/' : parts.join('/'));
    const parentOf = (parts: string[]): string => {
      if (parts.length <= 1) return place.folder;
      const joined = path.join(place.folder, ...parts.slice(0, -1));
      let real: string;
      try { real = fs.realpathSync(joined); } catch { throw new StorageRefusal('notFound', `“${shown(parts.slice(0, -1))}” does not exist.`); }
      if (real !== place.folder && !real.startsWith(place.folder + '/')) throw new StorageRefusal('badPath', `“${shown(parts)}” leads outside the place, so Vektor refused it.`);
      if (!fs.statSync(real).isDirectory()) throw new StorageRefusal('wrongKind', `“${shown(parts.slice(0, -1))}” is not a folder.`);
      return real;
    };
    // As Vektor: a version must look like one it gives (`v1.` …); `null` ("only if nothing is there") only for a write. Vektor
    // checks this while parsing the request, so a malformed one is badRequest before the file is looked at.
    const condition = (params: any): { kind: 'any' } | { kind: 'absent' } | { kind: 'version'; version: string } => {
      if (!('ifVersion' in params) || params.ifVersion === undefined) return { kind: 'any' };
      if (params.ifVersion === null) {
        if (method === 'storage/write') return { kind: 'absent' };
        throw new StorageRefusal('badRequest', 'The request cannot be used: “ifVersion” must be a version here.');
      }
      const version = params.ifVersion;
      if (typeof version !== 'string' || !version.startsWith('v1.') || version.length > 200 || !/^[A-Za-z0-9.-]+$/.test(version)) {
        throw new StorageRefusal('badRequest', 'The request cannot be used: “ifVersion” must be a version Vektor gave, or null.');
      }
      return { kind: 'version', version };
    };
    const current = (file: string): string | undefined => {
      try { return fs.lstatSync(file).isFile() ? this.version(file) : undefined; } catch { return undefined; }
    };
    const changed = (parts: string[], now: string | undefined) =>
      new StorageRefusal('changed', `“${shown(parts)}” changed since you read it.`, now === undefined ? undefined : { currentVersion: now });

    switch (method) {
      case 'storage/status':
        return { state: 'available', label, remote: false, writes: 'atomic', conditional: 'checked' };
      case 'storage/list': {
        const parts = parsePath(params.path, true);
        let limit = 1000;
        if (params.limit !== undefined && params.limit !== null) {
          if (!Number.isInteger(params.limit) || params.limit < 1 || params.limit > 5000) {
            throw new StorageRefusal('badRequest', 'The request cannot be used: “limit” must be a whole number from 1 to 5000.');
          }
          limit = params.limit;
        }
        const folder = parts.length === 0 ? place.folder : path.join(parentOf(parts), parts[parts.length - 1]);
        let listing: { place: string; path: string; names: string[]; offset: number; created: number };
        if (params.cursor !== undefined && params.cursor !== null) {
          const held = this.cursors.get(String(params.cursor));
          if (!held) throw new StorageRefusal('badCursor', 'That cursor cannot be used: it has expired, or Vektor did not give it. List the folder again from the start.');
          if (held.place !== params.place || held.path !== shown(parts)) {
            throw new StorageRefusal('badCursor', 'That cursor cannot be used: it was given for another folder, place or plugin. List this folder again from the start.');
          }
          if (Date.now() - held.created > 10 * 60 * 1000) {
            this.cursors.delete(String(params.cursor));
            throw new StorageRefusal('badCursor', 'That cursor cannot be used: it has expired, or Vektor did not give it. List the folder again from the start.');
          }
          listing = held;
        } else {
          let info;
          try { info = fs.statSync(folder); } catch { throw new StorageRefusal('notFound', `“${shown(parts)}” does not exist.`); }
          if (!info.isDirectory()) throw new StorageRefusal('wrongKind', `“${shown(parts)}” is not a folder.`);
          const names = fs.readdirSync(folder).filter((name) => listable(name) && !pathProblem(name)).sort();
          listing = { place: params.place, path: shown(parts), names, offset: 0, created: Date.now() };
        }
        const entries: JSONValue[] = [];
        let offset = listing.offset;
        while (offset < listing.names.length && entries.length < limit) {
          const name = listing.names[offset++];
          const full = path.join(folder, name);
          let info;
          try { info = fs.lstatSync(full); } catch { continue; } // removed meanwhile
          if (info.isSymbolicLink()) {
            let real: string;
            try { real = fs.realpathSync(full); info = fs.statSync(full); } catch { continue; }
            if (real !== place.folder && !real.startsWith(place.folder + '/')) continue;
          }
          if (info.isDirectory()) entries.push({ name, isFolder: true, modified: info.mtime.toISOString() });
          else if (info.isFile()) entries.push({ name, isFolder: false, size: Number(info.size), modified: info.mtime.toISOString(), version: this.version(full) });
        }
        const result: JSONObject = { entries };
        if (offset < listing.names.length) {
          const cursor = 'cu-' + crypto.randomBytes(12).toString('hex');
          this.cursors.set(cursor, { ...listing, offset });
          result.next = cursor;
        }
        return result;
      }
      case 'storage/read': {
        const parts = parsePath(params.path, false);
        const wanted = condition(params);
        const file = path.join(parentOf(parts), parts[parts.length - 1]);
        let info;
        try { info = fs.statSync(file); } catch { throw new StorageRefusal('notFound', `“${shown(parts)}” does not exist.`); }
        if (!info.isFile()) throw new StorageRefusal('wrongKind', `“${shown(parts)}” is a folder, not a file.`);
        const version = this.version(file);
        if (wanted.kind === 'version' && wanted.version !== version) throw changed(parts, version);
        const size = Number(info.size);
        const offset = Number.isInteger(params.offset) && params.offset >= 0 ? params.offset : 0;
        const length = Number.isInteger(params.length) && params.length >= 0 ? Math.min(params.length, PART_BYTES) : PART_BYTES;
        const bytes = Buffer.alloc(Math.max(0, Math.min(length, size - offset)));
        if (bytes.length > 0) {
          const fd = fs.openSync(file, 'r');
          try { fs.readSync(fd, bytes, 0, bytes.length, offset); } finally { fs.closeSync(fd); }
        }
        const answer: JSONObject = { version, size, offset, eof: offset + bytes.length >= size };
        const text = bytes.toString('utf8');
        if (params.encoding !== 'base64' && Buffer.from(text, 'utf8').equals(bytes)) { answer.content = text; answer.encoding = 'text'; }
        else { answer.content = bytes.toString('base64'); answer.encoding = 'base64'; }
        return answer;
      }
      case 'storage/write': {
        const parts = parsePath(params.path, false);
        const wanted = condition(params); // on every part: only the last one is checked against the file
        if (typeof params.content !== 'string') throw new StorageRefusal('badRequest', 'The content cannot be used: “content” must be text (or base64 with “encoding”: “base64”).');
        let bytes: Buffer;
        if (params.encoding === undefined || params.encoding === 'text') bytes = Buffer.from(params.content, 'utf8');
        else if (params.encoding === 'base64') bytes = Buffer.from(params.content, 'base64');
        else throw new StorageRefusal('badRequest', 'The content cannot be used: “encoding” must be “text” or “base64”.');
        if (bytes.length > PART_BYTES) throw new StorageRefusal('tooLarge', `That is larger than Vektor allows here (${PART_BYTES / 1024} KB).`);
        const parent = parentOf(parts);
        const file = path.join(parent, parts[parts.length - 1]);
        let whole = bytes;
        if (params.upload !== undefined) {
          const staged = this.uploads.get(String(params.upload));
          if (!staged || staged.place !== params.place || staged.path !== shown(parts)) {
            throw new StorageRefusal('badRequest', 'That upload is not one Vektor started for this plugin, or it was abandoned.');
          }
          whole = Buffer.concat([staged.bytes, bytes]);
          if (whole.length > FILE_BYTES) throw new StorageRefusal('tooLarge', `That is larger than Vektor allows here (${FILE_BYTES / 1024} KB).`);
        }
        if (params.more === true) {
          const id = params.upload ?? 'up-' + crypto.randomBytes(12).toString('hex');
          this.uploads.set(id, { place: params.place, path: shown(parts), bytes: whole });
          return { upload: id };
        }
        if (params.upload !== undefined) this.uploads.delete(String(params.upload));
        const now = current(file);
        try { if (fs.lstatSync(file).isDirectory()) throw new StorageRefusal('wrongKind', `“${shown(parts)}” is a folder, not a file.`); } catch (error) { if (error instanceof StorageRefusal) throw error; }
        if (wanted.kind === 'absent' && fs.existsSync(file)) throw changed(parts, now);
        if (wanted.kind === 'version' && now !== wanted.version) throw changed(parts, now);
        const staged = path.join(parent, `.vektor-storage-${crypto.randomBytes(8).toString('hex')}`);
        fs.writeFileSync(staged, whole);
        fs.renameSync(staged, file);
        return { version: this.version(file) };
      }
      case 'storage/delete': {
        const parts = parsePath(params.path, false);
        const wanted = condition(params);
        const file = path.join(parentOf(parts), parts[parts.length - 1]);
        let info;
        try { info = fs.lstatSync(file); } catch { throw new StorageRefusal('notFound', `“${shown(parts)}” does not exist.`); }
        if (wanted.kind === 'version') {
          if (!info.isFile()) throw new StorageRefusal('wrongKind', `“${shown(parts)}” is a folder, not a file.`);
          const now = this.version(file);
          if (now !== wanted.version) throw changed(parts, now);
        }
        fs.mkdirSync(this.trash, { recursive: true });
        fs.renameSync(file, path.join(this.trash, `${Date.now()}-${crypto.randomBytes(4).toString('hex')}-${parts[parts.length - 1]}`));
        return { trashed: true };
      }
      case 'storage/createFolder': {
        const parts = parsePath(params.path, false);
        const folder = path.join(parentOf(parts), parts[parts.length - 1]);
        if (fs.existsSync(folder)) throw new StorageRefusal('exists', `“${shown(parts)}” already exists.`);
        fs.mkdirSync(folder);
        return {};
      }
    }
    return {};
  }
}

// --- The host ------------------------------------------------------------------------------------------------------------

/** An in-memory pipe between the test host and a plugin in the same process. */
function memoryPair(): { pluginSide: Transport; deliverToPlugin: (bytes: Buffer) => void; endInput: () => void; onPluginBytes: (fn: (bytes: Buffer) => void) => void; onExit: (fn: (code: number) => void) => void } {
  let toHost: (bytes: Buffer) => void = () => {};
  let exited: (code: number) => void = () => {};
  const dataListeners: ((chunk: Buffer) => void)[] = [];
  const endListeners: (() => void)[] = [];
  let gone = false;
  return {
    pluginSide: {
      write: (bytes) => { if (!gone) setImmediate(() => toHost(bytes)); },
      onData: (listener) => { dataListeners.push(listener); },
      onEnd: (listener) => { endListeners.push(listener); },
      exit: (code) => { if (gone) return; gone = true; setImmediate(() => exited(code)); },
    },
    deliverToPlugin: (bytes) => { if (!gone) setImmediate(() => dataListeners.forEach((listener) => listener(bytes))); },
    endInput: () => setImmediate(() => endListeners.forEach((listener) => listener())),
    onPluginBytes: (fn) => { toHost = fn; },
    onExit: (fn) => { exited = fn; },
  };
}

function readManifest(folder: string): any {
  try {
    return JSON.parse(fs.readFileSync(path.join(folder, 'plugin.json'), 'utf8'));
  } catch (error) {
    throw new Error(`The plugin folder “${folder}” has no readable plugin.json: ${(error as Error).message}`);
  }
}

export class TestHost {
  /** Every message the plugin sent, in order. */
  readonly received: Envelope[] = [];
  /** A readable record of the conversation (→ to the plugin, ← from it, ! a problem). */
  readonly transcript: string[] = [];
  /** The folders behind fake places, by name (`${place.<name>}`). */
  readonly variables: Record<string, string> = {};
  /** The plugin object, in memory mode. */
  plugin?: Plugin;
  /** The exit status once the plugin left. */
  exitCode?: number;
  readonly work: string;
  readonly dataFolder: string;
  readonly sessionFolder: string;
  readonly places: TestPlaces;
  readonly manifest: any;

  private nextID = 1;
  private readonly waiters = new Set<() => void>();
  private writeToPlugin: (bytes: Buffer) => void = () => {};
  private closeInput: () => void = () => {};
  private child?: childProcess.ChildProcess;
  private settings: JSONObject;

  private constructor(private readonly options: TestHostOptions) {
    this.manifest = readManifest(options.folder);
    this.work = fs.mkdtempSync(path.join(os.tmpdir(), 'vektor-plugin-test-'));
    this.dataFolder = path.join(this.work, 'data');
    this.sessionFolder = path.join(this.work, 'session');
    fs.mkdirSync(this.dataFolder, { recursive: true });
    fs.mkdirSync(this.sessionFolder, { recursive: true });
    this.places = new TestPlaces(this.work);
    const defaults: JSONObject = {};
    for (const item of this.manifest.settings?.items ?? []) if (item && item.default !== undefined) defaults[item.key] = item.default;
    const substituted = this.places.substitute({ ...defaults, ...(options.settings ?? {}) });
    this.settings = substituted.settings;
    Object.assign(this.variables, { folder: options.folder, data: this.dataFolder, session: this.sessionFolder }, substituted.variables);
  }

  /** Starts the plugin (in memory with `setup`, or as a process with `spawn`). Does not send `startup`: call `startup()`. */
  static async start(options: TestHostOptions): Promise<TestHost> {
    const host = new TestHost(options);
    if (options.spawn || !options.setup) host.spawnProcess();
    else host.startInMemory(options.setup);
    return host;
  }

  private startInMemory(setup: (plugin: Plugin) => unknown): void {
    const pair = memoryPair();
    const reader = new MessageReader();
    pair.onPluginBytes((bytes) => this.fromPlugin(reader, bytes));
    pair.onExit((code) => { this.exitCode = code; this.log(`! the plugin exited (status ${code})`); this.wake(); });
    this.writeToPlugin = pair.deliverToPlugin;
    this.closeInput = pair.endInput;
    const plugin = new Plugin({ transport: pair.pluginSide, api: this.manifest.api, diagnostics: (text) => this.log(`stderr: ${text}`) });
    this.plugin = plugin;
    setup(plugin);
    plugin.start();
  }

  private spawnProcess(): void {
    const executable = path.join(this.options.folder, String(this.manifest.executable ?? ''));
    const child = childProcess.spawn(executable, (this.manifest.arguments ?? []).map(String), {
      cwd: this.options.folder,
      env: {
        PATH: PLUGIN_PATH, HOME: os.homedir(), TMPDIR: this.sessionFolder + '/', LANG: 'en_US.UTF-8',
        VEKTOR_PLUGIN_ID: String(this.manifest.id), VEKTOR_PLUGIN_DATA: this.dataFolder, VEKTOR_PLUGIN_SESSION: this.sessionFolder,
        VEKTOR_PLUGIN_API: String(this.manifest.api ?? 1),
        ...(this.options.environment ?? {}),
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child = child;
    const reader = new MessageReader();
    child.stdout.on('data', (bytes) => this.fromPlugin(reader, bytes));
    child.stderr.on('data', (bytes) => { for (const line of bytes.toString('utf8').split('\n')) if (line) this.log(`stderr: ${line}`); });
    child.on('exit', (code) => { this.exitCode = code ?? -1; this.log(`! the plugin exited (status ${this.exitCode})`); this.wake(); });
    child.on('error', (error) => { this.exitCode = -1; this.log(`! the plugin could not start: ${error.message}`); this.wake(); });
    child.stdin.on('error', () => {});
    this.writeToPlugin = (bytes) => { if (this.exitCode === undefined) child.stdin.write(bytes); };
    this.closeInput = () => child.stdin.end();
  }

  private log(line: string): void {
    this.transcript.push(line);
  }

  private wake(): void {
    for (const waiter of [...this.waiters]) waiter();
  }

  private fromPlugin(reader: MessageReader, bytes: Buffer): void {
    let messages: any[];
    try {
      messages = reader.push(bytes) as any[];
    } catch (error) {
      this.log(`! the plugin sent something Vektor would refuse: ${(error as Error).message}`);
      return;
    }
    for (const message of messages) {
      if (typeof message.api !== 'number') this.log('! a message without “api”, which Vektor refuses');
      let envelope: Envelope;
      if (typeof message.method === 'string') {
        envelope = message.id !== undefined
          ? { kind: 'request', id: message.id, method: message.method, params: message.params ?? {} }
          : { kind: 'notification', method: message.method, params: message.params ?? {} };
      } else if (message.error !== undefined) {
        envelope = { kind: 'failure', id: message.id, error: message.error };
      } else {
        envelope = { kind: 'response', id: message.id, result: message.result ?? {} };
      }
      this.received.push(envelope);
      this.log(`← ${JSON.stringify(envelope)}`);
      if (envelope.kind === 'notification' && (envelope.method === 'view/update' || envelope.method === 'view/patch')) this.checkView(envelope);
      if (envelope.kind === 'request') this.answer(envelope);
    }
    this.wake();
  }

  /** A block description is checked the way Vektor checks it; what it would refuse goes into the transcript. */
  private checkView(envelope: Envelope): void {
    const params = envelope.params ?? {};
    const declared = (this.manifest.contributes?.views ?? []).some((view: any) => view && view.id === params.view);
    if (!declared) this.log(`! “${envelope.method}” names the view “${params.view}”, which the manifest does not declare.`);
    const blocks = envelope.method === 'view/update' ? params.description?.blocks : undefined;
    if (blocks !== undefined) for (const problem of validateBlocks(blocks).problems) this.log(`! ${problem}`);
  }

  private answer(request: Envelope): void {
    const autoReply = this.options.autoReply ?? {};
    const method = request.method!;
    let reply: Record<string, unknown>;
    if (TestPlaces.isStorageMethod(method) && autoReply[method] === undefined) {
      const answer = this.places.answer(method, request.params);
      reply = answer.error ? { id: request.id, error: answer.error } : { id: request.id, result: answer.result };
    } else {
      const scripted = autoReply[method];
      if (scripted && typeof scripted === 'object' && !Array.isArray(scripted) && typeof (scripted as JSONObject).$error === 'string') {
        reply = { id: request.id, error: { message: (scripted as JSONObject).$error } };
      } else {
        reply = { id: request.id, result: scripted ?? {} };
      }
    }
    this.log(`→ ${JSON.stringify(reply)}`);
    this.writeToPlugin(encodeMessage({ api: this.manifest.api ?? 1, ...reply }));
  }

  /** `startup`'s parameters, as Vektor (and `vektor-plugin test`) sends them. */
  startupParams(): JSONObject {
    return {
      vektorVersion: '1.0.0',
      pluginID: String(this.manifest.id),
      previousSessionEndedUncleanly: this.options.previousSessionEndedUncleanly ?? false,
      sessionTemporaryFolder: this.sessionFolder,
      dataFolder: this.dataFolder,
      settings: this.settings,
      workspace: (this.options.workspace ?? null) as JSONValue,
    };
  }

  /** Sends a message: a request (answers its id) unless the method is one Vektor sends as a notification. */
  send(method: string, params: JSONValue = {}, kind?: 'request' | 'notification'): number | undefined {
    const isNotification = (kind ?? (VEKTOR_NOTIFICATIONS.has(method) ? 'notification' : 'request')) === 'notification';
    const message: Record<string, unknown> = { api: this.manifest.api ?? 1, method, params };
    let id: number | undefined;
    if (!isNotification) {
      id = this.nextID++;
      message.id = id;
    }
    this.log(`→ ${JSON.stringify(message)}`);
    this.writeToPlugin(encodeMessage(message));
    return id;
  }

  /** Waits until a message received after `since` satisfies `test`. */
  private async waitUntil(test: (envelope: Envelope) => boolean, since: number, timeout: number, what: () => string): Promise<Envelope> {
    const deadline = Date.now() + timeout * 1000;
    for (;;) {
      const found = this.received.slice(since).find(test);
      if (found) return found;
      if (this.exitCode !== undefined) throw new Error(`${what()} (the plugin had exited, status ${this.exitCode})\n${this.transcript.join('\n')}`);
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`${what()}\n${this.transcript.join('\n')}`);
      await new Promise<void>((resolve) => {
        const done = () => { this.waiters.delete(done); clearTimeout(timer); resolve(); };
        const timer = setTimeout(done, Math.min(left, 50));
        this.waiters.add(done);
      });
    }
  }

  /** Waits for a message the plugin sends after `since` (an index into `received`) that fits `expectation`. */
  waitFor(expectation: Expectation, options: { since?: number; requestID?: number; timeout?: number } = {}): Promise<Envelope> {
    return this.waitUntil(
      (envelope) => envelopeMatches(envelope, expectation, options.requestID),
      options.since ?? 0, options.timeout ?? 5, () => `did not receive ${describeExpectation(expectation)}`,
    );
  }

  /** Sends a request and waits for its answer (a response or a failure). */
  request(method: string, params: JSONValue = {}, timeout = 5): Promise<Envelope> {
    const since = this.received.length;
    const id = this.send(method, params, 'request')!;
    return this.waitUntil(
      (envelope) => (envelope.kind === 'response' || envelope.kind === 'failure') && envelope.id === id,
      since, timeout, () => `no answer to “${method}”`,
    );
  }

  /** Sends `startup` and waits for its answer. */
  startup(): Promise<Envelope> {
    return this.request('startup', this.startupParams());
  }

  /** Sends `view/opened`. */
  openView(view: string, item?: string): void {
    this.send('view/opened', item === undefined ? { view } : { view, item });
  }

  /** Sends a `view/event`; `revision` defaults to the last one the plugin sent for that view. */
  viewEvent(view: string, action: string, fields: JSONObject = {}): void {
    const revision = this.lastRevision(view);
    this.send('view/event', { view, action, ...(revision !== undefined ? { revision } : {}), ...fields });
  }

  /** Sends `web/message` as a page would. */
  webMessage(view: string, message: JSONValue, block?: string): void {
    this.send('web/message', block === undefined ? { view, message } : { view, block, message });
  }

  /**
   * Simulates Vektor refusing what the plugin sent last for `view` (`view/refused`, plugin API 2). `kind` defaults to whichever
   * the plugin sent last (`description` for a `view/update`, `patch` for a `view/patch`), `refusedRevision` to its revision, and
   * `revision` — what Vektor still shows — to the revision the plugin sent before it (`null` when there was none). `viewEvent`
   * keeps defaulting to the plugin's last revision: pass `revision` to make an event against the one Vektor still shows.
   */
  refuse(view: string, options: { problem?: string; kind?: 'description' | 'patch'; revision?: number | null; refusedRevision?: number } = {}): ViewRefusedParams {
    const sent: { method: string; revision?: number }[] = [];
    for (const envelope of this.received) {
      if (envelope.kind !== 'notification' || envelope.params?.view !== view) continue;
      if (envelope.method === 'view/update') sent.push({ method: 'view/update', revision: envelope.params.description?.revision });
      if (envelope.method === 'view/patch') sent.push({ method: 'view/patch', revision: envelope.params.revision });
    }
    const last = sent.at(-1);
    const refusal: ViewRefusedParams = {
      view,
      kind: options.kind ?? (last?.method === 'view/patch' ? 'patch' : 'description'),
      revision: options.revision !== undefined ? options.revision : (sent.length >= 2 ? sent[sent.length - 2].revision ?? null : null),
      problem: options.problem ?? 'Vektor could not show it.',
    };
    const refused = options.refusedRevision ?? last?.revision;
    if (refused !== undefined) refusal.refusedRevision = refused;
    this.send('view/refused', refusal as unknown as JSONValue);
    return refusal;
  }

  /** The revision of the description the plugin sent last for `view` (`view/update` or `view/patch`). */
  lastRevision(view: string): number | undefined {
    for (let index = this.received.length - 1; index >= 0; index--) {
      const envelope = this.received[index];
      if (envelope.kind !== 'notification' || envelope.params?.view !== view) continue;
      if (envelope.method === 'view/update') return envelope.params.description?.revision;
      if (envelope.method === 'view/patch') return envelope.params.revision;
    }
    return undefined;
  }

  /** Every notification of `method` received so far. */
  notifications(method: string): Envelope[] {
    return this.received.filter((envelope) => envelope.kind === 'notification' && envelope.method === method);
  }

  /** Waits for the plugin to leave by itself; true when it did. */
  async waitForExit(timeout = 5): Promise<boolean> {
    const deadline = Date.now() + timeout * 1000;
    while (this.exitCode === undefined && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 15));
    return this.exitCode !== undefined;
  }

  /** Sends `shutdown`, expects its answer and the plugin's exit. */
  async shutdown(reason = 'quit'): Promise<void> {
    const answer = await this.request('shutdown', { reason });
    if (answer.kind !== 'response') throw new Error(`shutdown was refused: ${JSON.stringify(answer.error)}`);
    if (!(await this.waitForExit())) throw new Error('the plugin did not exit after answering shutdown');
  }

  /** Ends the plugin if it is still there and removes the temporary folder (unless `keep`). */
  async close(): Promise<void> {
    if (this.exitCode === undefined) {
      this.closeInput();
      if (!(await this.waitForExit(1)) && this.child) this.child.kill('SIGKILL');
    }
    if (!this.options.keep) fs.rmSync(this.work, { recursive: true, force: true });
  }
}

// --- Scripts: the test/checks.json format of `vektor-plugin test` --------------------------------------------------------

export interface TestScript {
  settings?: JSONObject;
  workspace?: { id: string; name: string } | null;
  previousSessionEndedUncleanly?: boolean;
  autoReply?: Record<string, JSONValue>;
  steps: {
    name: string;
    startup?: boolean;
    send?: { method: string; params?: JSONValue; kind?: 'request' | 'notification' };
    expect?: (Expectation & { absent?: boolean; capture?: Record<string, string> })[];
    timeout?: number;
    expectExit?: boolean;
  }[];
}

export interface ScriptReport {
  passed: boolean;
  steps: { name: string; failures: string[] }[];
  transcript: string[];
}

function substitute(value: JSONValue | undefined, variables: Record<string, string>): JSONValue | undefined {
  if (typeof value === 'string') {
    let text = value;
    for (const [name, replacement] of Object.entries(variables)) text = text.split('${' + name + '}').join(replacement);
    return text;
  }
  if (Array.isArray(value)) return value.map((item) => substitute(item, variables)!);
  if (value !== null && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substitute(item, variables)!]));
  return value;
}

/**
 * Plays a `test/checks.json` script the way `vektor-plugin test` does, against the plugin in memory (`setup`) or as a process.
 * Each step sends one message (or `startup`), then waits until every expectation is met (or its timeout, default 5 s);
 * `absent` expectations must not arrive; `capture` stores values for `${name}` in later steps.
 */
export async function runScript(script: TestScript | string, options: Omit<TestHostOptions, 'settings' | 'workspace' | 'autoReply' | 'previousSessionEndedUncleanly'>): Promise<ScriptReport> {
  const parsed: TestScript = typeof script === 'string' ? JSON.parse(fs.readFileSync(script, 'utf8')) : script;
  const host = await TestHost.start({
    ...options, settings: parsed.settings, workspace: parsed.workspace, autoReply: parsed.autoReply,
    previousSessionEndedUncleanly: parsed.previousSessionEndedUncleanly,
  });
  const variables: Record<string, string> = { ...host.variables };
  const steps: ScriptReport['steps'] = [];
  try {
    for (const step of parsed.steps) {
      const mark = host.received.length;
      let requestID: number | undefined;
      if (step.startup) requestID = host.send('startup', host.startupParams(), 'request');
      else if (step.send) requestID = host.send(step.send.method, substitute(step.send.params ?? {}, variables) ?? {}, step.send.kind);
      const expectations = step.expect ?? [];
      const positives = expectations.filter((expectation) => !expectation.absent);
      const deadline = Date.now() + (step.timeout ?? 5) * 1000;
      const unmet = () => positives.filter((expectation) => !host.received.slice(mark).some((envelope) => envelopeMatches(envelope, expectation, requestID)));
      while (unmet().length > 0 && Date.now() < deadline) {
        if (host.exitCode !== undefined) { await new Promise((resolve) => setTimeout(resolve, 100)); break; }
        await new Promise((resolve) => setTimeout(resolve, 15));
      }
      if (expectations.some((expectation) => expectation.absent)) await new Promise((resolve) => setTimeout(resolve, 300));
      const failures = unmet().map((expectation) => `did not receive ${describeExpectation(expectation)}`);
      for (const expectation of expectations.filter((candidate) => candidate.absent)) {
        if (host.received.slice(mark).some((envelope) => envelopeMatches(envelope, expectation, requestID))) {
          failures.push(`received ${describeExpectation(expectation)}, which must not arrive`);
        }
      }
      if (failures.length > 0 && host.exitCode !== undefined) failures.push(`the plugin had exited (status ${host.exitCode})`);
      if (step.expectExit && !(await host.waitForExit(step.timeout ?? 5))) failures.push('the plugin did not exit by itself after the step');
      for (const expectation of expectations) {
        if (!expectation.capture) continue;
        const message = host.received.slice(mark).find((envelope) => envelopeMatches(envelope, expectation, requestID));
        if (!message) continue;
        for (const [name, dotted] of Object.entries(expectation.capture)) {
          const value = valueAt(message, dotted);
          if (typeof value === 'string') variables[name] = value;
          else if (typeof value === 'number') variables[name] = String(value);
        }
      }
      steps.push({ name: step.name, failures });
    }
  } finally {
    await host.close();
  }
  return { passed: steps.length > 0 && steps.every((step) => step.failures.length === 0), steps, transcript: host.transcript };
}

/** One line per step (`PASS name` / `FAIL name: why`), as `vektor-plugin test` prints them. */
export function formatReport(report: ScriptReport): string {
  const lines = report.steps.map((step) => (step.failures.length === 0 ? `PASS ${step.name}` : `FAIL ${step.name}: ${step.failures.join('; ')}`));
  lines.push(report.passed ? `ALL ${report.steps.length} STEPS PASSED` : 'FAILED');
  return lines.join('\n');
}
