'use strict';
// The protocol core and the helpers, driven through the test kit's in-memory host.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { PluginError, VektorError, TimeoutError, CancelledError, WorkspaceState, blocks: b } = require('../dist');
const { TestHost } = require('../dist/testkit');

// A plugin folder for the tests: only plugin.json is read in memory.
function folder(manifest = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vektor-sdk-test-'));
  fs.writeFileSync(path.join(dir, 'plugin.json'), JSON.stringify({
    id: 'com.example.sdk-test', name: 'SDK test', api: 2, executable: 'run.js',
    settings: { items: [{ key: 'greeting', kind: 'text', label: 'Greeting', default: 'Hello' }, { key: 'boards', kind: 'place', label: 'Boards' }] },
    contributes: { views: [{ id: 'v', title: 'V', kind: 'blocks' }, { id: 'page', title: 'Page', kind: 'web', entry: 'index.html' }] },
    ...manifest,
  }));
  return dir;
}

async function withHost(setup, options, body) {
  const host = await TestHost.start({ folder: folder(), setup, ...options });
  try { await body(host); } finally { await host.close(); }
}

test('startup: settings with defaults, workspace, data folder; answered with {} and every message carries api', () =>
  withHost((plugin) => {
    plugin.onStartup((params) => plugin.log(`started for ${params.workspace.name} with ${plugin.settings.greeting}`));
  }, { settings: { greeting: 'Ahoj' }, workspace: { id: 'w1', name: 'Work' } }, async (host) => {
    const answer = await host.startup();
    assert.deepEqual(answer, { kind: 'response', id: 1, result: {} });
    await host.waitFor({ method: 'log', match: { 'params.message': 'started for Work with Ahoj' } });
    assert.equal(host.plugin.dataFolder, host.dataFolder);
    assert.ok(host.transcript.every((line) => !line.includes('without “api”')));
  }));

test('the test kit’s refuse() is view/refused, a notification; the plugin resends the whole description', () =>
  withHost((plugin) => {
    const view = plugin.view('v');
    let rows = ['a', 'b'];
    const draw = () => view.show({ blocks: b.list('l', rows.map((id) => b.row(id, { title: id.toUpperCase() }))) });
    view.onOpen(draw);
    view.on('flip', () => { rows = rows.slice().reverse(); draw(); });
  }, {}, async (host) => {
    await host.startup();
    host.openView('v');
    await host.waitFor({ method: 'view/update' });
    host.viewEvent('v', 'flip');
    await host.waitFor({ method: 'view/patch', match: { 'params.revision': 2 } });
    const since = host.received.length;
    const refusal = host.refuse('v', { problem: 'operation 1 cannot apply.' });
    assert.deepEqual(refusal, { view: 'v', kind: 'patch', revision: 1, refusedRevision: 2, problem: 'operation 1 cannot apply.' });
    await host.waitFor({ method: 'view/update', match: { 'params.description.revision': 3, 'params.description.blocks.children.0.id': 'b' } }, { since });
    assert.ok(host.transcript.some((line) => line.includes('"method":"view/refused"') && !line.includes('"id"')), 'sent as a notification');
  }));

test('ping is answered; an unknown request is refused in plain words; a bug becomes a generic message', () =>
  withHost((plugin) => {
    plugin.command('boom', () => { throw new Error('internal detail'); });
    plugin.command('refuse', () => { throw new PluginError('That folder is empty.'); });
  }, {}, async (host) => {
    await host.startup();
    assert.equal((await host.request('ping')).kind, 'response');
    const unknown = await host.request('frobnicate', {});
    assert.deepEqual(unknown.error, { message: 'This plugin does not handle “frobnicate”.' });
    const boom = await host.request('invoke', { command: 'boom', target: {} });
    assert.equal(boom.error.message, 'Something went wrong in the plugin; its Log has the details.');
    assert.ok(host.transcript.some((line) => line.includes('internal detail')), 'the detail goes to stderr');
    const refused = await host.request('invoke', { command: 'refuse', target: {} });
    assert.equal(refused.error.message, 'That folder is empty.');
  }));

