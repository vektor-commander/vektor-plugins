/*
 * vektor-bridge.js — the page's side of the web view bridge (plugin API 2). Copy it into your plugin's folder next to your
 * page and load it before your own script:
 *
 *     <script src="vektor-bridge.js"></script>
 *
 * Vektor defines `vektor` before any script runs: `vektor.post(message)` reaches your plugin as `web/message`, and your
 * plugin's `web/post` arrives as the `vektor-message` event (and `vektor.onmessage`). This file adds what every page
 * writes otherwise, in the convention the SDKs' plugin side (`plugin.web(view)`) understands:
 *
 *     VektorBridge.on('strokes', (message) => draw(message.strokes));         // a push from the plugin, by `type`
 *     VektorBridge.post({ type: 'save', strokes });                           // a message to the plugin
 *     const { strokes } = await VektorBridge.request('load');                 // a question with an answer
 *     VektorBridge.onTheme(() => draw());                                      // the theme or accent changed
 *     VektorBridge.role('label3')                                              // a colour role's mark colour, as CSS
 *
 * Nothing here reaches the network or the file system: the page can talk only to its own plugin. Opened outside Vektor
 * (a browser preview while you build it), `available` is false and posts are logged to the console instead.
 */
(function () {
  'use strict';

  var MAX_BYTES = 1024 * 1024;
  var host = typeof window.vektor === 'object' && window.vektor && typeof window.vektor.post === 'function' ? window.vektor : null;
  var handlers = {};
  var anyHandlers = [];
  var pending = {};
  var counter = 0;
  var prefix = Math.random().toString(36).slice(2, 8);

  function size(message) {
    var text = JSON.stringify(message);
    return typeof TextEncoder === 'function' ? new TextEncoder().encode(text).length : text.length;
  }

  function deliver(message) {
    if (message && typeof message === 'object' && message.type === 'reply' && Object.prototype.hasOwnProperty.call(pending, message.replyTo)) {
      var waiting = pending[message.replyTo];
      delete pending[message.replyTo];
      clearTimeout(waiting.timer);
      if (message.error !== undefined) waiting.reject(new Error(String(message.error)));
      else waiting.resolve(message.result);
      return;
    }
    if (message && typeof message === 'object' && message.type === 'reply') return; // another page's answer
    var type = message && typeof message === 'object' ? message.type : undefined;
    var list = (typeof type === 'string' && handlers[type]) || anyHandlers;
    for (var index = 0; index < list.length; index++) {
      try { list[index](message); } catch (error) { console.error(error); }
    }
  }

  // The event, not `vektor.onmessage`, so a page that also sets `onmessage` itself keeps both.
  window.addEventListener('vektor-message', function (event) { deliver(event.detail); });

  var bridge = {
    /** Whether the page runs in Vektor (false in a browser preview). */
    available: host !== null,

    /** Sends a JSON value (at most 1 MB) to the plugin. */
    post: function (message) {
      if (size(message) > MAX_BYTES) throw new Error('A message to the plugin is at most 1 MB.');
      if (host) host.post(message);
      else console.info('[outside Vektor] would post', message);
    },

    /**
     * Asks the plugin and resolves with its answer: posts `{ type, requestId, ...fields }` and waits for
     * `{ type: "reply", replyTo, result }` (or rejects with the plugin's words). `timeout` in milliseconds, default 10 s.
     */
    request: function (type, fields, options) {
      var timeout = (options && options.timeout) || 10000;
      var requestId = prefix + '-' + (++counter);
      var message = { type: type, requestId: requestId };
      if (fields) for (var key in fields) if (Object.prototype.hasOwnProperty.call(fields, key)) message[key] = fields[key];
      return new Promise(function (resolve, reject) {
        var timer = setTimeout(function () {
          delete pending[requestId];
          reject(new Error('The plugin did not answer “' + type + '” in time.'));
        }, timeout);
        pending[requestId] = { resolve: resolve, reject: reject, timer: timer };
        try { bridge.post(message); } catch (error) { clearTimeout(timer); delete pending[requestId]; reject(error); }
        if (!host) { clearTimeout(timer); delete pending[requestId]; reject(new Error('Not in Vektor: there is no plugin to ask.')); }
      });
    },

    /** Calls `handler(message)` for messages from the plugin whose `type` is `type`. */
    on: function (type, handler) {
      (handlers[type] = handlers[type] || []).push(handler);
      return bridge;
    },

    /** Calls `handler(message)` for messages no `on` handler claims. */
    onAny: function (handler) {
      anyHandlers.push(handler);
      return bridge;
    },

    /** Calls `handler()` whenever Vektor's theme or accent changes (the CSS properties are already updated). */
    onTheme: function (handler) {
      window.addEventListener('vektor-theme', function () { handler(); });
      return bridge;
    },

    /** A theme value by its CSS property name without `--vektor-` (`color-accent-primary`, `font-size`). */
    value: function (name) {
      return getComputedStyle(document.documentElement).getPropertyValue('--vektor-' + name).trim();
    },

    /** A colour role's colour (`part`: `mark` — the default —, `text` or `fill`), for a canvas that cannot use CSS. */
    role: function (name, part) {
      return bridge.value('role-' + name + '-' + (part || 'mark'));
    },

    /** Whether the active theme is a light one. */
    isLight: function () {
      return bridge.value('theme-light') === '1';
    }
  };

  window.VektorBridge = bridge;
})();
