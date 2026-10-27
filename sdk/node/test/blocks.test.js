'use strict';
// Every builder against the JSON the reference documents (docs/reference.md, "Block views" and "Web views").
const test = require('node:test');
const assert = require('node:assert/strict');
const { blocks: b, validateBlocks, ROLES, ROLE_TITLES } = require('../dist');

test('the board example of the reference, built with the builders', () => {
  // docs/reference.md, "Block views": the first example, verbatim.
  const reference = {
    type: 'hstack', id: 'board', children: [
      { type: 'panel', id: 'col-todo', title: 'To do', role: 'label6', children: [
        { type: 'list', id: 'todo', group: 'cards', move: 'move', children: [
          { type: 'card', id: 'c1', title: 'Write the spec', edit: 'rename', delete: 'remove',
            children: [{ type: 'badge', id: 'c1-tag', text: 'docs', role: 'label3' }] }] }] },
      { type: 'panel', id: 'col-done', title: 'Done', role: 'label4', children: [
        { type: 'list', id: 'done', group: 'cards', move: 'move', children: [] }] }] };
  const built = b.hstack([
    b.panel([
      b.list('todo', [
        b.card([b.badge('docs', { id: 'c1-tag', role: 'label3' })], { id: 'c1', title: 'Write the spec', edit: 'rename', delete: 'remove' }),
      ], { group: 'cards', move: 'move' }),
    ], { id: 'col-todo', title: 'To do', role: 'label6' }),
    b.panel([b.list('done', [], { group: 'cards', move: 'move' })], { id: 'col-done', title: 'Done', role: 'label4' }),
  ], { id: 'board' });
  assert.deepEqual(built, reference);
  assert.deepEqual(require('../../fixtures/blocks.json')['reference: board'], reference);
  assert.deepEqual(validateBlocks(built), { problems: [], warnings: [] });
});

test('the web block example of the reference', () => {
  const reference = { type: 'vstack', id: 'root', children: [
    { type: 'hstack', id: 'bar', children: [{ type: 'button', id: 'clear', title: 'Clear', action: 'clear' }] },
    { type: 'web', id: 'canvas', entry: 'web/canvas.html' }] };
  const built = b.vstack([
    b.hstack([b.button({ id: 'clear', title: 'Clear', action: 'clear' })], { id: 'bar' }),
    b.web('canvas', 'web/canvas.html'),
  ], { id: 'root' });
  assert.deepEqual(built, reference);
  assert.deepEqual(require('../../fixtures/blocks.json')['reference: web block'], reference);
});

