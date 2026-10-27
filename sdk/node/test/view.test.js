'use strict';
// Patches (the reference's example, all or nothing), the diff that makes them, and the view state helper.
const test = require('node:test');
const assert = require('node:assert/strict');
const { blocks: b, applyPatch, diffBlocks, sameJSON, ViewState, PluginError } = require('../dist');

const board = (columns) => b.hstack(columns.map(([id, cards]) =>
  b.panel([b.list(id, cards.map(([cid, title]) => b.card([], { id: cid, title })), { group: 'cards', move: 'move' })], { id: `col-${id}`, title: id })),
{ id: 'board' });

test('the reference patch example applies in order', () => {
  const before = board([['todo', [['c1', 'One'], ['c2', 'Two'], ['c3', 'Three']]], ['done', []]]);
  // docs/reference.md, "Patches", verbatim.
  const ops = [
    { op: 'move', id: 'c1', parent: 'done', index: 0 },
    { op: 'insert', parent: 'todo', index: 0, block: { type: 'card', id: 'c9', title: 'New' } },
    { op: 'replace', id: 'c2', block: { type: 'card', id: 'c2', title: 'Renamed' } },
    { op: 'remove', id: 'c3' }];
  const after = applyPatch(before, ops);
  const expected = board([['todo', [['c9', 'New'], ['c2', 'Renamed']]], ['done', [['c1', 'One']]]]);
  expected.children[0].children[0].children[0] = { type: 'card', id: 'c9', title: 'New' };
  expected.children[0].children[0].children[1] = { type: 'card', id: 'c2', title: 'Renamed' };
  assert.ok(sameJSON(after, expected), JSON.stringify(after));
  assert.equal(before.children[0].children[0].children.length, 3, 'the original is not changed');
});

test('a patch is all or nothing, and names the operation that cannot apply', () => {
  const before = board([['todo', [['c1', 'One']]]]);
  assert.throws(() => applyPatch(before, [{ op: 'remove', id: 'c1' }, { op: 'remove', id: 'nope' }]), (error) =>
    error instanceof PluginError && /operation 2 removes “nope”/.test(error.message));
  assert.throws(() => applyPatch(before, [{ op: 'insert', parent: 'todo', index: 5, block: b.card([], { id: 'x' }) }]), /inserts at 5/);
  assert.throws(() => applyPatch(before, [{ op: 'insert', parent: 'todo', block: b.card([], { id: 'c1' }) }]), /listed twice/);
  assert.throws(() => applyPatch(before, [{ op: 'insert', parent: 'todo', block: b.card([]) }]), /needs an “id”/);
  assert.throws(() => applyPatch(before, [{ op: 'move', id: 'col-todo', parent: 'todo' }]), /into itself/);
  assert.throws(() => applyPatch(before, [{ op: 'remove', id: 'board' }]), /or is its root/);
});

function check(before, after) {
  const ops = diffBlocks(before, after);
  assert.ok(ops, 'a patch was expected');
  assert.ok(sameJSON(applyPatch(before, ops), after));
  return ops;
}

test('diff: a card moved to another column is one move', () => {
  const before = board([['todo', [['c1', 'One'], ['c2', 'Two']]], ['done', [['c3', 'Three']]]]);
  const after = board([['todo', [['c2', 'Two']]], ['done', [['c1', 'One'], ['c3', 'Three']]]]);
  assert.deepEqual(check(before, after), [{ op: 'move', id: 'c1', parent: 'done', index: 0 }]);
});

test('diff: insert, remove, rename', () => {
  const before = board([['todo', [['c1', 'One'], ['c2', 'Two'], ['c3', 'Three']]]]);
  const after = board([['todo', [['c1', 'One!'], ['c3', 'Three'], ['c4', 'Four']]]]);
  const ops = check(before, after);
  assert.deepEqual(ops.map((op) => op.op).sort(), ['insert', 'remove', 'replace']);
});

