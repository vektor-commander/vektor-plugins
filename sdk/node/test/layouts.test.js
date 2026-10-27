'use strict';
// The five layouts: the JSON they build (checked by eye against docs/reference.md, then pinned in sdk/fixtures/layouts.json,
// which the Swift SDK's tests check too), that Vektor would accept it, and that events reach the right callback.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const sdk = require('../dist');
const { validateBlocks, ViewState } = sdk;


// --- The inputs, the same as the Swift tests build ---------------------------------------------------------------------------
const boardSpec = () => ({
  columns: [
    { id: 'todo', title: 'To do', role: 'label6', cards: [
      { id: 'c1', title: 'Write the spec', subtitle: 'Draft first', role: 'accent', tags: [{ text: 'docs', role: 'label3' }] },
      { id: 'c2', title: 'Ship it' }] },
    { id: 'done', title: 'Done', role: 'label4', cards: [] }],
  search: '',
  filter: { options: [{ value: '', title: 'All' }, { value: 'docs', title: 'docs' }], value: '' },
  toolbar: [sdk.blocks.button({ id: 'sync', title: 'Sync', symbol: 'arrow.triangle.2.circlepath', action: 'sync' })],
});
const listDetailSpec = () => ({
  items: [{ id: 'a', title: 'Alpha', subtitle: 'first', symbol: 'doc', badge: { text: 'new', role: 'positive' } }, { id: 'b', title: 'Beta' }],
  selected: 'a',
  detail: sdk.detailPanel({ title: 'Alpha', subtitle: 'first', symbol: 'doc', fields: [{ label: 'Size', value: '3 KB' }], markdown: 'Hello', actions: [{ key: 'open', title: 'Open', style: 'primary' }] }),
});
const tableSpec = () => {
  const columns = [{ id: 'name', title: 'Name', sortable: true }, { id: 'size', title: 'Size', width: 80, sortable: true }];
  const sorted = { column: 'size', ascending: false };
  return {
    columns, sorted, selected: ['r1', 'r2'],
    rows: sdk.sortRows([{ id: 'r1', cells: ['a', 5] }, { id: 'r2', cells: ['b', 20] }, { id: 'r3', cells: ['c', 1], dimmed: true }], columns, sorted),
    toolbar: [{ key: 'delete', title: 'Delete', symbol: 'trash', style: 'destructive', needsSelection: true }, { key: 'add', title: 'Add', symbol: 'plus' }],
  };
};
const formSpec = () => ({
  sections: [
    { id: 'general', title: 'General', description: 'How it works.', fields: [
      { kind: 'text', key: 'name', label: 'Name', value: 'Vektor', placeholder: 'A name', help: 'Shown in the title' },
      { kind: 'toggle', key: 'sync', label: 'Sync', value: true },
      { kind: 'picker', key: 'mode', label: 'Mode', options: [{ value: 'a', title: 'A' }, { value: 'b', title: 'B' }], value: 'a', segmented: true },
      { kind: 'textArea', key: 'notes', label: 'Notes', value: 'x', error: 'Too short' }] },
    { id: 'more', title: 'More', collapsible: true, collapsed: true, fields: [
      { kind: 'stepper', key: 'count', label: 'Count', value: 2, min: 0, max: 9 },
      { kind: 'role', key: 'colour', label: 'Colour', value: 'label1', roles: ['label1', 'label4'] },
      { kind: 'button', key: 'reset', label: 'Defaults', title: 'Reset', symbol: 'arrow.counterclockwise', style: 'destructive' }] }],
});
const cardsSpec = () => ({
  cards: [
    { id: 'k1', symbol: 'cloud', title: 'Tunnel', pill: { label: 'Running', role: 'positive' }, lines: ['example.com', { text: 'Open', link: 'https://example.com' }], openable: true,
      buttons: [{ key: 'stop', title: 'Stop', symbol: 'stop' }, { key: 'copy', symbol: 'doc.on.doc', tooltip: 'Copy' }],
      menu: [{ key: 'rename', title: 'Rename' }, { separator: true }, { key: 'delete', title: 'Delete', symbol: 'trash', destructive: true }] },
    { id: 'k2', title: 'Plain' }],
});
const cases = {
  board: () => sdk.board(boardSpec()),
  'board: filtered': () => sdk.board({ ...boardSpec(), search: 'ship', filter: { ...boardSpec().filter, value: '' } }),
  'board: columns fill the pane': () => sdk.board({ ...boardSpec(), columnMinWidth: 260 }),
  listDetail: () => sdk.listDetail(listDetailSpec()),
  'listDetail: nothing chosen': () => sdk.listDetail({ ...listDetailSpec(), selected: undefined, search: 'be', emptyDetail: { text: 'Choose an item.', symbol: 'sidebar.right' } }),
  table: () => sdk.tableWithToolbar(tableSpec()),
  settingsForm: () => sdk.settingsForm(formSpec()),
  cardList: () => sdk.cardList(cardsSpec()),
  'cardList: empty': () => sdk.cardList({ cards: [], empty: { title: 'No tunnels', text: 'Create one.', symbol: 'cloud' } }),
};

