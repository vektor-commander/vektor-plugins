# The Vektor plugin SDK for Node.js

Write a plugin in Node.js without hand-building `Content-Length` frames or whole view descriptions. The SDK does the protocol,
gives typed builders for every block, keeps your view's state and sends **patches**, and ships five [layouts](sdk-layouts.md)
(a board, a list with detail, a table with toolbar, a settings form, a card list). Everything it does is plain protocol
([`reference.md`](reference.md)); nothing here is magic you cannot read — `sdk/node/src/` is TypeScript with comments, and
`dist/` is the compiled JavaScript your plugin carries.

* **No runtime dependencies**, Node.js 18 or later. **The user must install Node themselves** (nodejs.org or Homebrew; a Node
  from nvm, fnm or Volta is not on a plugin's fixed `PATH`) — the template says so in a banner on the first setting. Say it in your
  README too.
* The SDK is versioned on its own: see the table in [`sdk/README.md`](../sdk/README.md) for the plugin API each version targets and
  the oldest Vektor it needs.

## Start

Copy the template: `cp -R templates/node ~/my-plugin`, change `id`, `name` and `publisher` in `plugin.json`. The SDK is in the
template's `vektor-sdk/` folder (a plugin may only load files from its own folder, so it carries a copy; it is `sdk/node/dist`).

```js
#!/usr/bin/env node
'use strict';
const { Plugin, blocks: b } = require('./vektor-sdk');

function setup(plugin) {
  plugin.command('hello', (target) => `Hello! You chose ${(target.items || []).length} item(s).`);   // a string is a short notice
  return plugin;
}
module.exports = { setup };                       // so a test can run it in memory
if (require.main === module) setup(new Plugin()).start();
```

`plugin.start()` reads stdin and writes stdout. **stdout carries only messages**: use `console.error` or
`plugin.log(…)` for your own lines. A stray `console.log` (or a library writing to stdout) does not break the stream: the SDK
keeps the real stdout for messages and sends anything else written there to stderr, the plugin's Log. The SDK answers `ping`, `$/cancel` and `shutdown` itself and exits within the grace period.

## The plugin

| | |
|---|---|
| `plugin.command(name, (target, context) => result)` | a command of the manifest (`invoke`). Return nothing for `{}`, a string for a notice, or `{ message }`; throw a `PluginError` for an alert in plain words |
| `plugin.onStartup / onReady / onShutdown(reason) / onSettingsChanged / onWorkspaceChanged` | lifecycle. `onReady` runs right after `startup` is answered: send the first views there |
| `plugin.settings`, `plugin.workspace`, `plugin.dataFolder` | the latest values (defaults filled in), the active workspace, `$VEKTOR_PLUGIN_DATA` |
| `plugin.request(method, params, { timeout, signal })` | a request of your own, answered by id; `plugin.confirm`, `getSettings`, `navigate` … are typed wrappers |
| `plugin.notify(method, params)`, `plugin.log(…)` | notifications |
| `plugin.onRequest(method, handler)`, `onNotification` | anything the SDK does not type |
| `plugin.view(id)` | the [view state](#views-and-patches) of a view |
| `plugin.sidebar(entry)`, `plugin.web(view)`, `plugin.storage(place)` | [sidebar items](#sidebar-items-and-workspaces), [web views](#web-views), [storage](#storage-and-sync) |

Every message of the reference has its type in `vektor-sdk/messages.d.ts`. Errors are `PluginError` (your words, shown to the
user) or `VektorError` (Vektor refused something: `code`, `message`, `data`).

## Blocks

`blocks` (usually imported as `b`) has a builder for every block of the reference; each returns exactly the JSON the reference
documents (the tests check them against `sdk/fixtures/blocks.json`). Containers take their children first; ids of collections'
items, inputs, sections, tabs, splits, nodes and web blocks are required and **must be stable** (a card's id is the card's own).

```js
b.vstack([
  b.textField('name', 'add', { placeholder: 'Type a name' }),
  b.list('names', names.map((n) => b.row(n.id, { title: n.name, delete: 'remove' })), { placeholder: 'Nobody yet.' }),
]);
```

You never send a colour value, only a role (`accent`, `positive`, `warning`, `danger`, `neutral`, `label1` … `label8`).
`validateBlocks(tree)` reports, in plain words, what Vektor would refuse — `ViewState` runs it before every send. Like Vektor, it
trims required strings: an option's `value` or `title`, a menu item's `title` or `action`, a column's `id` or `title` that is
empty or only white space counts as missing, and Vektor refuses the whole description for it.

**Widths** go in any builder's options: `width`, `minWidth`, `maxWidth` (structural numbers in points, never a theme's, from 20 to
4000: `WIDTHS`) and `grow: true`. `width` is never wider than the row offers, `minWidth` is honoured inside a horizontal `scroll`
(on a `grid` it is the tile minimum), `grow` takes a share of the width the row leaves. Vektor ignores a value outside that range
and says so in the Log; `validateBlocks` reports it as a warning. Columns that fill the pane and scroll once they no longer fit:

```js
b.scroll([
  b.panel(todo, { id: 'col-todo', title: 'To do', grow: true, minWidth: 240 }),
  b.panel(done, { id: 'col-done', title: 'Done', grow: true, minWidth: 240 }),
], { axis: 'horizontal', spacing: 12 });
```

## Views and patches

```js
const view = plugin.view('hello');
const describe = () => view.show({ header: { title: 'Hello' }, blocks: tree() });
view.onOpen(describe);
view.on('add', (event) => { names.push({ id: `n${next++}`, name: event.value }); describe(); });
```

* `view.show(description)` keeps the description and its revision, and sends a **patch** (`view/patch`) when one says the change
  (computed by id and checked to rebuild the new tree exactly) and the whole description otherwise. It returns what it sent
  (`'patch'`, `'update'`, `'unchanged'`). `view.update(description)` always sends the whole; `view.patch(ops)` sends
  operations you built.
* `view.on(action, handler, { stale })` routes `view/event`s by the action string your blocks carried. An event made against an
  older revision: a **move** is dropped (`'ignoreMoves'`, the default — "put it at index 3" no longer means what the user saw),
  anything else is delivered with `event.stale = true`; `'ignore'` and `'deliver'` choose otherwise.
* `view.onOpen`, `onClose`, `view.isOpen`, `view.item` (the sidebar item the view was opened for), `view.invalidate()`.
* `view.onRefused((refusal) => …)` (API 2): Vektor could not show a description or a patch (`view/refused`). `refusal.problem`
  says why in plain words, `refusal.kind` is `'description'` or `'patch'`, `refusal.revision` is what Vektor still shows. Events
  made against that revision are not stale (they keep carrying it until Vektor shows something newer). The next `show` sends the
  whole description; after a refused **patch** the SDK sends the kept description again by itself, numbered above anything sent,
  unless your handler sent something (`plugin.view(id, { resendAfterRefusal: false })` turns that off). A refused whole
  description is not resent — it would be refused again — so fix what `problem` names and `show` again. `view.refusal` is the
  last one.
* API 1 view kinds (`list`, `form`, `detail`, `cardList`, `toolbar`) are plain objects in the description; the Todo (Node) sample
  uses them.

## Layouts

Each layout draws one block and routes its events to callbacks. The full description of each — what it shows and every callback —
is in [`sdk-layouts.md`](sdk-layouts.md); the source is `sdk/node/src/layouts/`, one short file each, meant to be copied.

```js
const { Plugin, board, routeBoard, moveCard, boardShows } = require('./vektor-sdk');

function setup(plugin) {
  const columns = [
    { id: 'todo', title: 'To do', role: 'label6', cards: [{ id: 'c1', title: 'Write the spec', tags: [{ text: 'docs' }] }] },
    { id: 'done', title: 'Done', role: 'label4', cards: [] },
  ];
  let search = '';
  let next = 2;
  const view = plugin.view('board');
  const draw = () => view.show({ header: { title: 'Roadmap' }, blocks: board({ columns, search }) });

  view.onOpen(draw);
  routeBoard(view, {}, {
    onMove: (move) => { if (moveCard(columns, move, (card) => boardShows({ search }, card))) draw(); },
    onAdd: (column) => { columns.find((c) => c.id === column).cards.push({ id: `c${next++}`, title: 'New card' }); draw(); },
    onRename: (card, title) => { for (const c of columns) for (const k of c.cards) if (k.id === card) k.title = title; draw(); },
    onRemove: (card) => { for (const c of columns) c.cards = c.cards.filter((k) => k.id !== card); draw(); },
    onSearch: (text) => { search = text; draw(); },
  });
  return plugin;
}
```

The manifest needs `"api": 2`, a view `{"id": "board", "kind": "blocks"}` and a sidebar entry for it. The other layouts are used
the same way:

| Layout | Draw | Listen |
|---|---|---|
| Board | `board({ columns, search, filter, toolbar })` | `routeBoard(view, {}, { onAdd, onOpen, onRename, onRemove, onMove, onColumnAction, onSearch, onFilter })` |
| List with detail | `listDetail({ items, selected, search, detail: detailPanel({ title, fields, markdown, actions }) })` | `routeListDetail(view, {}, { onSelect, onOpen, onSearch, onDetailAction })` |
| Table with toolbar | `tableWithToolbar({ columns, rows: sortRows(rows, columns, sorted), sorted, selected, toolbar })` | `routeTable(view, {}, { onSort, onSelect, onToolbar, onSearch, onOpen, onDelete })` |
| Settings form | `settingsForm({ sections: [{ id, title, fields: [{ kind: 'toggle', key, label, value }] }] })` | `routeSettingsForm(view, {}, { onChange, onButton })` |
| Card list | `cardList({ cards, empty })` (throws for a button key with a dot) | `routeCardList(view, { menuKeys: ['delete'] }, { onOpen, onButton, onMenu })` |

The second argument of every `route…` is `{ id }` (and `columnMenu` for the board): pass the same ones you draw with. All of
them are also on the namespace `layouts` (`layouts.board`, …).

## Sidebar items and workspaces

```js
plugin.sidebar('boards').provide((workspace) => boards.map((x) => ({ id: x.id, title: x.name })));   // sent after startup and each workspace switch
plugin.sidebar('boards').onMenu('rename', (item) => { … });                                           // a `sidebarItem` menu's command
view.onOpen((opened) => show(opened.item));                                                           // the item that opened the view
```

`WorkspaceState` keeps one value per workspace in the data folder, written atomically:
`const opened = new WorkspaceState(plugin, 'opened', { board: null }); opened.get().board = 'b1'; opened.save();`.
`plugin.onWorkspaceChanged` runs on a switch (also for an `"api": 1` plugin, from `settingsChanged`).

## Storage and sync

With the `storage` permission and a `place` setting, `plugin.storage(plugin.settings.place)` reads and writes inside the folder
the user chose, wherever it is (this Mac, S3, SFTP …). Paths are relative to the place.

```js
const store = plugin.storage(plugin.settings.board);                 // the handle from the latest startup / settingsChanged
const file = await store.readJSON('board.json');                      // { value, version } or null
const outcome = await store.writeIfUnchanged('board.json', board, file?.version ?? null);
if (!outcome.written) {
  const { mine, theirs, currentVersion } = outcome.conflict;          // someone changed it meanwhile
  const merged = threeWayMerge(baseCards, mine.cards, theirs.value.cards);
  // merged.status is 'unchanged', 'merged' or 'conflicts'; with conflicts YOU choose (the Board asks the user)
}
```

`threeWayMerge(base, mine, theirs)` compares records by stable `id` and `updatedAt` and returns `merged`, `conflicts` (both
changed a field, both added, one deleted while the other changed) or `unchanged`. It reports conflicts and never resolves them.
**Do not write `records` while there are conflicts**: resolve each one first. Until then a conflicting record holds theirs'
version (mine's when they deleted it), so a write by mistake loses nothing on the place; mine's version is only in the conflict.
Listing is paged (`list` follows the pages, `listPage` gives one), large files go in parts, `delete` answers whether the item
went to the Trash. Versions are opaque: compare for equality, pass back as `ifVersion`.

`updatedAt` is optional and only says which side changed a record last; both SDKs read it the same way. A number is
milliseconds since 1970 (JavaScript's `Date.now()`); text is an ISO 8601 date-time — `2026-10-23T10:00:00Z`, with optional
fractional seconds and `Z` or an offset such as `+02:00` — read to the millisecond. Anything else (a date without a time,
seconds since 1970 written as text, another date format, an impossible date) counts as no timestamp.

## Web views

`plugin.web('sketch').on('save', (message) => …)` receives what the page posted with `vektor.post({ type: 'save', … })`;
`.post(message)` reaches your pages. The page side is `sdk/web/vektor-bridge.js`; `sdk/web/vektor.css` is a starter stylesheet
on the theme's CSS properties. When to use a web view rather than blocks: [`sdk-layouts.md`](sdk-layouts.md#when-to-use-blocks-and-when-a-web-view).

## Testing

The test kit is an in-memory Vektor: `vektor-sdk/testkit.js` plays the same `test/checks.json` scripts as `vektor-plugin test`
and also lets you drive the plugin by hand.

```js
const { TestHost, runScript } = require('./vektor-sdk/testkit');
const host = await TestHost.start({ folder: __dirname, setup });
await host.startup();
host.openView('board');
await host.waitFor({ method: 'view/update' });
host.viewEvent('board', 'board.add', { block: 'board.add.todo' });
await host.waitFor({ method: 'view/patch' });
host.refuse('board', { problem: 'operation 1 cannot apply.' });   // view/refused: the plugin answers with the whole description
await host.waitFor({ method: 'view/update' });
await host.shutdown(); await host.close();
```

`node --test` in the plugin folder runs the template's test file. `vektor-plugin validate` and `vektor-plugin test` work on a
Node plugin like any other (on a Mac where Node came from nvm, run them on a scratch copy whose first line points at that node,
or install Node where the plugin `PATH` finds it).

## Changing the SDK

`sdk/node/src/` is TypeScript. `./build.sh` in `sdk/node` compiles it to `dist/` and refreshes the copies in `templates/node/`
and `samples/todo-node/`; it needs TypeScript (`npm install` there, or `TSC=/path/to/tsc`). `npm test` runs the tests. Publishing
the package is the maintainer's step.

The Todo (Node) sample (`samples/todo-node`) is the proof the SDK is complete enough: a whole plugin with settings, a list view, a
detail view, revisions and a file on disk.