test('diff: reordering within a list', () => {
  const before = board([['todo', [['a', 'A'], ['b', 'B'], ['c', 'C'], ['d', 'D']]]]);
  const after = board([['todo', [['d', 'D'], ['a', 'A'], ['b', 'B'], ['c', 'C']]]]);
  assert.deepEqual(check(before, after), [{ op: 'move', id: 'd', parent: 'todo', index: 0 }]);
});

test('diff: nothing changed is no operation', () => {
  const tree = board([['todo', [['a', 'A']]]]);
  assert.deepEqual(diffBlocks(tree, JSON.parse(JSON.stringify(tree))), []);
});

test('diff: a changed root or a changed block without an id needs the whole description', () => {
  assert.equal(diffBlocks(b.vstack([b.text('a')]), b.vstack([b.text('b')])), null);
  assert.equal(diffBlocks(b.vstack([], { spacing: 1 }), b.vstack([], { spacing: 2 })), null);
});

test('diff: changes inside a block without an id are reached through its children with ids', () => {
  const before = b.vstack([b.textField('f', 'add'), b.list('l', [])]);
  const after = b.vstack([b.textField('f', 'add'), b.list('l', [b.row('r1', { title: 'One' })])]);
  assert.deepEqual(check(before, after), [{ op: 'insert', parent: 'l', index: 0, block: { type: 'row', id: 'r1', title: 'One' } }]);
});

test('diff: a reorder under a block without an id (a scroll) is one move, at the root, nested and in a list root', () => {
  const cards = (order) => order.map((id) => b.card([], { id, title: id.toUpperCase() }));
  const atRoot = (order) => b.vstack([b.scroll([b.list('l', cards(order))])], { id: 'root' });
  assert.deepEqual(check(atRoot(['a', 'b']), atRoot(['b', 'a'])), [{ op: 'move', id: 'a', parent: 'l', index: 1 }]);
  const nested = (order) => b.vstack([b.vstack([b.vstack([b.scroll([b.list('l', cards(order))])])], { id: 'mid' })], { id: 'root' });
  assert.deepEqual(check(nested(['a', 'b', 'c']), nested(['c', 'a', 'b'])), [{ op: 'move', id: 'c', parent: 'l', index: 0 }]);
  const listRoot = (order) => [b.scroll([b.list('l', cards(order))])];
  assert.deepEqual(check(listRoot(['a', 'b']), listRoot(['b', 'a'])), [{ op: 'move', id: 'a', parent: 'l', index: 1 }]);
});

test('diff: a block without an id that changes itself replaces the nearest block with an id; at the root, none', () => {
  const tree = (axis) => b.vstack([b.vstack([b.scroll([b.list('l', [b.card([], { id: 'a' })])], { axis })], { id: 'mid' })], { id: 'root' });
  const ops = check(tree('vertical'), tree('horizontal'));
  assert.deepEqual(ops, [{ op: 'replace', id: 'mid', block: tree('horizontal').children[0] }]);
  const bare = (axis) => b.vstack([b.scroll([b.list('l', [b.card([], { id: 'a' })])], { axis })], { id: 'root' });
  assert.equal(diffBlocks(bare('vertical'), bare('horizontal')), null);
});

test('diff: a big board, one card moved, is a small patch', () => {
  const cards = (prefix, n) => Array.from({ length: n }, (_, i) => [`${prefix}${i}`, `Card ${prefix}${i}`]);
  const before = board([['a', cards('a', 1000)], ['b', cards('b', 1000)], ['c', cards('c', 1000)]]);
  const moved = cards('a', 1000);
  const card = moved.splice(500, 1)[0];
  const target = cards('c', 1000);
  target.splice(10, 0, card);
  const after = board([['a', moved], ['b', cards('b', 1000)], ['c', target]]);
  assert.deepEqual(check(before, after), [{ op: 'move', id: 'a500', parent: 'c', index: 10 }]);
});