// One line per block type of the reference's table: the builder call, and the JSON it must give.
const cases = [
  ['vstack', b.vstack([], { spacing: 4 }), { type: 'vstack', spacing: 4, children: [] }],
  ['hstack', b.hstack([b.spacer()], { spacing: 8 }), { type: 'hstack', spacing: 8, children: [{ type: 'spacer' }] }],
  ['spacer', b.spacer(), { type: 'spacer' }],
  ['divider', b.divider(), { type: 'divider' }],
  ['grid', b.grid([], { columns: 3, minWidth: 120, spacing: 6 }), { type: 'grid', columns: 3, minWidth: 120, spacing: 6, children: [] }],
  ['scroll', b.scroll([], { axis: 'both' }), { type: 'scroll', axis: 'both', children: [] }],
  ['split', b.split('s', b.text('a'), b.text('b'), { axis: 'horizontal', fraction: 0.3, height: 300 }),
    { type: 'split', id: 's', axis: 'horizontal', fraction: 0.3, height: 300, children: [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }] }],
  ['section', b.section('sec', [], { title: 'Open', collapsible: true, collapsed: false, count: 3 }),
    { type: 'section', id: 'sec', title: 'Open', collapsible: true, collapsed: false, count: 3, children: [] }],
  ['tabs/tab', b.tabs('t', [b.tab('one', 'One', [], { symbol: 'star' })], { style: 'segmented', action: 'tab' }),
    { type: 'tabs', id: 't', style: 'segmented', action: 'tab', children: [{ type: 'tab', id: 'one', title: 'One', symbol: 'star', children: [] }] }],
  ['card', b.card([], { title: 'T', symbol: 'doc', role: 'accent', badge: { text: 'new', role: 'positive' } }),
    { type: 'card', title: 'T', symbol: 'doc', role: 'accent', badge: { text: 'new', role: 'positive' }, children: [] }],
  ['panel', b.panel([], { title: 'P', role: 'label2' }), { type: 'panel', title: 'P', role: 'label2', children: [] }],
  ['list', b.list('l', [], { selection: 'multiple', select: 'sel', group: 'g', move: 'mv', placeholder: 'None', spacing: 6 }),
    { type: 'list', id: 'l', selection: 'multiple', select: 'sel', group: 'g', move: 'mv', placeholder: 'None', spacing: 6, children: [] }],
  ['row', b.row('r', { title: 'T', subtitle: 'S', symbol: 'doc', check: 'chk', checked: true, badge: { text: 'b' },
      buttons: [{ title: 'Go', symbol: 'play', action: 'go', enabled: true }], menu: [{ title: 'Del', action: 'del', destructive: true }, { separator: true }], dimmed: true }),
    { type: 'row', id: 'r', title: 'T', subtitle: 'S', symbol: 'doc', check: 'chk', checked: true, badge: { text: 'b' },
      buttons: [{ title: 'Go', symbol: 'play', action: 'go', enabled: true }], menu: [{ title: 'Del', action: 'del', destructive: true }, { separator: true }], dimmed: true }],
  ['table', b.table('tb', [{ id: 'name', title: 'Name', width: 200, sortable: true }], [b.row('r1', { cells: ['a', 1] })],
      { sorted: { column: 'name', ascending: false }, sort: 'sort' }),
    { type: 'table', id: 'tb', columns: [{ id: 'name', title: 'Name', width: 200, sortable: true }], sorted: { column: 'name', ascending: false }, sort: 'sort',
      children: [{ type: 'row', id: 'r1', cells: ['a', 1] }] }],
  ['tree/node', b.tree('tr', [b.node('n1', 'Root', [b.node('n2', 'Leaf')], { symbol: 'folder', expanded: true })]),
    { type: 'tree', id: 'tr', children: [{ type: 'node', id: 'n1', title: 'Root', symbol: 'folder', expanded: true, children: [{ type: 'node', id: 'n2', title: 'Leaf', children: [] }] }] }],
  ['text', b.text('Hi', { style: 'mono', selectable: true, link: 'https://example.com', role: 'neutral', lineLimit: 2 }),
    { type: 'text', text: 'Hi', style: 'mono', selectable: true, link: 'https://example.com', role: 'neutral', lineLimit: 2 }],
  ['symbol', b.symbol('star', { role: 'warning', label: 'Starred' }), { type: 'symbol', symbol: 'star', role: 'warning', label: 'Starred' }],
  ['badge', b.badge('docs', { role: 'label3', label: 'Tag docs' }), { type: 'badge', text: 'docs', role: 'label3', label: 'Tag docs' }],
  ['count', b.count(12, { role: 'accent' }), { type: 'count', count: 12, role: 'accent' }],
  ['markdown', b.markdown('# Hi'), { type: 'markdown', markdown: '# Hi' }],
  ['empty', b.empty('Nothing', { title: 'Empty', symbol: 'tray', role: 'neutral', link: 'https://example.com' }),
    { type: 'empty', text: 'Nothing', title: 'Empty', symbol: 'tray', role: 'neutral', link: 'https://example.com' }],
  ['banner', b.banner('Note', { role: 'warning' }), { type: 'banner', text: 'Note', role: 'warning' }],
  ['status', b.status('Synced', { symbol: 'checkmark', role: 'positive' }), { type: 'status', text: 'Synced', symbol: 'checkmark', role: 'positive' }],
  ['diff', b.diff('a', 'b', { leftTitle: 'Mine', rightTitle: 'Theirs', keepLeft: 'keepMine', keepRight: 'keepTheirs' }),
    { type: 'diff', left: 'a', right: 'b', leftTitle: 'Mine', rightTitle: 'Theirs', keepLeft: 'keepMine', keepRight: 'keepTheirs' }],
  ['button', b.button({ id: 'sync', title: 'Sync', symbol: 'arrow.triangle.2.circlepath', action: 'sync', style: 'icon', tooltip: 'Sync now', busy: true, enabled: false }),
    { type: 'button', id: 'sync', title: 'Sync', symbol: 'arrow.triangle.2.circlepath', action: 'sync', style: 'icon', tooltip: 'Sync now', busy: true, enabled: false }],
  ['textField', b.textField('f', 'set', { value: 'x', placeholder: 'Type', title: 'Name', error: 'Too short' }),
    { type: 'textField', id: 'f', action: 'set', value: 'x', placeholder: 'Type', title: 'Name', error: 'Too short' }],
  ['searchField', b.searchField('q', 'search', { placeholder: 'Filter' }), { type: 'searchField', id: 'q', action: 'search', placeholder: 'Filter' }],
  ['textArea', b.textArea('notes', 'save', { value: 'a\nb' }), { type: 'textArea', id: 'notes', action: 'save', value: 'a\nb' }],
  ['toggle', b.toggle('on', 'flip', { value: true, title: 'On' }), { type: 'toggle', id: 'on', action: 'flip', value: true, title: 'On' }],
  ['checkbox', b.checkbox('cb', 'tick', { value: false }), { type: 'checkbox', id: 'cb', action: 'tick', value: false }],
  ['picker', b.picker('p', 'pick', [{ value: 'a', title: 'A', symbol: 'a.circle' }], { value: 'a', style: 'segmented' }),
    { type: 'picker', id: 'p', action: 'pick', options: [{ value: 'a', title: 'A', symbol: 'a.circle' }], value: 'a', style: 'segmented' }],
  ['stepper', b.stepper('st', 'step', { value: 2, min: 0, max: 10, step: 2 }), { type: 'stepper', id: 'st', action: 'step', value: 2, min: 0, max: 10, step: 2 }],
  ['menu', b.menu([{ title: 'Rename', action: 'rename', symbol: 'pencil' }], { title: 'More' }),
    { type: 'menu', menu: [{ title: 'Rename', action: 'rename', symbol: 'pencil' }], title: 'More' }],
  ['datePicker', b.datePicker('due', 'due', { value: '2026-10-23' }), { type: 'datePicker', id: 'due', action: 'due', value: '2026-10-23' }],
  ['tagPicker', b.tagPicker('tags', 'tags', { tags: ['a'], suggestions: ['b'] }), { type: 'tagPicker', id: 'tags', action: 'tags', tags: ['a'], suggestions: ['b'] }],
  ['rolePicker', b.rolePicker('colour', 'colour', { value: 'label1', roles: ['label1', 'label4'] }),
    { type: 'rolePicker', id: 'colour', action: 'colour', value: 'label1', options: [{ value: 'label1', title: 'Red' }, { value: 'label4', title: 'Green' }] }],
  ['spinner', b.spinner({ text: 'Loading' }), { type: 'spinner', text: 'Loading' }],
  ['progress', b.progress({ progress: 0.5, title: 'Uploading' }), { type: 'progress', progress: 0.5, title: 'Uploading' }],
  ['fileList', b.fileList(['/tmp/a.txt', '/tmp/folder/']), { type: 'fileList', files: ['/tmp/a.txt', '/tmp/folder/'] }],
  ['web', b.web('page', 'web/index.html', { height: 300 }), { type: 'web', id: 'page', entry: 'web/index.html', height: 300 }],
];

