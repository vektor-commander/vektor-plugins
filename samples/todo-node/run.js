#!/usr/bin/env node
// Todo (Node) - a sample Vektor plugin: the Todo sample of this repository, written in Node.js instead of zsh.
//
// A todo list in a pane. Nothing in Vektor knows about todos: this program speaks the plugin protocol on stdin/stdout
// (`Content-Length` framed JSON), describes its list and its summary as data (a `list` view and a `detail` view), and
// answers what the user does - add, edit, check, reorder, delete - with a new description. Vektor draws it natively.
//
//   * The todos are a plain text file in the plugin's data folder (`$VEKTOR_PLUGIN_DATA/todos.list`), or in the folder
//     the "Storage location" setting names; "A list for each workspace" keeps one file per workspace. Each change is
//     written at once (to a temporary file, then renamed over the real one), so a quit or a crash loses nothing. The file
//     has the same format as the zsh sample's, so the two can read each other's lists.
//   * It starts no process and keeps nothing outside its data folder, so there is nothing to clean up on shutdown beyond a
//     half-written temporary file.
//   * Every description carries a `revision`; Vektor hands back, with each event, the revision the user was looking at. A
//     reorder made against a list that has since changed is ignored (and the list is described again), because "move
//     this before that" no longer means what the user saw.
//
// Node traps this file avoids (templates/node/run.js explains them in its header):
//   * `Content-Length` is a byte count: `send` measures the encoded Buffer, and the reader works on Buffers, decoding the
//     body only once all of its bytes have arrived.
//   * Nothing but messages goes to stdout. Diagnostics: console.error.
//   * `shutdown` is answered and the process exits when the answer has been written.
//   * Nothing is written outside $VEKTOR_PLUGIN_DATA (or the folder the user chose in Settings).
//   * Node is not installed by macOS; plugin.json says so in a banner. No npm packages are used.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const data = process.env.VEKTOR_PLUGIN_DATA || path.join(os.tmpdir(), 'vektor-todo-node');
fs.mkdirSync(data, { recursive: true });
const US = '\x1f';   // separates the fields of a line of the list

// --- State ------------------------------------------------------------------------------------------------------------
let settings = {};
let order = [];                 // todo ids in the user's order
const todos = new Map();        // id -> { text, fin (0|1), at }
let open = [];                  // ids as shown: the open ones and the completed ones
let fin = [];
let wsID = '';
let wsName = '';
let file = '';
let revision = 0;
let nextID = 0;

// --- Wire -------------------------------------------------------------------------------------------------------------
function send(message) {
  const body = Buffer.from(JSON.stringify({ api: 1, ...message }), 'utf8');
  process.stdout.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii'), body]));
}
const notify = (method, params) => send({ method, params });
const reply = (id, result) => send({ id, result });
const refuse = (id, message) => send({ id, error: { message } });

// --- Settings and the file --------------------------------------------------------------------------------------------
function loadSettings(params) {
  const s = params.settings || {};
  settings = { storage: s.storage || '', showCompleted: s.showCompleted, sort: s.sort || 'manual', perWorkspace: s.perWorkspace };
  wsID = (params.workspace && params.workspace.id) || '';
  wsName = (params.workspace && params.workspace.name) || '';
  let folder = settings.storage || data;
  try { fs.mkdirSync(folder, { recursive: true }); } catch { folder = data; }
  file = settings.perWorkspace === true && wsID
    ? path.join(folder, `todos-${wsID.replace(/[^A-Za-z0-9-]/g, '_')}.list`)
    : path.join(folder, 'todos.list');
}

function loadTodos() {
  order = [];
  todos.clear();
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return; }
  for (const line of text.split('\n')) {
    const [id, finished, at, ...rest] = line.split(US);
    const body = rest.join(US);
    if (!id || !body) continue;
    todos.set(id, { text: body, fin: finished === '1' ? 1 : 0, at: Number(at) || 0 });
    order.push(id);
  }
}