test('diff: random changes always give a patch that rebuilds the new tree exactly, or none', () => {
  let seed = 7;
  const random = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
  for (let round = 0; round < 300; round++) {
    const columns = ['x', 'y', 'z'].map((id) => [id, Array.from({ length: random(6) }, (_, i) => [`${id}${i}`, `T${random(3)}`])]);
    const before = board(columns);
    const all = columns.flatMap(([, cards]) => cards);
    const shuffled = all.filter(() => random(4) !== 0).map(([id, title]) => [id, random(4) === 0 ? `${title}!` : title]);
    if (random(2) === 0) shuffled.push([`new${round}`, 'New']);
    const next = [['x', []], ['y', []], ['z', []]];
    for (const card of shuffled) next[random(3)][1].push(card);
    const after = board(next);
    const ops = diffBlocks(before, after);
    if (ops) assert.ok(sameJSON(applyPatch(before, ops), after), `round ${round}`);
  }
});

// A board the way a plugin draws one: a bar, then columns whose head holds a count, then a list of cards that each hold a
// few blocks of their own (about ten blocks a card).
const bigBoard = (columns, done = new Set(), titles = {}) => b.vstack([
  b.hstack([b.text('Board'), b.searchField('search', 'search')], { id: 'bar' }),
  b.scroll([b.hstack(columns.map(([column, cards]) => b.panel([
    b.hstack([b.text(column), b.count(cards.length, { id: `count-${column}` })], { id: `head-${column}` }),
    b.list(`list-${column}`, cards.map((id) => b.card([
      b.hstack([b.text(titles[id] ?? `Task ${id}`), b.badge('tag', { role: 'label1' }), b.badge('x', { role: 'label2' })]),
      b.markdown(`Some *text* for ${id}`),
      b.hstack([b.symbol('bubble.left'), b.count(3, { id: `${id}.n` })], { id: `${id}.foot` }),
    ], { id, title: titles[id] ?? `Task ${id}`, check: 'done', checked: done.has(id) })), { group: 'cards', move: 'move' }),
  ], { id: `col-${column}` })), { id: 'columns' })], { axis: 'horizontal' }),
], { id: 'screen' });

test('diff: time grows with the tree, not its square (3,000 cards, ~30,000 blocks): a drag, a done circle, a rename', () => {
  const columns = ['a', 'b', 'c'].map((name) => [name, Array.from({ length: 1000 }, (_, n) => `${name}${n}`)]);
  const before = bigBoard(columns);
  const moved = columns.map(([name, cards]) => [name, [...cards]]);
  const [card] = moved[0][1].splice(500, 1);
  moved[2][1].unshift(card);
  const started = Date.now();
  const drag = check(before, bigBoard(moved));
  const done = check(before, bigBoard(columns, new Set(['b10'])));
  const rename = check(before, bigBoard(columns, new Set(), { c999: 'Renamed' }));
  const seconds = (Date.now() - started) / 1000;
  assert.equal(drag.length, 3, JSON.stringify(drag));
  assert.deepEqual(drag[0], { op: 'move', id: 'a500', parent: 'list-c', index: 0 });
  assert.deepEqual(new Set(drag.slice(1).map((op) => op.id)), new Set(['count-a', 'count-c']));
  assert.deepEqual(done.map((op) => [op.op, op.id]), [['replace', 'b10']]);
  assert.deepEqual(rename.map((op) => op.id), ['c999']);
  // Every id looked up from the root, the same three took minutes.
  assert.ok(seconds < 20, `three diffs of a 3,000-card board took ${seconds} s`);
});

