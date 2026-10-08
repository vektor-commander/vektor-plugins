#!/usr/bin/env node
// Hello Plugin (Node) - the Node plugin template (Vektor plugin API 1). Copy the folder, rename it in plugin.json, edit this file.
//
// A plugin is a program that Vektor starts when it is needed and talks to over stdin/stdout. Each message is
//
//     Content-Length: <bytes>\r\n
//     \r\n
//     <JSON body>
//
// Vektor sends requests (they carry an "id" and want an answer: startup, shutdown, invoke, ping) and notifications (no id:
// settingsChanged, view/opened, view/event, ...). You answer a request with {"id": ..., "result": ...} or
// {"id": ..., "error": {"message": ...}}. You may send Vektor notifications (log, toast, ...) and requests (dialog/show,
// openURL, ...) of your own. docs/reference.md lists every message with an example.
//
// Rules this file follows, each learned the hard way:
//   * Node is NOT installed by macOS. The user must install it (for example from nodejs.org or with Homebrew), and the plugin's
//     setting banner should say so. Vektor gives plugins a fixed PATH (/usr/bin, /opt/homebrew/bin, /usr/local/bin, ...), so a
//     Node installed by nvm, fnm or Volta is NOT found by `#!/usr/bin/env node`.
//   * Content-Length is a BYTE count. Always measure the encoded body (Buffer.byteLength), never string.length: one "e with an
//     accent" is two bytes. Read the body as bytes too, and decode it only when you have all of it.
//   * stdout carries messages and nothing else: never console.log. Diagnostics go to stderr (console.error) or to `log`.
//   * Answer `shutdown`, then exit. Stop everything you started; Vektor ends what is left after a short grace period.
//   * Keep state in $VEKTOR_PLUGIN_DATA, never inside this folder (it is replaced on update).
//   * No npm packages: this file needs only Node's own modules, so the plugin folder is the whole plugin.
'use strict';

let greeting = 'Hello';

// --- Wire -------------------------------------------------------------------------------------------------------------
function send(message) {
  const body = Buffer.from(JSON.stringify({ api: 1, ...message }), 'utf8');
  process.stdout.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii'), body]));
}
const notify = (method, params) => send({ method, params });
const reply = (id, result) => send({ id, result });
const refuse = (id, message) => send({ id, error: { message } });

// --- What the plugin does ---------------------------------------------------------------------------------------------
function onInvoke(id, params) {
  switch (params.command) {
    case 'hello': {
      // The items the command was chosen for: params.target.items is a list of {path, name, isFolder}.
      const count = (params.target && params.target.items ? params.target.items : []).length;
      // A reply with a "message" is shown to the user as a short notice. (Needs no permission: it only talks to you.)
      return reply(id, { message: `${greeting}! You chose ${count} item(s).` });
    }
    default:
      return refuse(id, `This plugin has no command “${params.command}”.`);
  }
}

function onMessage(message) {
  const { method, id, params = {} } = message;
  switch (method) {
    case 'startup':
      // params: vektorVersion, pluginID, settings (every setting, defaults filled in), workspace, dataFolder,
      // sessionTemporaryFolder, previousSessionEndedUncleanly.
      greeting = (params.settings && params.settings.greeting) || greeting;
      reply(id, {});
      return notify('log', { level: 'info', message: 'Hello Plugin started.' });
    case 'settingsChanged':
      greeting = (params.settings && params.settings.greeting) || greeting;
      return;
    case 'invoke':
      return onInvoke(id, params);
    case 'shutdown':
      // Answer, and leave only when the answer has been written.
      reply(id, {});
      return process.stdout.write('', () => process.exit(0));
    case 'ping':
      return reply(id, {});
    case '$/cancel':
      return;
    default:
      // An answer to a request of ours has no method (this plugin sends none). Anything else with an id gets an error.
      if (method && id !== undefined) refuse(id, 'unknown method');
  }
}

// --- Main loop --------------------------------------------------------------------------------------------------------
let pending = Buffer.alloc(0);

function drain() {
  for (;;) {
    const headerEnd = pending.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const header = pending.subarray(0, headerEnd).toString('latin1');
    const match = /^content-length:\s*(\d+)/im.exec(header);
    if (!match) { console.error('a message without Content-Length'); process.exit(1); }
    const length = Number(match[1]);
    if (pending.length < headerEnd + 4 + length) return;              // the rest of the body has not arrived yet
    const body = pending.subarray(headerEnd + 4, headerEnd + 4 + length).toString('utf8');
    pending = pending.subarray(headerEnd + 4 + length);
    let message;
    try { message = JSON.parse(body); } catch { console.error('a message that is not JSON'); continue; }
    try {
      onMessage(message);
    } catch (error) {
      // A bug or a failed write must not end the plugin: log it (stderr reaches the plugin's Log in Vektor) and answer a
      // request, so Vektor is not left waiting for a reply that never comes.
      console.error((error && error.stack) || String(error));
      if (message && message.method && message.id !== undefined) refuse(message.id, 'Something went wrong in the plugin; its log has the details.');
    }
  }
}

process.stdin.on('data', (chunk) => { pending = Buffer.concat([pending, chunk]); drain(); });
// End of file: Vektor is gone. Stop what you started (nothing here) and leave.
process.stdin.on('end', () => process.exit(0));
