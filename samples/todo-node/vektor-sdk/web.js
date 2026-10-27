"use strict";
// The plugin's side of the web view bridge (API 2). A page posts with `vektor.post(message)` and the plugin receives
// `web/message`; the plugin sends `web/post` and the page's `vektor.onmessage` receives it. Both are any JSON value up to
// 1 MB. This helper adds a convention both sides of the SDK share (the page side is `sdk/web/vektor-bridge.js`):
//
//   * a message is an object with a `type`: handlers are routed by it;
//   * a page's request carries `requestId`; what the handler returns goes back to the pages as
//     `{ type: "reply", replyTo, result }` (or `{ type: "reply", replyTo, error }` with plain words).
//
//     plugin.web('sketch').on('load', () => ({ strokes }));          // the page: await bridge.request('load')
//     plugin.web('sketch').on('save', (message) => { strokes = message.strokes; });
//     plugin.web('sketch').post({ type: 'cleared' });                 // the page: bridge.on('cleared', …)
Object.defineProperty(exports, "__esModule", { value: true });
exports.WebBridge = exports.MAX_WEB_MESSAGE_BYTES = void 0;
const errors_1 = require("./errors");
/** The largest message either way (Vektor's limit). */
exports.MAX_WEB_MESSAGE_BYTES = 1024 * 1024;
class WebBridge {
    plugin;
    view;
    handlers = new Map();
    fallback;
    constructor(plugin, view) {
        this.plugin = plugin;
        this.view = view;
    }
    /** Handles page messages whose `type` is `type`. For a request, the return value is the reply. */
    on(type, handler) {
        this.handlers.set(type, handler);
        return this;
    }
    /** Handles messages no `on` claims (and messages that are not objects with a `type`). */
    onAny(handler) {
        this.fallback = handler;
        return this;
    }
    /** Sends `message` to this plugin's pages showing the view — all of them, or only the `web` block `block`. */
    post(message, block) {
        const size = Buffer.byteLength(JSON.stringify(message), 'utf8');
        if (size > exports.MAX_WEB_MESSAGE_BYTES)
            throw new errors_1.PluginError(`A message to a page is at most 1 MB; this one is ${Math.ceil(size / 1024)} KB.`);
        this.plugin.notify('web/post', block === undefined ? { view: this.view, message } : { view: this.view, block, message });
    }
    /** Called by the plugin for this view's `web/message`. */
    async receive(params) {
        const message = params.message;
        const context = { view: params.view, block: params.block };
        const type = message && typeof message === 'object' && !Array.isArray(message) ? message.type : undefined;
        const handler = (typeof type === 'string' ? this.handlers.get(type) : undefined) ?? this.fallback;
        const requestId = message && typeof message === 'object' ? message.requestId : undefined;
        if (!handler) {
            if (requestId !== undefined)
                this.post({ type: 'reply', replyTo: requestId, error: `This plugin does not handle “${String(type)}”.` }, params.block);
            return;
        }
        try {
            const result = await handler(message, context);
            if (requestId !== undefined)
                this.post({ type: 'reply', replyTo: requestId, result: (result ?? null) }, params.block);
        }
        catch (error) {
            if (requestId === undefined)
                throw error;
            const text = error instanceof errors_1.PluginError ? error.message : errors_1.GENERIC_FAILURE;
            if (!(error instanceof errors_1.PluginError))
                process.stderr.write(`vektor-sdk: a web message handler failed: ${error?.stack ?? error}\n`);
            this.post({ type: 'reply', replyTo: requestId, error: text }, params.block);
        }
    }
}
exports.WebBridge = WebBridge;