function saveTodos() {   // a temporary file, then renamed over the real one: a crash never leaves half a list
  const lines = order.map((id) => { const t = todos.get(id); return [id, t.fin, t.at, t.text].join(US); });
  fs.writeFileSync(`${file}.new`, lines.map((l) => `${l}\n`).join(''));
  fs.renameSync(`${file}.new`, file);
}

function clean(value) {   // one line, trimmed, at most 2000 bytes and valid UTF-8; '' for nothing
  let t = String(value ?? '').replace(/[\t\n\r\x1f]/g, ' ').trim();
  const bytes = Buffer.from(t, 'utf8');
  if (bytes.length > 2000) t = bytes.subarray(0, 2000).toString('utf8').replace(/�+$/, '');
  return t;
}

// --- What is shown ----------------------------------------------------------------------------------------------------
function computeDisplay() {   // open and fin, in the order the Sort order setting asks for
  let base;
  switch (settings.sort || 'manual') {
    case 'newest': base = [...order].reverse(); break;
    case 'alphabetical':
      base = [...order].sort((a, b) => {
        const x = todos.get(a).text.toLowerCase();
        const y = todos.get(b).text.toLowerCase();
        return x < y ? -1 : x > y ? 1 : a < b ? -1 : a > b ? 1 : 0;
      });
      break;
    default: base = [...order];
  }
  open = base.filter((id) => todos.get(id).fin !== 1);
  fin = base.filter((id) => todos.get(id).fin === 1);
}

function rowJSON(id) {
  const t = todos.get(id);
  const done = t.fin === 1;
  return {
    id, title: t.text,
    checkbox: { checked: done, action: 'toggle' }, edit: 'edit', delete: 'delete', dimmed: done,
    menu: [
      { title: 'Edit', symbol: 'pencil', action: 'edit' },
      { separator: true },
      { title: 'Delete', symbol: 'trash', action: 'delete', destructive: true },
    ],
  };
}

function todosJSON() {
  const groups = [{ id: 'open', rows: open.map(rowJSON) }];
  if (settings.showCompleted !== false && fin.length > 0) {
    groups.push({ id: 'done', title: 'Completed', collapsible: true, rows: fin.map(rowJSON) });
  }
  const list = { input: { placeholder: 'Add a todo…', action: 'add' }, groups };
  // Rows move only in the user's own order: with another sort the position is not theirs to set.
  if ((settings.sort || 'manual') === 'manual') list.reorder = 'move';
  return {
    revision, header: { title: 'Todo' }, list,
    empty: { title: 'Nothing to do', message: 'Type a todo above and press Return.', symbol: 'checklist' },
  };
}

function summaryJSON() {
  const home = os.homedir();
  const where = settings.perWorkspace === true && wsID ? `Workspace “${wsName}”` : 'All workspaces';
  const stored = file.startsWith(home) ? `~${file.slice(home.length)}` : file;
  const markdown = [
    '## Keys', '',
    '- **Return** adds a todo from the field at the top, or edits the selected one',
    '- **Space** checks it off',
    '- **⌥↑** and **⌥↓** move it; so does dragging',
    '- **Delete** removes it',
    '- **Esc** closes the list',
  ].join('\n');
  return {
    revision,
    detail: {
      heading: { title: 'Todo', subtitle: `${open.length} open, ${fin.length} completed`, symbol: 'checklist' },
      rows: [
        { label: 'Open', value: String(open.length) },
        { label: 'Completed', value: String(fin.length) },
        { label: 'Total', value: String(order.length) },
        { label: 'List', value: where },
        { label: 'Stored in', value: stored },
      ],
      markdown,
      actions: [{ title: 'Clear Completed', symbol: 'trash', action: 'clear', enabled: fin.length > 0 }],
    },
  };
}

function refresh() {   // every view is described again, with the next revision
  revision += 1;
  computeDisplay();
  notify('view/update', { view: 'todos', description: todosJSON() });
  notify('view/update', { view: 'summary', description: summaryJSON() });
}