for (const [name, built, expected] of cases) {
  test(`builder: ${name}`, () => assert.deepEqual(built, expected));
}

test('sdk/fixtures/blocks.json (which the Swift SDK’s tests build against) holds exactly these expectations', () => {
  const fixtures = require('../../fixtures/blocks.json');
  for (const [name, , expected] of cases) assert.deepEqual(fixtures[name], expected, name);
  assert.equal(Object.keys(fixtures).length, cases.length + 3);
});

test('the widths example of the reference, built with the builders', () => {
  // docs/reference.md, "Widths": a board whose columns fill the pane and scroll once they no longer fit.
  const built = b.scroll([
    b.panel([], { id: 'col-todo', title: 'To do', grow: true, minWidth: 240 }),
    b.panel([], { id: 'col-done', title: 'Done', grow: true, minWidth: 240 }),
  ], { axis: 'horizontal', spacing: 12 });
  assert.deepEqual(built, require('../../fixtures/blocks.json')['reference: widths']);
  assert.deepEqual(validateBlocks(built), { problems: [], warnings: [] });
});

test('widths: width, minWidth, maxWidth and grow on any block; out of 20…4000 a warning, never a refusal', () => {
  const card = b.card([], { id: 'c', width: 300, minWidth: 220, maxWidth: 4000, grow: true });
  assert.deepEqual(card, { type: 'card', id: 'c', width: 300, minWidth: 220, maxWidth: 4000, grow: true, children: [] });
  assert.deepEqual(validateBlocks(card), { problems: [], warnings: [] });
  assert.deepEqual(validateBlocks(b.hstack([b.panel([], { id: 'a', width: 20 }), b.panel([], { id: 'b', maxWidth: 4000 })])), { problems: [], warnings: [] });
  const bad = validateBlocks(b.hstack([
    b.panel([], { id: 'a', width: 5 }), b.panel([], { id: 'b', maxWidth: 9000 }),
    { type: 'panel', id: 'c', minWidth: 'wide' }, { type: 'panel', id: 'd', grow: 'yes' }]));
  assert.deepEqual(bad.problems, []);
  assert.equal(bad.warnings.length, 4);
  assert.match(bad.warnings[0], /“a”.*“width”.*20 to 4000/);
  assert.match(bad.warnings[1], /“b”.*“maxWidth”/);
  assert.match(bad.warnings[2], /“c”.*“minWidth”/);
  assert.match(bad.warnings[3], /“d”.*“grow”/);
  assert.deepEqual(validateBlocks(b.grid([], { id: 'g', minWidth: 160 })).warnings, [], 'a grid’s minWidth is its tile minimum, in the same range');
});

