'use strict';
// The storage helper against the test kit's fake place (a temporary folder): JSON documents with versions, Conflict from
// writeIfUnchanged, paged listing, large files in parts, deletes to the stand-in Trash, refusal codes.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Conflict, VektorError, threeWayMerge } = require('../dist');
const { TestHost } = require('../dist/testkit');

function folder() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vektor-sdk-storage-'));
  fs.writeFileSync(path.join(dir, 'plugin.json'), JSON.stringify({
    id: 'com.example.storage-test', name: 'Storage test', api: 2, executable: 'run.js', permissions: ['storage'],
    settings: { items: [{ key: 'boards', kind: 'place', label: 'Boards' }] },
  }));
  return dir;
}

// Runs `body(storage, host)` inside the plugin (a command), so every call goes over the wire to the host.
async function withStorage(body) {
  let run;
  const host = await TestHost.start({
    folder: folder(), settings: { boards: { $place: 'boards' } },
    setup: (plugin) => plugin.command('run', async () => { await run(plugin.storage(plugin.settings.boards), host); return 'ok'; }),
  });
  try {
    await host.startup();
    return async (fn) => {
      let failure;
      run = async (storage) => { try { await fn(storage, host); } catch (error) { failure = error; } };
      const answer = await host.request('invoke', { command: 'run', target: {} }, 20);
      if (failure) throw failure;
      assert.equal(answer.kind, 'response', JSON.stringify(answer));
    };
  } catch (error) {
    await host.close();
    throw error;
  } finally {
    withStorage.hosts.push(host);
  }
}
withStorage.hosts = [];
test.after(async () => { for (const host of withStorage.hosts) await host.close(); });

test('the place handle and status are what Vektor sends', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    assert.match(storage.place, /^pl-[a-z2-7]{26}$/);
    assert.deepEqual(host.plugin.settings.boards.label, 'Test place ▸ boards');
    assert.deepEqual(await storage.status(), { state: 'available', label: 'Test place ▸ boards', remote: false, writes: 'atomic', conditional: 'checked' });
  });
});

test('JSON documents: write as new, read with its version, null for a missing one', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    assert.equal(await storage.readJSON('board.json'), null);
    const version = await storage.writeJSON('board.json', { cards: ['é', '👍'] }, null);
    const read = await storage.readJSON('board.json');
    assert.deepEqual(read, { value: { cards: ['é', '👍'] }, version });
    assert.ok(fs.existsSync(path.join(host.variables['place.boards'], 'board.json')));
  });
});

test('writeIfUnchanged: written when unchanged; a Conflict with both versions when someone else wrote meanwhile', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const first = await storage.writeIfUnchanged('board.json', { title: 'Base' }, null);
    assert.equal(first.written, true);
    const base = await storage.readJSON('board.json');
    // Another device writes the file.
    fs.writeFileSync(path.join(host.variables['place.boards'], 'board.json'), JSON.stringify({ title: 'Theirs' }));
    const outcome = await storage.writeIfUnchanged('board.json', { title: 'Mine' }, base.version);
    assert.equal(outcome.written, false);
    const conflict = outcome.conflict;
    assert.ok(conflict instanceof Conflict);
    assert.deepEqual(conflict.mine, { title: 'Mine' });
    assert.equal(conflict.baseVersion, base.version);
    assert.deepEqual(conflict.theirs.value, { title: 'Theirs' });
    assert.notEqual(conflict.currentVersion, base.version);
    // Resolved by the plugin, written against the current version.
    const merged = await storage.writeIfUnchanged('board.json', { title: 'Mine + Theirs' }, conflict.currentVersion);
    assert.equal(merged.written, true);
  });
});

test('writeIfUnchanged expecting no file, when one appeared: a Conflict', async () => {
  const inside = await withStorage();
  await inside(async (storage) => {
    await storage.writeJSON('a.json', { n: 1 });
    const outcome = await storage.writeIfUnchanged('a.json', { n: 2 }, null);
    assert.equal(outcome.written, false);
    assert.equal(outcome.conflict.baseVersion, null);
    assert.deepEqual(outcome.conflict.theirs.value, { n: 1 });
  });
});