test('patch: thousands of operations apply in time linear in the tree (no walk per operation)', () => {
  const before = bigBoard([['a', Array.from({ length: 1000 }, (_, n) => `a${n}`)], ['b', []]]);
  const ops = [];
  for (let n = 0; n < 1000; n++) ops.push({ op: 'move', id: `a${n}`, parent: 'list-b', index: n });
  for (let n = 0; n < 1000; n++) ops.push({ op: 'insert', parent: 'list-a', index: n, block: b.card([], { id: `new${n}` }) });
  const started = Date.now();
  const after = applyPatch(before, ops);
  assert.ok(Date.now() - started < 20_000);
  const list = (root, column) => root.children[1].children[0].children[column].children[1].children;
  assert.equal(list(after, 1)[999].id, 'a999');
  assert.equal(list(after, 0)[0].id, 'new0');
  // An id a patch takes away is free again; one still in the tree is not.
  assert.throws(() => applyPatch(before, [{ op: 'insert', parent: 'list-b', index: 0, block: b.card([], { id: 'a1' }) }]), /listed twice/);
  const reused = applyPatch(before, [{ op: 'remove', id: 'a1' }, { op: 'insert', parent: 'list-b', index: 0, block: b.card([], { id: 'a1' }) }]);
  assert.equal(list(reused, 1)[0].id, 'a1');
  // A replace may keep the ids of what it replaces, and they can be found after it.
  const replaced = applyPatch(before, [{ op: 'replace', id: 'a2', block: b.card([b.count(1, { id: 'a2.n' })], { id: 'a2' }) }, { op: 'remove', id: 'a2.n' }]);
  assert.deepEqual(list(replaced, 0)[2].children, []);
});

test('diff: a tree that lists an id twice is still compared (by walking, the first found), or left to the whole description', () => {
  const twice = b.vstack([b.list('l', [b.card([], { id: 'a' }), b.card([], { id: 'b' })]), b.list('m', [b.card([], { id: 'a' })])], { id: 'root' });
  const changed = b.vstack([b.list('l', [b.card([], { id: 'b' }), b.card([], { id: 'a' })]), b.list('m', [b.card([], { id: 'a' })])], { id: 'root' });
  const ops = diffBlocks(twice, changed);
  if (ops) assert.ok(sameJSON(applyPatch(twice, ops), changed));
});

test('diff: random changes in a deeper tree (heads, counts, nested blocks, columns gained and lost) rebuild it exactly', () => {
  let seed = 11;
  const random = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
  let patched = 0;
  for (let round = 0; round < 300; round++) {
    const names = ['x', 'y', 'z', 'w'].filter(() => random(5) !== 0);
    const columns = names.map((name) => [name, Array.from({ length: random(7) }, (_, n) => `${name}${n}`)]);
    const pool = columns.flatMap(([, cards]) => cards).filter(() => random(5) !== 0);
    if (random(2) === 0) pool.push(`new${round}`);
    const nextNames = random(3) === 0 ? ['x', 'y', 'z', 'w'].filter(() => random(5) !== 0) : names;
    const next = nextNames.map((name) => [name, []]);
    if (next.length > 0) for (const card of pool) next[random(next.length)][1].push(card);
    const done = new Set(pool.filter(() => random(4) === 0));
    const titles = Object.fromEntries(pool.filter(() => random(5) === 0).map((id) => [id, `T${id}`]));
    const before = bigBoard(columns);
    const after = bigBoard(next, done, titles);
    const ops = diffBlocks(before, after);
    if (ops) {
      assert.ok(sameJSON(applyPatch(before, ops), after), `round ${round}`);
      patched += 1;
    } else {
      assert.ok(names.join() !== nextNames.join(), `round ${round}: no patch`);
    }
  }
  assert.ok(patched > 200, `${patched} of 300 rounds patched`);
});

// --- ViewState, against a recording plugin ----------------------------------------------------------------------------

function recorder() {
  const sent = [];
  return { sent, notify: (method, params) => sent.push({ method, params: JSON.parse(JSON.stringify(params)) }) };
}

