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
export declare function stdioTransport(): Transport;
/** A line on stderr: the plugin's Log in Vektor. */
export declare function logToStderr(text: string): void;