// `WRITE_FIXTURES=1 node --test test/layouts.test.js` rewrites the fixture from the builders: read the diff before committing it.
if (process.env.WRITE_FIXTURES) {
  const out = Object.fromEntries(Object.entries(cases).map(([name, build]) => [name, JSON.parse(JSON.stringify(build()))]));
  fs.writeFileSync(path.resolve(__dirname, '../../fixtures/layouts.json'), JSON.stringify(out, null, 2) + '\n');
}

test('every layout builds exactly the JSON in sdk/fixtures/layouts.json', () => {
  const fixtures = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../fixtures/layouts.json'), 'utf8'));
  assert.deepEqual(Object.keys(fixtures).sort(), Object.keys(cases).sort());
  for (const [name, build] of Object.entries(cases)) assert.deepEqual(JSON.parse(JSON.stringify(build())), fixtures[name], name);
});

test('every layout is a tree Vektor accepts, with no colour value', () => {
  for (const [name, build] of Object.entries(cases)) {
    const { problems, warnings } = validateBlocks(build());
    assert.deepEqual([problems, warnings], [[], []], name);
  }
});

test('ids stay stable when the data changes (a card keeps its id wherever it is)', () => {
  const spec = boardSpec();
  const ids = (block) => [block.id, ...(block.children ?? []).flatMap(ids)].filter(Boolean);
  const before = ids(sdk.board(spec));
  sdk.moveCard(spec.columns, { card: 'c1', to: 'done', index: 0 });
  const after = ids(sdk.board(spec));
  assert.deepEqual([...after].sort(), [...before].sort());
  assert.equal(new Set(after).size, after.length, 'unique');
});

// --- Events ------------------------------------------------------------------------------------------------------------------
const recorder = () => {
  const sent = [];
  const view = new ViewState({ notify: (method, params) => sent.push({ method, params }) }, 'v');
  const calls = [];
  const record = (name) => (...args) => { calls.push([name, ...args.slice(0, -1)]); };
  return { view, sent, calls, record };
};
const event = (view, params) => view.receive('view/event', { view: 'v', ...params });

test('board: events reach the typed callbacks', async () => {
  const { view, calls, record } = recorder();
  sdk.routeBoard(view, {}, {
    onAdd: record('add'), onOpen: record('open'), onRename: record('rename'), onRemove: record('remove'), onMove: record('move'),
    onColumnAction: record('column'), onSearch: record('search'), onFilter: record('filter'),
  });
  await event(view, { action: 'board.add', block: 'board.add.todo' });
  await event(view, { action: 'board.open', block: 'c1' });
  await event(view, { action: 'board.rename', block: 'c1', value: 'New title' });
  await event(view, { action: 'board.remove', block: 'c2' });
  await event(view, { action: 'board.move', item: 'c1', from: 'board.list.todo', target: 'board.list.done', index: 2 });
  await event(view, { action: 'board.column.delete', block: 'board.colmenu.done' });
  await event(view, { action: 'board.search', block: 'board.search', value: 'spec' });
  await event(view, { action: 'board.filter', block: 'board.filter', value: 'docs' });
  assert.deepEqual(calls, [
    ['add', 'todo'], ['open', 'c1'], ['rename', 'c1', 'New title'], ['remove', 'c2'],
    ['move', { card: 'c1', from: 'todo', to: 'done', index: 2 }], ['column', 'done', 'delete'], ['search', 'spec'], ['filter', 'docs'],
  ]);
});