// --- Changing the list ------------------------------------------------------------------------------------------------
function addTodo(value) {
  const text = clean(value);
  if (!text) return false;
  nextID += 1;
  const now = Math.floor(Date.now() / 1000);
  const id = `t${now}${Math.floor(Math.random() * 32768)}${nextID}`;
  todos.set(id, { text, fin: 0, at: now });
  order.push(id);
  return true;
}

function removeTodo(id) {
  order = order.filter((x) => x !== id);
  todos.delete(id);
}

function moveTodo(id, before) {   // "this one goes before that one"; no `before`: the end of its group
  if (!todos.has(id) || id === before) return false;
  order = order.filter((x) => x !== id);
  const at = before ? order.indexOf(before) : -1;
  if (at >= 0) {
    order.splice(at, 0, id);
  } else {
    let last = -1;
    order.forEach((other, i) => { if (todos.get(other).fin === todos.get(id).fin) last = i; });
    if (last >= 0) order.splice(last + 1, 0, id); else order.push(id);
  }
  return true;
}

function onEvent(params) {
  const { action, card, value, before, revision: seen } = params;
  switch (action) {
    case 'add':
      if (addTodo(value)) { saveTodos(); refresh(); }
      return;
    case 'toggle':
      if (!todos.has(card)) return;
      todos.get(card).fin = value === true || value === 'true' ? 1 : 0;
      saveTodos(); refresh();
      return;
    case 'edit': {
      const text = clean(value);
      if (!todos.has(card) || !text) return;
      todos.get(card).text = text;
      saveTodos(); refresh();
      return;
    }
    case 'delete':
      if (!todos.has(card)) return;
      removeTodo(card); saveTodos(); refresh();
      return;
    case 'move':
      // A reorder made against an older list is ignored: describe the list again so the user sees what is true.
      if (typeof seen === 'number' && seen < revision) { refresh(); return; }
      if (moveTodo(card, before)) { saveTodos(); refresh(); }
      return;
    case 'clear':
      for (const id of [...order]) if (todos.get(id).fin === 1) removeTodo(id);
      saveTodos(); refresh();
      return;
    default:
  }
}

// --- Main loop --------------------------------------------------------------------------------------------------------
function removeTemporary() { try { fs.unlinkSync(`${file}.new`); } catch { /* not there */ } }

function onMessage(message) {
  const { method, id, params = {} } = message;
  switch (method) {
    case 'startup':
      loadSettings(params);
      loadTodos();
      reply(id, {});
      return refresh();
    case 'shutdown':
      if (file) removeTemporary();
      reply(id, {});
      return process.stdout.write('', () => process.exit(0));   // leave only when the answer has been written
    case 'settingsChanged': {
      const previous = file;
      loadSettings(params);
      if (file !== previous) loadTodos();
      return refresh();
    }
    case 'view/opened': return refresh();
    case 'view/closed': return;
    case 'view/event': return onEvent(params);
    case 'ping': return reply(id, {});
    case '$/cancel': return;
    default:
      if (method && id !== undefined) refuse(id, 'unknown method');
  }
}

let pending = Buffer.alloc(0);

function drain() {
  for (;;) {
    const headerEnd = pending.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const header = pending.subarray(0, headerEnd).toString('latin1');
    const match = /^content-length:\s*(\d+)/im.exec(header);
    if (!match) { console.error('a message without Content-Length'); process.exit(1); }
    const length = Number(match[1]);
    if (pending.length < headerEnd + 4 + length) return;   // the rest of the body has not arrived yet
    const body = pending.subarray(headerEnd + 4, headerEnd + 4 + length).toString('utf8');
    pending = pending.subarray(headerEnd + 4 + length);
    let message;
    try { message = JSON.parse(body); } catch { console.error('a message that is not JSON'); continue; }
    onMessage(message);
  }
}

process.stdin.on('data', (chunk) => { pending = Buffer.concat([pending, chunk]); drain(); });
// End of file: Vektor is gone. Nothing to stop; remove a half-written temporary file.
process.stdin.on('end', () => { if (file) removeTemporary(); process.exit(0); });
