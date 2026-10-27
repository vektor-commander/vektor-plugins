// The few Node.js APIs the SDK uses, declared here so the SDK builds with TypeScript alone (no @types/node download).
// Only what the sources touch is declared; it is not a general description of Node.

interface Buffer extends Uint8Array {
  toString(encoding?: BufferEncoding, start?: number, end?: number): string;
  indexOf(value: string | number | Uint8Array, byteOffset?: number): number;
  subarray(start?: number, end?: number): Buffer;
  equals(other: Uint8Array): boolean;
}
declare const Buffer: {
  from(data: string, encoding?: BufferEncoding): Buffer;
  from(data: Uint8Array | ArrayLike<number> | Iterable<number>): Buffer;
  alloc(size: number): Buffer;
  concat(list: readonly Uint8Array[], totalLength?: number): Buffer;
  byteLength(text: string, encoding?: BufferEncoding): number;
  isBuffer(value: unknown): value is Buffer;
};
type BufferEncoding = 'utf8' | 'utf-8' | 'ascii' | 'latin1' | 'base64' | 'hex';

declare function setTimeout(callback: (...args: any[]) => void, ms?: number): unknown;
declare function clearTimeout(handle: unknown): void;
declare function setImmediate(callback: () => void): unknown;

interface NodeReadable {
  on(event: 'data', listener: (chunk: Buffer) => void): this;
  on(event: 'end' | 'close', listener: () => void): this;
  on(event: 'error', listener: (error: Error) => void): this;
  resume(): this;
}
interface NodeWritable {
  write(chunk: Uint8Array | string, callback?: (error?: Error | null) => void): boolean;
  end(callback?: () => void): void;
  on(event: 'error', listener: (error: Error) => void): this;
}

declare const process: {
  env: Record<string, string | undefined>;
  argv: string[];
  stdin: NodeReadable;
  stdout: NodeWritable;
  stderr: NodeWritable;
  exit(code?: number): never;
  pid: number;
  platform: string;
  versions: Record<string, string>;
};

declare const require: (name: string) => any;
declare const module: { exports: unknown };
declare const __dirname: string;

declare module 'fs' {
  interface Stats {
    isFile(): boolean;
    isDirectory(): boolean;
    isSymbolicLink(): boolean;
    size: number | bigint;
    ino: number | bigint;
    dev: number | bigint;
    mtimeMs: number | bigint;
    mtimeNs?: bigint;
    mtime: Date;
  }
  interface Dirent {
    name: string;
    isFile(): boolean;
    isDirectory(): boolean;
    isSymbolicLink(): boolean;
  }
  export function readFileSync(path: string): Buffer;
  export function readFileSync(path: string, encoding: BufferEncoding): string;
  export function writeFileSync(path: string, data: string | Uint8Array): void;
  export function renameSync(from: string, to: string): void;
  export function mkdirSync(path: string, options?: { recursive?: boolean }): string | undefined;
  export function mkdtempSync(prefix: string): string;
  export function existsSync(path: string): boolean;
  export function lstatSync(path: string, options?: { bigint?: boolean }): Stats;
  export function statSync(path: string, options?: { bigint?: boolean }): Stats;
  export function readdirSync(path: string, options: { withFileTypes: true }): Dirent[];
  export function readdirSync(path: string): string[];
  export function realpathSync(path: string): string;
  export function rmSync(path: string, options?: { recursive?: boolean; force?: boolean }): void;
  export function unlinkSync(path: string): void;
  export function openSync(path: string, flags: string): number;
  export function readSync(fd: number, buffer: Uint8Array, offset: number, length: number, position: number): number;
  export function closeSync(fd: number): void;
  export function copyFileSync(from: string, to: string): void;
}

declare module 'path' {
  export function join(...parts: string[]): string;
  export function dirname(path: string): string;
  export function basename(path: string): string;
  export function resolve(...parts: string[]): string;
  export function relative(from: string, to: string): string;
  export const sep: string;
}

declare module 'os' {
  export function tmpdir(): string;
  export function homedir(): string;
}

declare module 'crypto' {
  export function randomBytes(size: number): Buffer;
  export function createHash(algorithm: string): { update(data: string | Uint8Array): { digest(encoding: 'hex'): string } };
}

declare module 'child_process' {
  interface ChildProcess {
    stdin: NodeWritable;
    stdout: NodeReadable;
    stderr: NodeReadable;
    pid?: number;
    exitCode: number | null;
    kill(signal?: string): boolean;
    on(event: 'exit', listener: (code: number | null, signal: string | null) => void): this;
    on(event: 'error', listener: (error: Error) => void): this;
  }
  export function spawn(
    command: string,
    args: string[],
    options: { cwd?: string; env?: Record<string, string | undefined>; stdio?: string[]; detached?: boolean },
  ): ChildProcess;
}

declare function structuredClone<T>(value: T): T;
declare class AbortSignal {
  readonly aborted: boolean;
  addEventListener(type: 'abort', listener: () => void): void;
}
declare class AbortController {
  readonly signal: AbortSignal;
  abort(): void;
}
