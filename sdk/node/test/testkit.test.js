'use strict';
// The test kit plays the same test/checks.json scripts as `vektor-plugin test`, in memory and as a process; and the Node
// template carries exactly this SDK.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { runScript, formatReport, valueMatches, valueAt } = require('../dist/testkit');

const repository = path.resolve(__dirname, '../../..');
const template = path.join(repository, 'templates/node');

test('the Node template passes its checks.json in memory', async () => {
  const { setup } = require(path.join(template, 'run.js'));
  const report = await runScript(path.join(template, 'test/checks.json'), { folder: template, setup });
  assert.ok(report.passed, formatReport(report) + '\n' + report.transcript.join('\n'));
});

test('the Node template passes its checks.json as a process (started the way Vektor starts it)', async () => {
  // The plugin PATH has no Node on a Mac where it came from nvm; this one test adds the running Node's folder, as a user
  // who installed Node with Homebrew would have it.
  const report = await runScript(path.join(template, 'test/checks.json'), {
    folder: template, spawn: true, environment: { PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin` },
  });
  assert.ok(report.passed, formatReport(report) + '\n' + report.transcript.join('\n'));
});

test('a failing expectation fails the step, with the reason', async () => {
  const { setup } = require(path.join(template, 'run.js'));
  const report = await runScript({ steps: [
    { name: 'startup', startup: true, expect: [{ kind: 'response' }] },
    { name: 'wrong', send: { method: 'invoke', params: { command: 'hello', target: {} } }, expect: [{ kind: 'response', match: { 'result.message': 'nope' } }], timeout: 0.3 },
    { name: 'absent', send: { method: 'view/opened', params: { view: 'hello' } }, expect: [{ method: 'view/update', absent: true }] },
  ] }, { folder: template, setup });
  assert.equal(report.passed, false);
  assert.deepEqual(report.steps.map((step) => step.failures.length), [0, 1, 1]);
  assert.match(report.steps[1].failures[0], /did not receive response with result.message = "nope"/);
  assert.match(report.steps[2].failures[0], /which must not arrive/);
});

test('matching: exists, contains, matches, count, nested paths', () => {
  const message = { kind: 'notification', params: { list: [{ title: 'Buy milk' }], text: 'žluť' } };
  assert.equal(valueAt(message, 'params.list.0.title'), 'Buy milk');
  assert.ok(valueMatches(valueAt(message, 'params.list'), { count: 1 }));
  assert.ok(valueMatches(valueAt(message, 'params.text'), { count: 4 }));
  assert.ok(valueMatches(valueAt(message, 'params.list.0.title'), { contains: 'milk' }));
  assert.ok(valueMatches(valueAt(message, 'params.list.0.title'), { matches: '^Buy' }));
  assert.ok(valueMatches(valueAt(message, 'params.missing'), { exists: false }));
  assert.ok(!valueMatches(valueAt(message, 'params.missing'), null));
  assert.ok(valueMatches(valueAt(message, 'params.list'), [{ title: 'Buy milk' }]));
});

for (const [name, folder] of [['templates/node', template], ['samples/todo-node', path.join(repository, 'samples/todo-node')]]) test(`${name} carries exactly this SDK (vektor-sdk = dist)`, () => {
  const dist = path.resolve(__dirname, '../dist');
  const copy = path.join(folder, 'vektor-sdk');
  const files = (dir, sub = '') => fs.readdirSync(path.join(dir, sub), { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? files(dir, path.join(sub, entry.name)) : /\.(js|d\.ts)$/.test(entry.name) ? [path.join(sub, entry.name)] : []).sort();
  assert.deepEqual(files(copy), files(dist));
  for (const name of files(dist)) {
    assert.ok(fs.readFileSync(path.join(dist, name)).equals(fs.readFileSync(path.join(copy, name))), `${name} differs: run sdk/node/build.sh`);
  }
});

test('the Todo sample in Node passes its checks.json in memory (it is written on this SDK)', async () => {
  const folder = path.join(repository, 'samples/todo-node');
  const { setup } = require(path.join(folder, 'run.js'));
  const report = await runScript(path.join(folder, 'test/checks.json'), { folder, setup });
  assert.ok(report.passed, formatReport(report) + '\n' + report.transcript.join('\n'));
});
