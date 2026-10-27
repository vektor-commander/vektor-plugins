'use strict';
// The page side of the web bridge (sdk/web/vektor-bridge.js) in a stand-in page, against the plugin side (WebBridge) in the
// test host; and the starter stylesheet uses only the CSS properties the reference documents.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { TestHost } = require('../dist/testkit');

const web = path.resolve(__dirname, '../../web');

// A page: `window` with an event target, and `vektor` as Vektor defines it.
function page(post) {
  const listeners = {};
  const window = {
    vektor: post ? { post } : undefined,
    addEventListener: (type, fn) => (listeners[type] = listeners[type] || []).push(fn),
    dispatch: (type, detail) => (listeners[type] || []).forEach((fn) => fn({ detail })),
  };
  const context = vm.createContext({ window, console, setTimeout, clearTimeout, Promise, JSON, Math, Object, TextEncoder, Error, String,
    getComputedStyle: () => ({ getPropertyValue: (name) => (name === '--vektor-role-label3-mark' ? ' #c9a227 ' : name === '--vektor-theme-light' ? '1' : '') }),
    document: { documentElement: {} } });
  vm.runInContext(fs.readFileSync(path.join(web, 'vektor-bridge.js'), 'utf8'), context);
  return { bridge: window.VektorBridge, window };
}

test('page ↔ plugin: a request answered by the plugin side, a push routed by type', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vektor-sdk-web-'));
  fs.writeFileSync(path.join(dir, 'plugin.json'), JSON.stringify({ id: 'com.example.web', name: 'W', api: 2, executable: 'x',
    contributes: { views: [{ id: 'page', title: 'P', kind: 'web', entry: 'index.html' }] } }));
  const host = await TestHost.start({ folder: dir, setup: (plugin) => {
    plugin.web('page').on('load', (message) => ({ strokes: [message.which] }));
  } });
  try {
    await host.startup();
    // The page posts through Vektor: the host forwards it to the plugin as web/message, and web/post back as the event.
    const { bridge, window } = page((message) => host.webMessage('page', message));
    let since = host.received.length;
    const answer = bridge.request('load', { which: 7 });
    const posted = await host.waitFor({ method: 'web/post' }, { since });
    window.dispatch('vektor-message', posted.params.message);
    assert.deepEqual(await answer, { strokes: [7] });
    const pushed = [];
    bridge.on('cleared', (message) => pushed.push(message));
    since = host.received.length;
    host.plugin.web('page').post({ type: 'cleared', by: 'plugin' });
    window.dispatch('vektor-message', (await host.waitFor({ method: 'web/post' }, { since })).params.message);
    assert.deepEqual(pushed, [{ type: 'cleared', by: 'plugin' }]);
  } finally {
    await host.close();
  }
});

test('page: a refusal rejects the request with the plugin’s words; another page’s reply is ignored', async () => {
  const posted = [];
  const { bridge, window } = page((message) => posted.push(message));
  const asked = bridge.request('undo');
  assert.equal(posted[0].type, 'undo');
  window.dispatch('vektor-message', { type: 'reply', replyTo: 'another-page-1', result: 1 });
  window.dispatch('vektor-message', { type: 'reply', replyTo: posted[0].requestId, error: 'Nothing to undo.' });
  await assert.rejects(asked, /Nothing to undo\./);
});

test('page: theme helpers read the CSS properties; outside Vektor posts are logged, requests refused', async () => {
  const { bridge } = page(null);
  assert.equal(bridge.available, false);
  assert.equal(bridge.role('label3'), '#c9a227');
  assert.equal(bridge.isLight(), true);
  const original = console.info;
  console.info = () => {};
  try {
    bridge.post({ type: 'x' });
    await assert.rejects(bridge.request('load'), /Not in Vektor/);
  } finally {
    console.info = original;
  }
  assert.throws(() => bridge.post({ big: 'x'.repeat(1024 * 1024) }), /at most 1 MB/);
});

test('the starter stylesheet uses only the CSS properties the reference documents', () => {
  const documented = new Set([
    ...['background-primary', 'background-secondary', 'background-elevated', 'background-chrome', 'surface-row-alternate', 'surface-row-hover',
      'foreground-primary', 'foreground-secondary', 'foreground-muted', 'foreground-disabled', 'foreground-on-accent', 'accent-primary',
      'accent-secondary', 'accent-destructive', 'accent-warning', 'accent-success', 'border-standard', 'border-subtle', 'border-focus',
      'selection-background', 'selection-foreground', 'selection-inactive'].map((token) => `--vektor-color-${token}`),
    ...['accent', 'positive', 'warning', 'danger', 'neutral', 'label1', 'label2', 'label3', 'label4', 'label5', 'label6', 'label7', 'label8']
      .flatMap((role) => ['mark', 'text', 'fill'].map((part) => `--vektor-role-${role}-${part}`)),
    '--vektor-font-family', '--vektor-font-mono', '--vektor-font-size', '--vektor-font-size-small', '--vektor-font-size-heading',
    '--vektor-font-size-title', '--vektor-radius-window', '--vektor-radius-panel', '--vektor-radius-control', '--vektor-radius-menu',
    '--vektor-border-width', '--vektor-space-xxs', '--vektor-space-xs', '--vektor-space-sm', '--vektor-space-md', '--vektor-space-lg',
    '--vektor-space-xl', '--vektor-theme-light',
  ]);
  for (const file of [path.join(web, 'vektor.css'), path.resolve(__dirname, '../../../samples/sketch/web/vektor.css')]) {
    const css = fs.readFileSync(file, 'utf8');
    const used = new Set(css.match(/--vektor-[a-z0-9-]+/g));
    for (const name of used) assert.ok(documented.has(name), `${path.basename(path.dirname(path.dirname(file)))}: ${name} is not a documented property`);
    assert.ok(!/#[0-9a-f]{3,6}\b/i.test(css.replace(/:where\(:root\)\s*\{[^}]*\}/, '')), 'no colour outside the preview fallbacks');
  }
});