test('ViewState: whole description first, then patches, revisions counting up', () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'board');
  assert.equal(view.show({ header: { title: 'Board' }, blocks: board([['todo', [['c1', 'One']]], ['done', []]]) }), 'update');
  assert.equal(view.show({ header: { title: 'Board' }, blocks: board([['todo', []], ['done', [['c1', 'One']]]]) }), 'patch');
  assert.equal(view.show({ header: { title: 'Board' }, blocks: board([['todo', []], ['done', [['c1', 'One']]]]) }), 'unchanged');
  assert.equal(view.show({ header: { title: 'Board 2' }, blocks: board([['todo', []], ['done', [['c1', 'One']]]]) }), 'update');
  assert.deepEqual(plugin.sent.map((m) => m.method), ['view/update', 'view/patch', 'view/update']);
  assert.equal(plugin.sent[0].params.description.revision, 1);
  assert.deepEqual(plugin.sent[1].params, { view: 'board', revision: 2, ops: [{ op: 'move', id: 'c1', parent: 'done', index: 0 }] });
  assert.equal(plugin.sent[2].params.description.revision, 3);
  assert.equal(view.revision, 3);
});

test('ViewState: a reopened view gets the whole description again', async () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'v');
  view.show({ blocks: b.list('l', []) });
  await view.receive('view/opened', { view: 'v' });
  view.show({ blocks: b.list('l', [b.row('r', { title: 'x' })]) });
  assert.deepEqual(plugin.sent.map((m) => m.method), ['view/update', 'view/update']);
});

test('ViewState: patches off sends whole descriptions; a refused tree throws before anything is sent', () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'v', { patches: false });
  view.show({ blocks: b.list('l', []) });
  view.show({ blocks: b.list('l', [b.row('r', { title: 'x' })]) });
  assert.deepEqual(plugin.sent.map((m) => m.method), ['view/update', 'view/update']);
  assert.throws(() => view.show({ blocks: b.list('l', [b.row(undefined, { title: 'no id' })]) }), /cannot be shown: every item of “l” needs an “id”/);
  assert.equal(plugin.sent.length, 2);
});

test('ViewState: patch() applies to the kept description and refuses one that cannot apply', () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'v');
  assert.throws(() => view.patch([{ op: 'remove', id: 'x' }]), /send the whole description first/);
  view.update({ blocks: b.list('l', [b.row('a', { title: 'A' })]) });
  view.patch([{ op: 'insert', parent: 'l', block: b.row('b', { title: 'B' }) }]);
  assert.deepEqual(view.description.blocks.children.map((row) => row.id), ['a', 'b']);
  assert.throws(() => view.patch([{ op: 'remove', id: 'zzz' }]), /removes “zzz”/);
  assert.equal(plugin.sent.at(-1).params.revision, 2);
});

test('ViewState: events are routed by action; stale moves are ignored, stale text is delivered and marked', async () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'v');
  const seen = [];
  view.on('add', (event) => seen.push(['add', event.value, event.stale]));
  view.on('move', (event) => seen.push(['move', event.item, event.stale]));
  view.on('strict', (event) => seen.push(['strict', event.stale]), { stale: 'ignore' });
  view.onAnyEvent((event) => seen.push(['other', event.action]));
  view.update({ blocks: b.list('l', []) });
  view.update({ blocks: b.list('l', []) }); // revision 2
  await view.receive('view/event', { view: 'v', action: 'add', value: 'x', revision: 1 });
  await view.receive('view/event', { view: 'v', action: 'move', item: 'c1', target: 'l', index: 0, revision: 1 });
  await view.receive('view/event', { view: 'v', action: 'move', item: 'c2', target: 'l', index: 0, revision: 2 });
  await view.receive('view/event', { view: 'v', action: 'strict', revision: 1 });
  await view.receive('view/event', { view: 'v', action: 'unknown', revision: 2 });
  assert.deepEqual(seen, [['add', 'x', true], ['move', 'c2', false], ['other', 'unknown']]);
});