test('a conflict on a deleted file: theirs is null', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const version = await storage.writeJSON('gone.json', { n: 1 });
    fs.unlinkSync(path.join(host.variables['place.boards'], 'gone.json'));
    const outcome = await storage.writeIfUnchanged('gone.json', { n: 2 }, version);
    assert.equal(outcome.conflict.theirs, null);
    assert.equal(outcome.conflict.currentVersion, null);
  });
});

test('list follows every page; a made-up cursor is refused with badCursor', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const dir = host.variables['place.boards'];
    for (let i = 0; i < 25; i++) fs.writeFileSync(path.join(dir, `card-${String(i).padStart(2, '0')}.json`), '{}');
    fs.writeFileSync(path.join(dir, '.vektor-temp'), 'hidden');
    fs.mkdirSync(path.join(dir, 'sub'));
    const page = await storage.listPage('', { limit: 10 });
    assert.equal(page.entries.length, 10);
    assert.ok(page.next);
    const all = await storage.list('', { limit: 10 });
    assert.equal(all.length, 26);
    assert.ok(!all.some((entry) => entry.name.startsWith('.vektor-')));
    assert.deepEqual(all.find((entry) => entry.name === 'sub'), { name: 'sub', isFolder: true, modified: all.find((e) => e.name === 'sub').modified });
    await assert.rejects(storage.listPage('', { cursor: 'cu-forged' }), (error) => error instanceof VektorError && error.code === 'badCursor');
    await assert.rejects(storage.listPage('sub', { cursor: page.next }), (error) => error.code === 'badCursor' && /another folder/.test(error.message));
  });
});

test('a large file goes in parts both ways, multi-byte text intact', async () => {
  const inside = await withStorage();
  await inside(async (storage) => {
    const text = 'žluťoučký kůň 👍\n'.repeat(60000); // ~1.3 MB: three parts, parts split characters
    await storage.write('big.txt', text);
    const read = await storage.readText('big.txt');
    assert.equal(read.value, text);
  });
});

test('delete answers trashed (the stand-in Trash), and refusal codes come through', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const version = await storage.write('x.txt', 'x');
    assert.equal(await storage.delete('x.txt', version), true);
    assert.equal(fs.readdirSync(host.places.trash).length, 1);
    await assert.rejects(storage.readText('x.txt'), (error) => error.code === 'notFound' && error.message === '“x.txt” does not exist.');
    await assert.rejects(storage.write('../escape.txt', 'x'), (error) => error.code === 'badPath');
    await assert.rejects(storage.write('a/b.txt', 'x'), (error) => error.code === 'notFound');
    await storage.createFolders('a/b');
    await storage.createFolders('a/b');
    await storage.write('a/b/c.txt', 'deep');
    await assert.rejects(storage.createFolder('a'), (error) => error.code === 'exists');
    await assert.rejects(storage.write('a/b/c.txt', 'x', 'made-up'), (error) => error.code === 'badRequest' && /a version Vektor gave/.test(error.message));
  });
});

test('sync over storage: a three-way merge of a list of cards, written back if unchanged', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const base = [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }];
    await storage.writeJSON('cards.json', base);
    const theirsOnDisk = [{ id: 'a', title: 'A' }, { id: 'b', title: 'B (there)' }, { id: 'c', title: 'C' }];
    fs.writeFileSync(path.join(host.variables['place.boards'], 'cards.json'), JSON.stringify(theirsOnDisk));
    const mine = [{ id: 'a', title: 'A (here)' }, { id: 'b', title: 'B' }];
    const theirs = await storage.readJSON('cards.json');
    const result = threeWayMerge(base, mine, theirs.value);
    assert.equal(result.status, 'merged');
    const outcome = await storage.writeIfUnchanged('cards.json', result.records, theirs.version);
    assert.equal(outcome.written, true);
    assert.deepEqual((await storage.readJSON('cards.json')).value.map((card) => card.title), ['A (here)', 'B (there)', 'C']);
  });
});

