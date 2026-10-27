// The wire: JSON messages framed like a language server's.
//
//     Content-Length: <bytes>\r\n
//     \r\n
//     <JSON body>
//
// `Content-Length` counts BYTES of the UTF-8 body, never characters: "é" is two bytes, "👍" four. The reader works on
// Buffers and decodes a body only when all of its bytes are there, so a character split across two reads is never broken,
// and a header split across reads simply waits for the rest.

import { FramingError } from './errors';

/** A header larger than this ends the plugin in Vektor; the SDK refuses one too. */
export const MAX_HEADER_BYTES = 1024;
/** A body larger than this ends the plugin in Vektor. */
export const MAX_BODY_BYTES = 16 * 1024 * 1024;

const SEPARATOR = Buffer.from('\r\n\r\n', 'latin1');

/** One framed message: the header with the body's byte count, then the body. */
export function encodeMessage(message: unknown): Buffer {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  if (body.length > MAX_BODY_BYTES) {
    throw new FramingError(`A message of ${body.length} bytes is larger than Vektor accepts (16 MB).`);
  }
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'latin1'), body]);
}

/**
 * Collects bytes as they arrive and hands back whole messages. Feed it every chunk read from stdin; it keeps what is not yet
 * a whole message. A broken stream throws a `FramingError` (and stays broken: the caller should stop).
 */
export class MessageReader {
  private pending: Buffer = Buffer.alloc(0);

  /** Adds `chunk` and returns every message that is now complete, in order. */
  push(chunk: Uint8Array): unknown[] {
    this.pending = this.pending.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.pending, chunk]);
    const messages: unknown[] = [];
    for (;;) {
      const headerEnd = this.pending.indexOf(SEPARATOR);
      if (headerEnd < 0) {
        // No end of header yet. More than 1 KB without one can never become a valid header.
        if (this.pending.length > MAX_HEADER_BYTES + SEPARATOR.length) {
          throw new FramingError('A message header is longer than 1 KB.');
        }
        return messages;
      }
      if (headerEnd > MAX_HEADER_BYTES) throw new FramingError('A message header is longer than 1 KB.');
      const header = this.pending.subarray(0, headerEnd).toString('latin1');
      let length = -1;
      for (const line of header.split('\r\n')) {
        const match = /^content-length:\s*(\d+)\s*$/i.exec(line);
        if (match) length = Number(match[1]);
      }
      if (length < 0) throw new FramingError('A message header has no Content-Length.');
      if (length > MAX_BODY_BYTES) throw new FramingError('A message body is larger than 16 MB.');
      const start = headerEnd + SEPARATOR.length;
      if (this.pending.length < start + length) return messages; // the rest of the body has not arrived
      const body = this.pending.subarray(start, start + length).toString('utf8');
      this.pending = this.pending.subarray(start + length);
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch {
        throw new FramingError('A message body is not valid JSON.');
      }
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new FramingError('A message is not a JSON object.');
      }
      messages.push(parsed);
    }
  }

  /** Bytes received that are not yet part of a whole message. */
  get bufferedBytes(): number {
    return this.pending.length;
  }
}