test('a command returns a notice, an object, or nothing', () =>
  withHost((plugin) => {
    plugin.command('text', (target) => `${target.items.length} item(s)`);
    plugin.command('object', () => ({ message: 'done' }));
    plugin.command('nothing', () => undefined);
  }, {}, async (host) => {
    await host.startup();
    assert.deepEqual((await host.request('invoke', { command: 'text', target: { items: [{ path: '/a', name: 'a', isFolder: false }] } })).result, { message: '1 item(s)' });
    assert.deepEqual((await host.request('invoke', { command: 'object', target: {} })).result, { message: 'done' });
    assert.deepEqual((await host.request('invoke', { command: 'nothing', target: {} })).result, {});
  }));

test('the plugin’s own requests: ids from 1000, answers, refusals with code and data, autoReply errors', () =>
  withHost((plugin) => {
    plugin.command('ask', async () => {
      const confirmed = await plugin.confirm({ title: 'Sure?', message: 'Really', confirmTitle: 'Yes' });
      try { await plugin.readSecret('token'); } catch (error) { return `${confirmed} ${error instanceof VektorError} ${error.message}`; }
      return 'no error';
    });
  }, { autoReply: { confirm: { confirmed: true }, 'secrets/read': { $error: 'No such secret.' } } }, async (host) => {
    await host.startup();
    const answer = await host.request('invoke', { command: 'ask', target: {} });
    assert.equal(answer.result.message, 'true true No such secret.');
    const requests = host.received.filter((m) => m.kind === 'request');
    assert.deepEqual(requests.map((m) => [m.id, m.method]), [[1000, 'confirm'], [1001, 'secrets/read']]);
  }));

test('a cancelled dialog without `values` (older Vektor) reads as an empty object; a bare storage status gets its defaults', () =>
  withHost((plugin) => {
    plugin.command('ask', async () => {
      const answer = await plugin.showDialog({ title: 'Name', fields: [{ key: 'name', kind: 'text', label: 'Name' }] });
      const status = await plugin.storage('pl-aaaaaaaaaaaaaaaaaaaaaaaaaa').status();
      return `${answer.result} ${JSON.stringify(answer.values)} ${status.state} ${JSON.stringify([status.label, status.remote, status.writes, status.conditional])}`;
    });
  }, { autoReply: { 'dialog/show': { result: 'cancel' }, 'storage/status': { state: 'missing' } } }, async (host) => {
    await host.startup();
    const answer = await host.request('invoke', { command: 'ask', target: {} });
    assert.equal(answer.result?.message, 'cancel {} missing ["",false,"",""]', JSON.stringify(answer));
  }));

test('a request of the plugin times out with plain words', async () => {
  const { Plugin } = require('../dist');
  const plugin = new Plugin({ transport: { write() {}, onData() {}, onEnd() {}, exit() {} }, requestTimeout: 0.05 });
  await assert.rejects(plugin.request('openURL', { url: 'https://example.com' }), (error) =>
    error instanceof TimeoutError && error.message === 'Vektor did not answer “openURL” within 0.05 seconds.');
  assert.equal(plugin.pendingRequests, 0);
});

test('$/cancel aborts the handler of that request', () =>
  withHost((plugin) => {
    plugin.command('slow', async (target, context) => {
      await new Promise((resolve) => context.signal.addEventListener('abort', resolve));
      context.throwIfCancelled();
    });
  }, {}, async (host) => {
    await host.startup();
    const since = host.received.length;
    const id = host.send('invoke', { command: 'slow', target: {} });
    host.send('$/cancel', { id });
    const answer = await host.waitFor({ kind: 'failure' }, { since, requestID: id });
    assert.equal(answer.error.message, 'Cancelled.');
  }));

test('shutdown: answered first, handlers run, the plugin exits; a slow handler is cut at the grace period', () =>
  withHost((plugin) => {
    plugin.onShutdown(() => new Promise(() => {})); // never ends
  }, {}, async (host) => {
    await host.startup();
    host.plugin.shutdownGrace = 100;
    const started = Date.now();
    await host.shutdown();
    assert.equal(host.exitCode, 0);
    assert.ok(Date.now() - started < 2000);
  }));