// A stand-in for Vektor that answers storage/read with whatever `part(params)` returns, to test what the helper accepts.
const { Storage } = require('../dist');
const answering = (part) => new Storage({ request: async (method, params) => part(params) }, 'pl-test');
const notWhole = (error) => error.code === 'failed' && error.message === '“f.bin” was not read whole.';

test('a read in parts is checked whole: an empty part before the end, a part from another offset, or a short total is refused', async () => {
  const file = Buffer.alloc(600 * 1024, 65);
  const part = (params, overrides = {}) => {
    const bytes = file.subarray(params.offset, params.offset + params.length);
    return { content: bytes.toString('base64'), encoding: 'base64', version: 'v1.x', size: file.length, offset: params.offset,
      eof: params.offset + bytes.length >= file.length, ...overrides };
  };
  assert.equal((await answering((params) => part(params)).readBytes('f.bin')).value.length, file.length);
  await assert.rejects(answering((params) => part(params, params.offset > 0 ? { content: '', eof: false } : {})).readBytes('f.bin'), notWhole);
  await assert.rejects(answering((params) => part(params, params.offset > 0 ? { offset: params.offset + 1 } : {})).readBytes('f.bin'), notWhole);
  await assert.rejects(answering((params) => part(params, { size: file.length + 1 })).readBytes('f.bin'), notWhole);
  await assert.rejects(answering((params) => part(params, params.offset > 0 ? { content: 'QQ==', eof: true } : {})).readBytes('f.bin'), notWhole);
});

test('the test host reads a file byte for byte: a UTF-8 BOM is kept, bytes that are not UTF-8 come as base64', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const bom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('{"a":1}')]);
    fs.writeFileSync(path.join(host.variables['place.boards'], 'bom.json'), bom);
    assert.deepEqual((await storage.readBytes('bom.json')).value, bom);
    const binary = Buffer.from([0xff, 0x00, 0xfe]);
    fs.writeFileSync(path.join(host.variables['place.boards'], 'bin'), binary);
    assert.deepEqual((await storage.readBytes('bin')).value, binary);
  });
});

test('list ends at a page whose next is null, as at one without next', async () => {
  let calls = 0;
  const storage = new Storage({ request: async (method, params) => {
    if (++calls > 5) throw new Error(`still listing, cursor ${params.cursor}`);
    return params.cursor === undefined ? { entries: [{ name: 'a', isFolder: false }], next: 'cu-1' } : { entries: [{ name: 'b', isFolder: false }], next: null };
  } }, 'pl-test');
  assert.deepEqual((await storage.list()).map((entry) => entry.name), ['a', 'b']);
});

test('the test host checks ifVersion first, as Vektor parses it: before the file is looked at, on every part of a write', async () => {
  const inside = await withStorage();
  await inside(async (storage, host) => {
    const code = (method, params) => host.places.answer(method, { place: storage.place, ...params }).error?.code;
    assert.equal(code('storage/read', { path: 'missing.txt', ifVersion: null }), 'badRequest');
    assert.equal(code('storage/delete', { path: 'missing.txt', ifVersion: null }), 'badRequest');
    assert.equal(code('storage/read', { path: 'missing.txt', ifVersion: 'made-up' }), 'badRequest');
    assert.equal(code('storage/delete', { path: 'missing.txt', ifVersion: 'made-up' }), 'badRequest');
    assert.equal(code('storage/write', { path: 'part.txt', content: 'x', more: true, ifVersion: 'made-up' }), 'badRequest');
    const upload = host.places.answer('storage/write', { place: storage.place, path: 'part.txt', content: 'x', more: true }).result.upload;
    assert.equal(code('storage/write', { path: 'part.txt', content: 'y', more: true, upload, ifVersion: 7 }), 'badRequest');
    // A well-formed version of a file that is not there: Vektor answers notFound for a delete (it looks the item up first).
    assert.equal(code('storage/delete', { path: 'missing.txt', ifVersion: 'v1.l.1.2.3.4' }), 'notFound');
  });
});