test('board: a move made against an older description is dropped, other events are not', async () => {
  const { view, calls, record } = recorder();
  view.update({ blocks: sdk.board(boardSpec()) });
  view.update({ blocks: sdk.board(boardSpec()) });   // revision 2
  sdk.routeBoard(view, {}, { onMove: record('move'), onSearch: record('search') });
  await event(view, { action: 'board.move', item: 'c1', target: 'board.list.done', index: 0, revision: 1 });
  await event(view, { action: 'board.search', value: 'x', revision: 1 });
  await event(view, { action: 'board.move', item: 'c1', target: 'board.list.done', index: 0, revision: 2 });
  assert.deepEqual(calls.map((call) => call[0]), ['search', 'move']);
});

test('board: moving a card is a move patch, not a replaced column', () => {
  // A board of 40 cards: a patch is sent when it is smaller than the whole description, which it is only if the counts
  // (blocks of their own) change instead of the columns' own fields.
  const columns = [
    { id: 'a', title: 'A', cards: Array.from({ length: 20 }, (_, i) => ({ id: `a${i}`, title: `Card ${i}`, tags: [{ text: 'x' }] })) },
    { id: 'b', title: 'B', cards: Array.from({ length: 20 }, (_, i) => ({ id: `b${i}`, title: `Card ${i}` })) },
  ];
  const sent = [];
  const view = new ViewState({ notify: (method, params) => sent.push({ method, params }) }, 'w');
  view.show({ blocks: sdk.board({ columns }) });
  sdk.moveCard(columns, { card: 'a3', to: 'b', index: 5 });
  assert.equal(view.show({ blocks: sdk.board({ columns }) }), 'patch');
  const ops = sent[1].params.ops;
  assert.ok(ops.some((op) => op.op === 'move' && op.id === 'a3' && op.parent === 'board.list.b' && op.index === 5), JSON.stringify(ops));
  assert.ok(!ops.some((op) => op.op === 'replace' && /^board\.col\./.test(op.id)), 'no column is replaced');
  assert.ok(JSON.stringify(ops).length < 600, `a small patch (${JSON.stringify(ops).length} bytes)`);
});

test('board: the "All" filter option (value \'\') goes out as a value Vektor accepts and comes back as \'\'', async () => {
  const block = sdk.board(boardSpec());
  const filter = block.children[0].children[1];
  assert.equal(filter.type, 'picker');
  assert.deepEqual(filter.options.map((option) => option.value), ['board.all', 'docs']);
  assert.equal(filter.value, 'board.all');
  assert.equal(sdk.board({ ...boardSpec(), filter: { ...boardSpec().filter, value: 'docs' } }).children[0].children[1].value, 'docs');
  assert.equal(sdk.board({ ...boardSpec(), id: 'roadmap' }).children[0].children[1].value, 'roadmap.all');
  const { view, calls, record } = recorder();
  sdk.routeBoard(view, {}, { onFilter: record('filter') });
  await event(view, { action: 'board.filter', block: 'board.filter', value: 'board.all' });
  await event(view, { action: 'board.filter', block: 'board.filter', value: 'docs' });
  assert.deepEqual(calls, [['filter', ''], ['filter', 'docs']]);
});

test('board: a card opens from its context menu (Vektor gives `edit` precedence on Return); the "…" has a VoiceOver label', () => {
  const todo = sdk.board(boardSpec()).children[1].children[0].children[0];
  const c1 = todo.children[1].children[0];
  assert.equal(c1.id, 'c1');
  assert.equal(c1.edit, 'board.rename');
  assert.equal(c1.action, undefined, 'an action would never fire beside edit');
  assert.deepEqual(c1.menu, [{ title: 'Open', action: 'board.open' }]);
  const more = todo.children[0].children.find((block) => block.type === 'menu');
  assert.equal(more.label, 'To do actions');
});

test('board: a custom id and column menu', () => {
  const block = sdk.board({ ...boardSpec(), id: 'roadmap', columnMenu: [{ key: 'archive', title: 'Archive' }] });
  assert.equal(block.id, 'roadmap');
  const text = JSON.stringify(block);
  assert.ok(text.includes('"roadmap.column.archive"') && !text.includes('"board.'));
});

