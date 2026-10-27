'use strict';
// The three-way sync helper: merged, conflicts, unchanged.
const test = require('node:test');
const assert = require('node:assert/strict');
const { threeWayMerge } = require('../dist');

const card = (id, fields = {}, updatedAt = '2026-10-01T10:00:00Z') => ({ id, title: id.toUpperCase(), column: 'todo', ...fields, updatedAt });

test('nothing changed anywhere: unchanged', () => {
  const base = [card('a'), card('b')];
  const result = threeWayMerge(base, base, base);
  assert.equal(result.status, 'unchanged');
  assert.equal(result.changedMine, false);
  assert.equal(result.changedTheirs, false);
});

test('only one side changed: that side wins, no conflict', () => {
  const base = [card('a'), card('b')];
  const mine = [card('a', { title: 'Mine' }, '2026-10-02T00:00:00Z'), card('b')];
  const theirs = [card('a'), card('b', { column: 'done' }, '2026-10-03T00:00:00Z')];
  const result = threeWayMerge(base, mine, theirs);
  assert.equal(result.status, 'merged');
  assert.deepEqual(result.records, [mine[0], theirs[1]]);
  assert.equal(result.changedMine, true);
  assert.equal(result.changedTheirs, true);
});

test('both added the same id with different content: a bothAdded conflict', () => {
  const result = threeWayMerge([], [card('n', { title: 'Mine' })], [card('n', { title: 'Theirs' }, '2026-10-05T00:00:00Z')]);
  assert.equal(result.status, 'conflicts');
  assert.equal(result.conflicts.length, 1);
  assert.equal(result.conflicts[0].kind, 'bothAdded');
  assert.equal(result.conflicts[0].newer, 'theirs');
  assert.deepEqual(result.records, [card('n', { title: 'Theirs' }, '2026-10-05T00:00:00Z')], 'theirs is kept until the plugin resolves it');
});

test('both added the same record identically: no conflict', () => {
  const result = threeWayMerge([], [card('n')], [card('n')]);
  assert.equal(result.status, 'unchanged');
});

test('both changed the same field differently: a bothChanged conflict naming it', () => {
  const base = [card('a')];
  const result = threeWayMerge(base, [card('a', { title: 'Mine' }, '2026-10-02T00:00:00Z')], [card('a', { title: 'Theirs' }, '2026-10-03T00:00:00Z')]);
  assert.equal(result.status, 'conflicts');
  assert.deepEqual(result.conflicts.map((c) => [c.id, c.kind, c.fields, c.newer]), [['a', 'bothChanged', ['title'], 'theirs']]);
});

test('both changed different fields: merged field by field, the newer stamp kept', () => {
  const base = [card('a')];
  const result = threeWayMerge(base, [card('a', { title: 'Mine' }, '2026-10-02T00:00:00Z')], [card('a', { column: 'done' }, '2026-10-03T00:00:00Z')]);
  assert.equal(result.status, 'merged');
  assert.deepEqual(result.records, [{ id: 'a', title: 'Mine', column: 'done', updatedAt: '2026-10-03T00:00:00Z' }]);
});

test('both made the same change: no conflict', () => {
  const base = [card('a')];
  const result = threeWayMerge(base, [card('a', { column: 'done' }, '2026-10-02T00:00:00Z')], [card('a', { column: 'done' }, '2026-10-03T00:00:00Z')]);
  assert.equal(result.status, 'merged');
  assert.equal(result.records[0].column, 'done');
});

test('I deleted it while they changed it: deletedByMe; they deleted it while I changed it: deletedByThem', () => {
  const base = [card('a'), card('b')];
  const mine = [card('b', { title: 'Changed here' })];                // a deleted here
  const theirs = [card('a', { title: 'Changed there' })];             // b deleted there
  const result = threeWayMerge(base, mine, theirs);
  assert.equal(result.status, 'conflicts');
  assert.deepEqual(result.conflicts.map((c) => [c.id, c.kind]).sort(), [['a', 'deletedByMe'], ['b', 'deletedByThem']]);
  assert.equal(result.conflicts.find((c) => c.id === 'a').mine, undefined);
  assert.equal(result.conflicts.find((c) => c.id === 'b').theirs, undefined);
});

test('a delete on one side of an untouched record is taken', () => {
  const base = [card('a'), card('b')];
  const result = threeWayMerge(base, [card('a')], [card('a'), card('b')]);
  assert.equal(result.status, 'merged');
  assert.deepEqual(result.records.map((r) => r.id), ['a']);
  assert.equal(result.changedTheirs, true);
  assert.equal(result.changedMine, false);
});

test('base missing (the first sync): additions on either side are taken, different copies conflict', () => {
  const result = threeWayMerge(null, [card('m'), card('same'), card('x', { title: 'Mine' })], [card('t'), card('same'), card('x', { title: 'Theirs' })]);
  assert.equal(result.status, 'conflicts');
  assert.deepEqual(result.records.map((r) => r.id), ['m', 'same', 'x', 't']);
  assert.deepEqual(result.conflicts.map((c) => [c.id, c.kind]), [['x', 'bothAdded']]);
});