test('end of input: shutdown handlers run and the plugin leaves', () =>
  withHost((plugin) => {
    plugin.onShutdown((reason) => plugin.log(`stopping: ${reason}`));
  }, {}, async (host) => {
    await host.startup();
    host.plugin.stop('endOfInput', false);
    assert.ok(await host.waitForExit(2));
  }));

test('views: opened → described, events routed, revision handed back; patches on change', () =>
  withHost((plugin) => {
    const items = [];
    const view = plugin.view('v');
    const show = () => view.show({ header: { title: 'Items' }, blocks: b.list('l', items.map((t, i) => b.row(`r${i}`, { title: t }))) });
    view.onOpen(show);
    view.on('add', (event) => { items.push(event.value); show(); });
  }, {}, async (host) => {
    await host.startup();
    host.openView('v');
    const update = await host.waitFor({ method: 'view/update' });
    assert.equal(update.params.description.revision, 1);
    host.viewEvent('v', 'add', { block: 'f', value: 'one' });
    const patch = await host.waitFor({ method: 'view/patch' });
    assert.deepEqual(patch.params, { view: 'v', revision: 2, ops: [{ op: 'insert', parent: 'l', index: 0, block: { type: 'row', id: 'r0', title: 'one' } }] });
  }));

test('workspace: workspace/changed updates plugin.workspace, runs handlers and resends sidebar items', () =>
  withHost((plugin) => {
    plugin.sidebar('boards').provide((workspace) => [{ id: `b-${workspace ? workspace.id : 'none'}`, title: 'Board', badge: 3 }]);
    plugin.onWorkspaceChanged((workspace) => plugin.log(`now in ${workspace.name}`));
  }, { workspace: { id: 'w1', name: 'One' } }, async (host) => {
    await host.startup();
    await host.waitFor({ method: 'sidebar/items', match: { 'params.entry': 'boards', 'params.items.0.id': 'b-w1', 'params.items.0.badge': 3 } });
    const since = host.received.length;
    host.send('workspace/changed', { id: 'w2', name: 'Two' });
    await host.waitFor({ method: 'log', match: { 'params.message': 'now in Two' } }, { since });
    await host.waitFor({ method: 'sidebar/items', match: { 'params.items.0.id': 'b-w2' } }, { since });
    assert.deepEqual(host.plugin.workspace, { id: 'w2', name: 'Two' });
  }));

test('workspace: an API 1 style switch (settingsChanged with another workspace) is a workspace change too', () =>
  withHost((plugin) => {
    plugin.onWorkspaceChanged((workspace) => plugin.log(`now in ${workspace.name}`));
  }, { workspace: { id: 'w1', name: 'One' } }, async (host) => {
    await host.startup();
    host.send('settingsChanged', { settings: { greeting: 'Hi' }, workspace: { id: 'w3', name: 'Three' } });
    await host.waitFor({ method: 'log', match: { 'params.message': 'now in Three' } });
    assert.equal(host.plugin.settings.greeting, 'Hi');
  }));

test('sidebar items: refused before sending when Vektor would refuse them; a sidebarItem menu gets the item', () =>
  withHost((plugin) => {
    plugin.sidebar('boards').onMenu('rename', (item) => `renaming ${item}`);
    plugin.command('bad', () => { plugin.sidebar('boards').set([{ id: 'a', title: 'A' }, { id: 'a', title: 'again' }]); });
  }, {}, async (host) => {
    await host.startup();
    assert.equal((await host.request('invoke', { command: 'rename', target: { menu: 'sidebarItem', entry: 'boards', item: 'b7' } })).result.message, 'renaming b7');
    assert.match((await host.request('invoke', { command: 'bad', target: {} })).error.message, /listed twice/);
  }));

test('WorkspaceState keeps one value per workspace, on disk', () =>
  withHost(() => {}, { workspace: { id: 'w1', name: 'One' } }, async (host) => {
    await host.startup();
    const state = new WorkspaceState(host.plugin, 'opened', { board: null });
    state.current.board = 'b1';
    state.save();
    host.plugin.workspace = { id: 'w2', name: 'Two' };
    assert.deepEqual(state.current, { board: null });
    const again = new WorkspaceState(host.plugin, 'opened', { board: null });
    assert.equal(again.get({ id: 'w1', name: 'One' }).board, 'b1');
    assert.ok(fs.existsSync(path.join(host.dataFolder, 'opened.workspaces.json')));
  }));