test('board: moveCard counts shown cards only, and keeps hidden ones in place', () => {
  const columns = [
    { id: 'a', title: 'A', cards: [{ id: '1', title: 'one' }, { id: '2', title: 'two x' }, { id: '3', title: 'three' }, { id: '4', title: 'four x' }] },
    { id: 'b', title: 'B', cards: [{ id: '5', title: 'five x' }, { id: '6', title: 'sixty' }, { id: '7', title: 'seven x' }] },
  ];
  const shown = (c) => c.title.endsWith('x');
  // Shown in b: 5, 7. Dropping card 2 at index 1 (between 5 and 7) goes right before 7, after the hidden 6.
  assert.ok(sdk.moveCard(columns, { card: '2', from: 'a', to: 'b', index: 1 }, shown));
  assert.deepEqual(columns[1].cards.map((c) => c.id), ['5', '6', '2', '7']);
  assert.deepEqual(columns[0].cards.map((c) => c.id), ['1', '3', '4']);
  assert.ok(sdk.moveCard(columns, { card: '1', to: 'b', index: 99 }, shown));   // past the end: last
  assert.equal(columns[1].cards.at(-1).id, '1');
  assert.ok(sdk.moveCard(columns, { card: '4', to: 'a', index: 0 }));           // within a column
  assert.deepEqual(columns[0].cards.map((c) => c.id), ['4', '3']);
  assert.ok(sdk.moveCard(columns, { card: '3', to: 'a', index: -1 }));           // a malformed index: last
  assert.deepEqual(columns[0].cards.map((c) => c.id), ['4', '3']);
  assert.equal(sdk.moveCard(columns, { card: 'nope', to: 'a', index: 0 }), false);
  assert.equal(sdk.moveCard(columns, { card: '3', to: 'nope', index: 0 }), false);
});

test('board: search and filter hide cards and the count says so', () => {
  const block = sdk.board({ ...boardSpec(), search: 'ship' });
  const todo = block.children[1].children[0].children[0];
  assert.equal(todo.id, 'board.col.todo');
  assert.equal(todo.children[0].children[0].text, '1 of 2');
  assert.deepEqual(todo.children[1].children.map((c) => c.id), ['c2']);
  assert.equal(sdk.board(boardSpec()).children[1].children[0].children[0].children[0].children[0].count, 2);
  assert.equal(sdk.boardShows({ search: '', filter: { options: [], value: 'docs' } }, { id: 'x', title: 'x', tags: [{ text: 'docs' }] }), true);
  assert.equal(sdk.boardShows({ search: '', filter: { options: [], value: 'docs' } }, { id: 'x', title: 'x' }), false);
});

test('list with detail: the chosen item is sent as the list\'s `selected` while it is shown', () => {
  const listOf = (block) => block.children[0].children[1];
  assert.deepEqual(listOf(sdk.listDetail(listDetailSpec())).selected, ['a']);
  assert.equal(listOf(sdk.listDetail({ ...listDetailSpec(), search: 'be' })).selected, undefined);   // 'a' is hidden
  assert.equal(listOf(sdk.listDetail({ ...listDetailSpec(), selected: undefined })).selected, undefined);
});

test('list with detail: events reach the typed callbacks', async () => {
  const { view, calls, record } = recorder();
  sdk.routeListDetail(view, {}, { onSelect: record('select'), onOpen: record('open'), onSearch: record('search'), onDetailAction: record('action') });
  await event(view, { action: 'listDetail.select', block: 'listDetail.list', selected: ['b'] });
  await event(view, { action: 'listDetail.select', block: 'listDetail.list', selected: [] });
  await event(view, { action: 'listDetail.open', block: 'a' });
  await event(view, { action: 'listDetail.search', value: 'be' });
  await event(view, { action: 'listDetail.action', block: 'listDetail.action.open' });
  assert.deepEqual(calls, [['select', 'b'], ['select', undefined], ['open', 'a'], ['search', 'be'], ['action', 'open']]);
});