test('updatedAt alone never makes a conflict, and ignored fields are not compared', () => {
  const base = [card('a')];
  const result = threeWayMerge(base, [card('a', { seen: 1 }, '2026-10-09T00:00:00Z')], [card('a', { seen: 2 })], { ignore: ['seen'] });
  assert.equal(result.conflicts.length, 0);
});

test('records need a stable text id, once per side', () => {
  assert.throws(() => threeWayMerge([], [{ title: 'no id' }], []), /needs a text “id”/);
  assert.throws(() => threeWayMerge([], [card('a'), card('a')], []), /twice/);
});

test('a field-by-field merge keeps the ignored fields (as mine has them)', () => {
  const base = [card('a', { local: 'X' })];
  const result = threeWayMerge(base, [card('a', { local: 'X', title: 'Mine' }, '2026-10-02T00:00:00Z')],
    [card('a', { local: 'X', column: 'done' }, '2026-10-03T00:00:00Z')], { ignore: ['local'] });
  assert.equal(result.status, 'merged');
  assert.deepEqual(result.records, [{ id: 'a', title: 'Mine', column: 'done', local: 'X', updatedAt: '2026-10-03T00:00:00Z' }]);
});

test('a field named __proto__ is merged like any other (records come from JSON.parse, which keeps it as a field)', () => {
  const parse = (text) => JSON.parse(text);
  const result = threeWayMerge([parse('{"id":"a","x":1,"__proto__":{"k":1}}')], [parse('{"id":"a","x":2,"__proto__":{"k":1}}')],
    [parse('{"id":"a","x":1,"__proto__":{"k":2}}')]);
  assert.equal(result.status, 'merged');
  assert.deepEqual(JSON.parse(JSON.stringify(result.records[0])), parse('{"id":"a","x":2,"__proto__":{"k":2}}'));
  assert.equal(Object.getPrototypeOf(result.records[0]), Object.prototype, 'the record itself keeps an ordinary prototype');
  assert.ok(Object.hasOwn(result.records[0], '__proto__'));
});

test('updatedAt: a number is milliseconds since 1970; text only an ISO 8601 date-time; anything else is no stamp', () => {
  const newer = (mine, theirs) => threeWayMerge(null, [{ id: 'a', v: 1, updatedAt: mine }], [{ id: 'a', v: 2, updatedAt: theirs }]).conflicts[0].newer;
  assert.equal(newer(1792575995, '2026-01-01T00:00:00Z'), 'theirs', '1792575995 ms is in January 1970');
  assert.equal(newer(1792575995000, '2026-01-01T00:00:00Z'), 'mine');
  assert.equal(newer('2026-10-23T12:00:00.5+02:00', '2026-10-23T10:00:00.4Z'), 'mine', 'fractional seconds and an offset');
  assert.equal(newer('2026-10-23T10:00:00.0019Z', '2026-10-23T10:00:00.001Z'), undefined, 'milliseconds are the precision');
  assert.equal(newer('2026-01-01T00:00:00.001Z', 1767225600000), 'mine');
  for (const notAStamp of ['2026-10-24', '2026-02-30T00:00:00Z', '2026-10-23T24:00:00Z', 'Fri, 23 Oct 2026 10:00:00 GMT', '1', '', true, null]) {
    assert.equal(newer(notAStamp, '2026-10-23T10:00:00Z'), undefined, JSON.stringify(notAStamp));
  }
});

test('with conflicts open, records hold what loses nothing on the place: theirs where they have it, else mine (never a delete)', () => {
  const base = [card('changed'), card('mineGone'), card('theirsGone')];
  const mine = [card('changed', { title: 'Mine' }), card('theirsGone', { title: 'Changed here' })];
  const theirs = [card('changed', { title: 'Theirs' }), card('mineGone', { title: 'Changed there' })];
  const result = threeWayMerge(base, mine, theirs);
  assert.equal(result.status, 'conflicts');
  assert.deepEqual(result.records, [theirs[0], mine[1], theirs[1]]);
});

test('a change only to an ignored field, while the other side deleted the record, is a conflict too (not a silent delete)', () => {
  const base = [card('a', { note: 'x' }), card('b', { note: 'x' })];
  const mine = [card('a', { note: 'Changed here' })];                                  // b deleted here
  const theirs = [card('b', { note: 'Changed there' })];                               // a deleted there
  const result = threeWayMerge(base, mine, theirs, { ignore: ['note'] });
  assert.deepEqual(result.conflicts.map((c) => [c.id, c.kind]), [['a', 'deletedByThem'], ['b', 'deletedByMe']]);
  const touched = threeWayMerge(base, [card('a', { note: 'x' }, '2026-10-09T00:00:00Z'), base[1]], [base[1]], { ignore: ['note'] });
  assert.equal(touched.status, 'merged', 'a new updatedAt alone is no change: the delete is taken');
});