test('every block type of the reference has a builder case above', () => {
  const covered = new Set(cases.flatMap(([, built]) => {
    const types = [];
    const walk = (block) => { types.push(block.type); (block.children || []).forEach(walk); };
    walk(built);
    return types;
  }));
  const reference = ['vstack', 'hstack', 'spacer', 'divider', 'grid', 'scroll', 'split', 'section', 'tabs', 'tab', 'card', 'panel', 'list', 'row',
    'table', 'tree', 'node', 'text', 'symbol', 'badge', 'count', 'markdown', 'empty', 'banner', 'status', 'diff', 'button', 'textField',
    'searchField', 'textArea', 'toggle', 'checkbox', 'picker', 'stepper', 'menu', 'datePicker', 'tagPicker', 'rolePicker', 'spinner', 'progress',
    'fileList', 'web'];
  for (const type of reference) assert.ok(covered.has(type), `no case for ${type}`);
});

test('fields on any block: menu, tooltip, label, drag, drop, fileDrop, revealOnHover, enabled, error', () => {
  const common = {
    menu: [{ title: 'Open', action: 'open' }], tooltip: 'Tip', label: 'Spoken', drag: 'cards',
    drop: { action: 'dropped', accepts: ['cards'] }, fileDrop: { action: 'files', accepts: 'files', extensions: ['md'] },
    revealOnHover: true, enabled: false, error: 'Wrong',
  };
  assert.deepEqual(b.card([], { id: 'c', ...common }), { type: 'card', id: 'c', ...common, children: [] });
});