test('table: sorting, selection, toolbar, search, open, delete', async () => {
  const { view, calls, record } = recorder();
  view.update({ blocks: sdk.tableWithToolbar({ ...tableSpec(), selected: [] }) });
  sdk.routeTable(view, {}, { onSort: record('sort'), onSelect: record('select'), onToolbar: record('tool'), onSearch: record('search'), onOpen: record('open'), onDelete: record('delete') });
  await event(view, { action: 'table.sort', block: 'table.table', column: 'size', ascending: true });
  await event(view, { action: 'table.select', block: 'table.table', selected: ['r1', 'r3'] });
  await event(view, { action: 'table.tool', block: 'table.tool.delete' });
  await event(view, { action: 'table.search', value: 'a' });
  await event(view, { action: 'table.open', block: 'r1' });
  await event(view, { action: 'table.delete', block: 'r3' });
  assert.deepEqual(calls, [['sort', 'size', true], ['select', ['r1', 'r3']], ['tool', 'delete', ['r1', 'r3']], ['search', 'a'], ['open', 'r1'], ['delete', 'r3']]);
});

test('table: only shown rows count as selected, and they are sent as the table\'s `selected`', () => {
  const table = (spec) => sdk.tableWithToolbar({ ...tableSpec(), ...spec });
  const both = table({ selected: ['r1', 'r2'] });
  assert.deepEqual(both.children[1].selected, ['r1', 'r2']);
  const searched = table({ selected: ['r1', 'r2'], search: 'a' });          // only r1 ('a') is shown
  assert.deepEqual(searched.children[1].children.map((item) => item.id), ['r1']);
  assert.deepEqual(searched.children[1].selected, ['r1']);
  assert.equal(searched.children[0].children.find((block) => block.id === 'table.count').text, '1 selected');
  const hidden = table({ selected: ['r2'], search: 'a' });
  assert.equal(hidden.children[1].selected, undefined);
  assert.equal(hidden.children[0].children.find((block) => block.id === 'table.count'), undefined);
  assert.equal(hidden.children[0].children.find((block) => block.id === 'table.tool.delete').enabled, false);
});

test('table: onToolbar reports only rows still described, and a reopened view starts from the described selection', async () => {
  const { view, calls, record } = recorder();
  const draw = (spec) => view.show({ blocks: sdk.tableWithToolbar({ ...tableSpec(), ...spec }) });
  sdk.routeTable(view, {}, { onToolbar: record('tool') });
  await view.receive('view/opened', { view: 'v' });
  draw({ selected: [] });
  await event(view, { action: 'table.select', block: 'table.table', selected: ['r1', 'r2'] });
  draw({ selected: ['r1', 'r2'], search: 'a' });                          // r2 is hidden: Vektor unselects it, silently
  await event(view, { action: 'table.tool', block: 'table.tool.delete' });
  await view.receive('view/closed', { view: 'v' });
  await view.receive('view/opened', { view: 'v' });
  draw({ selected: [] });                                                 // Vektor starts with nothing selected
  await event(view, { action: 'table.tool', block: 'table.tool.add' });
  await view.receive('view/closed', { view: 'v' });
  await view.receive('view/opened', { view: 'v' });
  draw({ selected: ['r3'] });                                             // …or with the described `selected`
  await event(view, { action: 'table.tool', block: 'table.tool.add' });
  assert.deepEqual(calls, [['tool', 'delete', ['r1']], ['tool', 'add', []], ['tool', 'add', ['r3']]]);
});

test('table: sortRows orders numbers as numbers and text naturally', () => {
  const columns = [{ id: 'n', title: 'N' }, { id: 's', title: 'S' }];
  const rows = [{ id: 'a', cells: ['file10', 10] }, { id: 'b', cells: ['file2', 9] }, { id: 'c', cells: ['file1', 100] }];
  assert.deepEqual(sdk.sortRows(rows, columns, { column: 's', ascending: true }).map((r) => r.id), ['b', 'a', 'c']);
  assert.deepEqual(sdk.sortRows(rows, columns, { column: 'n', ascending: true }).map((r) => r.id), ['c', 'b', 'a']);
  assert.deepEqual(sdk.sortRows(rows, columns, { column: 'n', ascending: false }).map((r) => r.id), ['a', 'b', 'c']);
  assert.deepEqual(sdk.sortRows(rows, columns).map((r) => r.id), ['a', 'b', 'c']);
});