test('ViewState: a refused patch is answered with the whole description, numbered above anything sent; once', async () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'board');
  const heard = [];
  view.onRefused((refusal) => heard.push(`${refusal.kind} ${refusal.revision} ${refusal.refusedRevision} ${refusal.problem}`));
  view.show({ blocks: board([['todo', [['c1', 'One'], ['c2', 'Two']]], ['done', []]]) });          // 1: update
  view.show({ blocks: board([['todo', [['c2', 'Two']]], ['done', [['c1', 'One']]]]) });            // 2: patch
  view.show({ blocks: board([['todo', []], ['done', [['c1', 'One'], ['c2', 'Two']]]]) });          // 3: patch
  assert.deepEqual(plugin.sent.map((m) => m.method), ['view/update', 'view/patch', 'view/patch']);
  await view.receive('view/refused', { view: 'board', kind: 'patch', revision: 1, refusedRevision: 2, problem: 'operation 1 cannot apply.' });
  assert.deepEqual(heard, ['patch 1 2 operation 1 cannot apply.']);
  assert.deepEqual(plugin.sent.map((m) => m.method), ['view/update', 'view/patch', 'view/patch', 'view/update']);
  assert.equal(plugin.sent[3].params.description.revision, 4);
  assert.ok(sameJSON(plugin.sent[3].params.description.blocks, board([['todo', []], ['done', [['c1', 'One'], ['c2', 'Two']]]])));
  // The patch sent after the refused one is refused too: the whole description already went out after it, so not again.
  await view.receive('view/refused', { view: 'board', kind: 'patch', revision: 1, refusedRevision: 3, problem: 'x' });
  assert.equal(plugin.sent.length, 4);
  assert.equal(view.refusal.refusedRevision, 3);
});

test('ViewState: after a refusal, events made against the revision Vektor still shows are not stale', async () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'v', { resendAfterRefusal: false });
  const seen = [];
  view.on('move', (event) => seen.push(`${event.item} stale=${event.stale}`));
  view.update({ blocks: b.list('l', [b.row('a', { title: 'A' }), b.row('b', { title: 'B' })]) });  // 1
  view.show({ blocks: b.list('l', [b.row('b', { title: 'B' }), b.row('a', { title: 'A' })]) });    // 2: refused below
  await view.receive('view/refused', { view: 'v', kind: 'patch', revision: 1, refusedRevision: 2, problem: 'no' });
  await view.receive('view/event', { view: 'v', action: 'move', item: 'a', target: 'l', index: 1, revision: 1 });
  assert.deepEqual(seen, ['a stale=false']);
  assert.equal(view.show({ blocks: b.list('l', [b.row('b', { title: 'B' }), b.row('a', { title: 'A' })]) }), 'update');
  await view.receive('view/event', { view: 'v', action: 'move', item: 'b', target: 'l', index: 1, revision: 3 });
  assert.equal(view.refusal, undefined);
  await view.receive('view/event', { view: 'v', action: 'move', item: 'c', target: 'l', index: 0, revision: 1 });
  assert.deepEqual(seen, ['a stale=false', 'b stale=false']);
});

test('ViewState: a refused whole description is not sent again; the handler decides', async () => {
  const plugin = recorder();
  const view = new ViewState(plugin, 'v');
  const refusals = [];
  view.onRefused((refusal) => refusals.push(refusal));
  view.update({ blocks: b.list('l', []) });
  await view.receive('view/refused', { view: 'v', kind: 'description', revision: null, refusedRevision: 1, problem: 'too deep' });
  assert.equal(plugin.sent.length, 1);
  assert.equal(refusals[0].revision, null);
  assert.equal(view.show({ blocks: b.list('l', []) }), 'update', 'the next show sends the whole description');
});

test('sameJSON compares own fields only: a "__proto__" field is a field like any other', () => {
  const withProto = JSON.parse('{"__proto__": {}}');
  assert.equal(sameJSON(withProto, { title: {} }), false);
  assert.equal(sameJSON({ title: {} }, withProto), false);
  assert.equal(sameJSON(withProto, JSON.parse('{"__proto__": {}}')), true);
});
