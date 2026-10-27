#!/usr/bin/env node
// Hello Plugin (Node) - the Node plugin template, on the Vektor SDK (plugin API 2). Copy the folder, rename it in
// plugin.json, edit this file.
//
// It shows the two things most plugins do:
//   * a COMMAND in the file menu ("Say Hello"): Vektor sends `invoke`, the handler's return value is shown as a notice;
//   * a VIEW in the sidebar ("Hello"): a block view the plugin describes as data; Vektor draws it and sends back what the
//     user did as events, routed here by their action.
//
// The SDK (vektor-sdk/, plain JavaScript with no dependencies) does the protocol: Content-Length framing by bytes, ids
// and timeouts, `ping`, `$/cancel`, `shutdown` within the grace period, errors in plain words, and patches instead of whole
// descriptions where it can. docs/reference.md in the plugins repository is the protocol itself.
//
// Rules this file still follows by itself:
//   * Node is NOT installed by macOS. The user must install it (nodejs.org or Homebrew), and the setting banner in
//     plugin.json says so. Vektor gives plugins a fixed PATH, so a Node installed by nvm, fnm or Volta is NOT found.
//   * stdout carries messages and nothing else: never console.log. Diagnostics go to stderr (console.error) or
//     `plugin.log(...)`.
//   * Keep state in `plugin.dataFolder` ($VEKTOR_PLUGIN_DATA), never inside this folder (it is replaced on update).
'use strict';

const { Plugin, blocks: b } = require('./vektor-sdk');

// Everything the plugin does is registered here, so a test can run it in memory (see test/run.test.js).
function setup(plugin) {
  const greeting = () => plugin.settings.greeting || 'Hello';
  const names = [];            // [{ id, name }] - kept only while the plugin runs; a real plugin would save them
  let nextID = 1;

  // --- The command ----------------------------------------------------------------------------------------------------
  plugin.command('hello', (target) => {
    // target.items: the items the command was chosen for, each { path, name, isFolder } (or a `location` when remote).
    const count = (target.items || []).length;
    return `${greeting()}! You chose ${count} item(s).`;
  });

  // --- The view -------------------------------------------------------------------------------------------------------
  const view = plugin.view('hello');

  // The whole view, as it should look now. `show` compares it with what Vektor has and sends a patch when it can.
  // Ids are stable (a name keeps its id), which is what lets the SDK patch instead of resending everything.
  const describe = () => view.show({
    header: { title: 'Hello' },
    blocks: b.vstack([
      b.textField('name', 'add', { placeholder: 'Type a name and press Return' }),
      b.list('names', names.map((entry) => b.row(entry.id, {
        title: `${greeting()}, ${entry.name}!`,
        symbol: 'person',
        delete: 'remove',
        menu: [{ title: 'Remove', symbol: 'trash', action: 'remove', destructive: true }],
      })), { placeholder: 'Nobody greeted yet.' }),
    ]),
  });

  view.onOpen(describe);
  view.on('add', (event) => {
    const name = String(event.value || '').trim();
    if (name === '') return;
    names.push({ id: `name-${nextID++}`, name });
    describe();
  });
  view.on('remove', (event) => {
    const index = names.findIndex((entry) => entry.id === event.block);
    if (index >= 0) names.splice(index, 1);
    describe();
  });

  // --- Lifecycle ------------------------------------------------------------------------------------------------------
  plugin.onSettingsChanged(() => { if (view.isOpen) describe(); });
  plugin.onReady(() => plugin.log('Hello Plugin started.'));
  plugin.onShutdown(() => {
    // Stop what you started (nothing here). The SDK answers `shutdown` and exits within the grace period.
  });
  return plugin;
}

module.exports = { setup };
if (require.main === module) setup(new Plugin()).start();