test('table: a toolbar button that needs a selection is disabled without one', () => {
  const none = sdk.tableWithToolbar({ ...tableSpec(), selected: [] });
  const buttons = none.children[0].children.filter((b) => b.type === 'button');
  assert.deepEqual(buttons.map((b) => b.enabled), [false, undefined]);
});

test('settings form: changes and buttons reach the callbacks with the field key', async () => {
  const { view, calls, record } = recorder();
  sdk.routeSettingsForm(view, {}, { onChange: record('change'), onButton: record('button') });
  await event(view, { action: 'settings.change', block: 'settings.field.name', value: 'Z' });
  await event(view, { action: 'settings.change', block: 'settings.field.sync', value: false });
  await event(view, { action: 'settings.change', block: 'settings.field.tags', value: ['a', 'b'] });
  await event(view, { action: 'settings.press', block: 'settings.field.reset' });
  assert.deepEqual(calls, [['change', 'name', 'Z'], ['change', 'sync', false], ['change', 'tags', ['a', 'b']], ['button', 'reset']]);
});

test('settings form: text typed against an older revision is still delivered', async () => {
  const { view, calls, record } = recorder();
  view.update({ blocks: sdk.settingsForm(formSpec()) });
  view.update({ blocks: sdk.settingsForm(formSpec()) });
  sdk.routeSettingsForm(view, {}, { onChange: record('change') });
  await event(view, { action: 'settings.change', block: 'settings.field.name', value: 'Za', revision: 1 });
  assert.equal(calls.length, 1);
});

test('card list: the cards are the items of a list (only a collection\'s items get Return and a double-click), spaced, nothing selected', () => {
  const block = sdk.cardList(cardsSpec());
  assert.equal(block.type, 'list');
  assert.equal(block.id, 'cards');
  assert.equal(block.selection, 'none');
  assert.equal(block.spacing, 8);
  assert.deepEqual(block.children.map((child) => [child.type, child.id, child.action]), [['card', 'k1', 'cards.open'], ['card', 'k2', undefined]]);
});

test('card list: a button key with a dot (or none) is refused while drawing, since the card id may have dots', () => {
  for (const key of ['open.url', '']) {
    assert.throws(() => sdk.cardList({ cards: [{ id: 'k1', title: 'T', buttons: [{ key, symbol: 'safari' }] }] }),
      (error) => error instanceof sdk.PluginError && error.message === `The button key “${key}” of the card “k1” must be a word without dots.`);
  }
});

test('card list: open, buttons (card ids may contain dots) and menus', async () => {
  const { view, calls, record } = recorder();
  sdk.routeCardList(view, { menuKeys: ['rename', 'delete'] }, { onOpen: record('open'), onButton: record('button'), onMenu: record('menu') });
  await event(view, { action: 'cards.open', block: 'k1' });
  await event(view, { action: 'cards.button', block: 'cards.button.stop.k1' });
  await event(view, { action: 'cards.button', block: 'cards.button.copy.my.card.1' });
  await event(view, { action: 'cards.menu.delete', block: 'k1' });
  await event(view, { action: 'cards.menu.rename', block: 'cards.more.k2' });
  assert.deepEqual(calls, [['open', 'k1'], ['button', 'k1', 'stop'], ['button', 'my.card.1', 'copy'], ['menu', 'k1', 'delete'], ['menu', 'k2', 'rename']]);
});

test('events of another layout, or with no block, are ignored', async () => {
  const { view, calls, record } = recorder();
  sdk.routeBoard(view, {}, { onAdd: record('add'), onOpen: record('open'), onMove: record('move'), onColumnAction: record('column') });
  await event(view, { action: 'board.add', block: 'other.add.todo' });
  await event(view, { action: 'board.open' });
  await event(view, { action: 'board.move', item: 'c1', target: 'elsewhere', index: 0 });
  await event(view, { action: 'board.column.rename', block: 'x' });
  assert.deepEqual(calls, []);
});

test('layouts are exported flat and as a namespace', () => {
  for (const name of ['board', 'listDetail', 'tableWithToolbar', 'settingsForm', 'cardList']) {
    assert.equal(typeof sdk[name], 'function', name);
    assert.equal(sdk.layouts[name], sdk[name]);
  }
});