test('web bridge: messages routed by type, requests answered with reply, posts to a block', () =>
  withHost((plugin) => {
    let strokes = [];
    plugin.web('page').on('load', () => ({ strokes }));
    plugin.web('page').on('save', (message) => { strokes = message.strokes; });
    plugin.web('page').on('fail', () => { throw new PluginError('Nothing to undo.'); });
  }, {}, async (host) => {
    await host.startup();
    host.webMessage('page', { type: 'save', strokes: [1, 2] });
    host.webMessage('page', { type: 'load', requestId: 'r1' }, 'canvas');
    const reply = await host.waitFor({ method: 'web/post', match: { 'params.message.replyTo': 'r1' } });
    assert.deepEqual(reply.params, { view: 'page', block: 'canvas', message: { type: 'reply', replyTo: 'r1', result: { strokes: [1, 2] } } });
    host.webMessage('page', { type: 'fail', requestId: 'r2' });
    const refused = await host.waitFor({ method: 'web/post', match: { 'params.message.replyTo': 'r2' } });
    assert.equal(refused.params.message.error, 'Nothing to undo.');
    host.webMessage('page', { type: 'unknown', requestId: 'r3' });
    await host.waitFor({ method: 'web/post', match: { 'params.message.replyTo': 'r3', 'params.message.error': { contains: 'does not handle' } } });
  }));

test('a message with an id is answered even for a method Vektor sends as a notification', () =>
  withHost(() => {}, {}, async (host) => {
    await host.startup();
    assert.equal((await host.request('view/event', { view: 'v', action: 'x' })).kind, 'response');
  }));

test('stdout carries only messages: a plugin process writes nothing else', async () => {
  // Spawned for real: the SDK's own diagnostics must go to stderr.
  const dir = folder({ executable: 'run.js' });
  fs.writeFileSync(path.join(dir, 'run.js'), `#!${process.execPath}\nconst { Plugin } = require(${JSON.stringify(path.resolve(__dirname, '../dist'))});\n` +
    `const plugin = new Plugin(); plugin.command('x', () => { throw new Error('boom'); }); plugin.start();\n`);
  fs.chmodSync(path.join(dir, 'run.js'), 0o755);
  const host = await TestHost.start({ folder: dir, spawn: true });
  try {
    await host.startup();
    const answer = await host.request('invoke', { command: 'x', target: {} });
    assert.equal(answer.kind, 'failure');
    assert.ok(host.transcript.some((line) => line.startsWith('stderr: vektor-sdk: a request handler failed')));
    assert.ok(!host.transcript.some((line) => line.includes('refuse')), host.transcript.join('\n'));
    await host.shutdown();
  } finally {
    await host.close();
  }
});

test('a stray console.log or stdout write goes to stderr, never into the message stream', async () => {
  // Authors write console.log out of habit; one stray line on stdout would end the plugin in Vektor.
  const dir = folder({ executable: 'run.js' });
  fs.writeFileSync(path.join(dir, 'run.js'), `#!${process.execPath}\nconst { Plugin } = require(${JSON.stringify(path.resolve(__dirname, '../dist'))});\n` +
    `const plugin = new Plugin(); plugin.command('x', () => { console.log('stray line'); process.stdout.write('raw write'); return 'done'; }); plugin.start();\n`);
  fs.chmodSync(path.join(dir, 'run.js'), 0o755);
  const host = await TestHost.start({ folder: dir, spawn: true });
  try {
    await host.startup();
    const answer = await host.request('invoke', { command: 'x', target: {} });
    assert.deepEqual(answer.result, { message: 'done' }, host.transcript.join('\n'));
    const ping = await host.request('ping', {});
    assert.equal(ping.kind, 'response', host.transcript.join('\n'));
    assert.ok(host.transcript.some((line) => line.startsWith('stderr:') && line.includes('stray line')), host.transcript.join('\n'));
    await host.shutdown();
  } finally {
    await host.close();
  }
});

test('errors are PluginErrors with plain words', () => {
  assert.ok(new CancelledError() instanceof PluginError);
  assert.equal(new CancelledError().message, 'Cancelled.');
});
