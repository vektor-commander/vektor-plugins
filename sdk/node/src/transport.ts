// Where the bytes go. A plugin talks to Vektor over its stdin and stdout; the test kit swaps in an in-memory pair, so the
// same plugin code runs under a test runner without a process.

export interface Transport {
  /** Writes one framed message. */
  write(bytes: Buffer): void;
  /** Called with every chunk that arrives. */
  onData(listener: (chunk: Buffer) => void): void;
  /** Called once when the input ends (Vektor is gone). */
  onEnd(listener: () => void): void;
  /** Ends the plugin with `code`, after everything written has been flushed. */
  exit(code: number): void;
}

/**
 * The real one: stdin and stdout. stdout carries messages and NOTHING else. The SDK keeps the real stdout for itself and
 * points `process.stdout.write` (and with it `console.log`) at stderr: one stray line on stdout would break the framing and
 * Vektor would end the plugin, while on stderr it is a line in the plugin's Log.
 */
export function stdioTransport(): Transport {
  const write = messageOutput();
  let exiting = false;
  return {
    write(bytes) {
      write(bytes);
    },
    onData(listener) {
      process.stdin.on('data', listener);
    },
    onEnd(listener) {
      process.stdin.on('end', listener);
    },
    exit(code) {
      if (exiting) return;
      exiting = true;
      // Leave only once what was written has reached the pipe: an answer to `shutdown` must not be lost.
      write(Buffer.alloc(0), () => process.exit(code));
    },
  };
}

type Writer = (bytes: Buffer, done?: () => void) => void;
let realStdout: Writer | undefined;

/** The real stdout's writer, taken once; from then on everything else written to stdout goes to stderr. */
function messageOutput(): Writer {
  if (realStdout) return realStdout;
  const original = process.stdout.write.bind(process.stdout) as (chunk: Uint8Array | string, callback?: () => void) => boolean;
  realStdout = (bytes, done) => { original(bytes, done); };
  const toStderr = process.stderr.write.bind(process.stderr);
  process.stdout.write = ((...args: unknown[]) => (toStderr as (...a: unknown[]) => boolean)(...args)) as typeof process.stdout.write;
  return realStdout;
}

/** A line on stderr: the plugin's Log in Vektor. */
export function logToStderr(text: string): void {
  process.stderr.write(`${text}\n`);
}
