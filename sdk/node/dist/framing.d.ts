/** A header larger than this ends the plugin in Vektor; the SDK refuses one too. */
export declare const MAX_HEADER_BYTES = 1024;
/** A body larger than this ends the plugin in Vektor. */
export declare const MAX_BODY_BYTES: number;
/** One framed message: the header with the body's byte count, then the body. */
export declare function encodeMessage(message: unknown): Buffer;
/**
 * Collects bytes as they arrive and hands back whole messages. Feed it every chunk read from stdin; it keeps what is not yet
 * a whole message. A broken stream throws a `FramingError` (and stays broken: the caller should stop).
 */
export declare class MessageReader {
    private pending;
    /** Adds `chunk` and returns every message that is now complete, in order. */
    push(chunk: Uint8Array): unknown[];
    /** Bytes received that are not yet part of a whole message. */
    get bufferedBytes(): number;
}
