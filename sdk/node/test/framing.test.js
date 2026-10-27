'use strict';
// Framing: Content-Length is a BYTE count; a header or a character split across reads must survive.
const test = require('node:test');
const assert = require('node:assert/strict');
const { encodeMessage, MessageReader, FramingError } = require('../dist');

test('encodes the byte count of the UTF-8 body, not the character count', () => {
  const message = { api: 2, method: 'toast', params: { message: 'Příliš žluťoučký kůň 👍' } };
  const framed = encodeMessage(message);
  const text = framed.toString('latin1');
  const header = text.slice(0, text.indexOf('\r\n\r\n'));
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  assert.equal(header, `Content-Length: ${body.length}`);
  assert.notEqual(body.length, JSON.stringify(message).length); // the point of the test: bytes ≠ characters
});

test('the reference example frames to Content-Length 44', () => {
  const framed = encodeMessage({ api: 1, id: 1, method: 'ping', params: {} });
  assert.equal(framed.toString('utf8'), 'Content-Length: 44\r\n\r\n{"api":1,"id":1,"method":"ping","params":{}}');
});

test('reads messages fed one byte at a time: split header, split multi-byte characters', () => {
  const messages = [
    { api: 2, method: 'web/message', params: { view: 'v', message: { text: 'é' } } },
    { api: 2, id: 7, method: 'invoke', params: { command: 'x', target: { text: '日本語 🇨🇿 é' } } },
  ];
  const bytes = Buffer.concat(messages.map(encodeMessage));
  const reader = new MessageReader();
  const out = [];
  for (let index = 0; index < bytes.length; index++) out.push(...reader.push(bytes.subarray(index, index + 1)));
  assert.deepEqual(out, messages);
  assert.equal(reader.bufferedBytes, 0);
});

test('reads several messages from one chunk, and keeps a partial one', () => {
  const one = encodeMessage({ api: 2, method: 'a', params: {} });
  const two = encodeMessage({ api: 2, method: 'b', params: { x: 'ž' } });
  const reader = new MessageReader();
  const cut = two.length - 3; // inside the body
  assert.deepEqual(reader.push(Buffer.concat([one, two.subarray(0, cut)])).map((m) => m.method), ['a']);
  assert.deepEqual(reader.push(two.subarray(cut)).map((m) => m.method), ['b']);
});

test('accepts other header lines and any case of Content-Length', () => {
  const body = Buffer.from('{"api":2,"method":"x"}', 'utf8');
  const reader = new MessageReader();
  const framed = Buffer.concat([Buffer.from(`Content-Type: application/json\r\ncontent-length: ${body.length}\r\n\r\n`, 'latin1'), body]);
  assert.equal(reader.push(framed)[0].method, 'x');
});

test('refuses a header over 1 KB, even before it ends', () => {
  const reader = new MessageReader();
  assert.throws(() => reader.push(Buffer.from('X-Padding: ' + 'a'.repeat(1100), 'latin1')), FramingError);
  const ended = new MessageReader();
  assert.throws(() => ended.push(Buffer.from(`X: ${'a'.repeat(1100)}\r\nContent-Length: 2\r\n\r\n{}`, 'latin1')), /longer than 1 KB/);
});

test('refuses a header without Content-Length, a body that is not an object, and bad JSON', () => {
  assert.throws(() => new MessageReader().push(Buffer.from('Foo: 1\r\n\r\n{}', 'latin1')), /no Content-Length/);
  assert.throws(() => new MessageReader().push(Buffer.from('Content-Length: 2\r\n\r\n[]', 'latin1')), /not a JSON object/);
  assert.throws(() => new MessageReader().push(Buffer.from('Content-Length: 2\r\n\r\n{x', 'latin1')), /not valid JSON/);
});

test('refuses a body over 16 MB by its header', () => {
  assert.throws(() => new MessageReader().push(Buffer.from(`Content-Length: ${16 * 1024 * 1024 + 1}\r\n\r\n`, 'latin1')), /16 MB/);
});