test('nothing undefined reaches the JSON', () => {
  assert.equal(JSON.stringify(b.text('x', { style: undefined })), '{"type":"text","text":"x"}');
});

test('colour roles: the thirteen of the reference, each with a name', () => {
  assert.deepEqual([...ROLES], ['accent', 'positive', 'warning', 'danger', 'neutral', 'label1', 'label2', 'label3', 'label4', 'label5', 'label6', 'label7', 'label8']);
  assert.deepEqual(ROLES.map((role) => ROLE_TITLES[role]).slice(5), ['Red', 'Orange', 'Yellow', 'Green', 'Teal', 'Blue', 'Purple', 'Pink']);
});

test('validateBlocks refuses what Vektor refuses, in its words', () => {
  const problem = (tree) => validateBlocks(tree).problems[0];
  assert.match(problem({ id: 'x' }), /needs a “type”/);
  assert.match(problem(b.vstack([b.text('a', { id: 'x' }), b.text('b', { id: 'x' })])), /“x” is listed twice/);
  assert.match(problem(b.list('l', [b.row(undefined, { title: 'no id' })])), /every item of “l” needs an “id”/);
  assert.match(problem({ type: 'textField', action: 'a' }), /a “textField” block needs an “id”/);
  assert.match(problem(b.button({ title: 'Nothing' })), /needs an “action”/);
  assert.match(problem({ type: 'picker', id: 'p', action: 'a' }), /needs “options”/);
  assert.match(problem({ type: 'table', id: 't' }), /needs “columns”/);
  assert.match(problem({ type: 'web', id: 'w' }), /needs an “entry”/);
  assert.match(problem(b.tabs('t', [b.text('not a tab')])), /must be a “tab”/);
  assert.match(problem({ type: 'menu', menu: [{ title: 'no action' }] }), /needs a “title” and an “action”/);
  // Vektor trims required strings: empty or blank is missing.
  assert.match(problem(b.picker('p', 'a', [{ value: '', title: 'All' }])), /every option of “p” needs a “value” and a “title”/);
  assert.match(problem(b.picker('p', 'a', [{ value: 'x', title: '  ' }])), /every option of “p” needs a “value” and a “title”/);
  assert.match(problem(b.table('t', [{ id: '', title: 'Name' }], [])), /every column of “t” needs an “id” and a “title”/);
  assert.match(problem(b.table('t', [{ id: 'name', title: ' ' }], [])), /every column of “t” needs an “id” and a “title”/);
  assert.match(problem(b.menu([{ title: '', action: 'a' }])), /needs a “title” and an “action”/);
  assert.match(problem(b.menu([{ title: 'Go', action: ' ' }])), /needs a “title” and an “action”/);
  assert.match(problem(b.button({ title: 'Blank', action: '' })), /needs an “action”/);
  assert.match(problem(b.web('w', ' ')), /needs an “entry”/);
  assert.match(problem({ type: ' ' }), /needs a “type”/);
  assert.match(problem(b.textField(' ', 'a')), /a “textField” block needs an “id”/);
  let deep = b.text('leaf');
  for (let level = 0; level < 70; level++) deep = b.vstack([deep]);
  assert.match(problem(deep), /nested more than 64 deep/);
});

test('validateBlocks warns about colour values and unknown roles, which Vektor ignores', () => {
  const { problems, warnings } = validateBlocks({ type: 'text', text: 'x', color: '#ff0000', role: 'crimson' });
  assert.deepEqual(problems, []);
  assert.equal(warnings.length, 2);
  assert.match(warnings[0], /colour value \(“color”\)/);
  assert.match(warnings[1], /colour role Vektor does not know/);
});

test('a list of blocks is read as a vertical stack', () => {
  assert.deepEqual(validateBlocks([b.text('a'), b.textField('f', 'x')]).problems, []);
  assert.match(validateBlocks([b.text('a'), { type: 'toggle' }]).problems[0], /needs an “id”/);
});
