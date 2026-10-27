'use strict';
// Runs test/checks.json against the plugin in memory, with Node's own test runner: `node --test` in the plugin folder.
// It is the same script `vektor-plugin test . test/checks.json` plays; this way it also runs where Node comes from nvm,
// and you can add tests of your own below with the test host (see vektor-sdk/testkit.d.ts).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { runScript, formatReport, TestHost } = require('../vektor-sdk/testkit');
const { setup } = require('../run.js');

const folder = path.resolve(__dirname, '..');

test('checks.json passes', async () => {
  const report = await runScript(path.join(__dirname, 'checks.json'), { folder, setup });
  assert.ok(report.passed, `${formatReport(report)}\n${report.transcript.join('\n')}`);
});

test('the view keeps the names in the order they were added', async () => {
  const host = await TestHost.start({ folder, setup });
  try {
    await host.startup();
    host.openView('hello');
    await host.waitFor({ method: 'view/update' });
    for (const name of ['Ada', 'Grace', 'Edsger']) host.viewEvent('hello', 'add', { block: 'name', value: name });
    await host.waitFor({ method: 'view/patch', match: { 'params.revision': 4 } });
    const rows = host.plugin.view('hello').description.blocks.children[1].children;
    assert.deepEqual(rows.map((row) => row.title), ['Hello, Ada!', 'Hello, Grace!', 'Hello, Edsger!']);
    await host.shutdown();
  } finally {
    await host.close();
  }
});
