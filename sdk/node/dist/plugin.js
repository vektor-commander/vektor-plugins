"use strict";
// The protocol core: one `Plugin` per program. It reads framed messages from stdin, answers Vektor's requests through the
// handlers you register, sends your requests with ids and timeouts, and handles the parts every plugin gets wrong once:
// `ping`, `$/cancel`, `startup` state, `shutdown` with its grace period, end of input, and errors in plain words.
//
//     const { Plugin } = require('./vektor-sdk');
//     const plugin = new Plugin();
//     plugin.command('hello', (target) => `Hello! You chose ${target.items?.length ?? 0} item(s).`);
//     plugin.start();
Object.defineProperty(exports, "__esModule", { value: true });
exports.Plugin = exports.FIRST_REQUEST_ID = void 0;
const errors_1 = require("./errors");
const framing_1 = require("./framing");
const messages_1 = require("./messages");
const transport_1 = require("./transport");
const view_1 = require("./view");
const storage_1 = require("./storage");
const sidebar_1 = require("./sidebar");
const web_1 = require("./web");
/** The first id of the plugin's own requests (the reference: "start yours at 1000 or so"). */
exports.FIRST_REQUEST_ID = 1000;
class Plugin {
    /** The plugin API written on every message. */
    api;
    /** Every setting's value (defaults filled in), as of the latest `startup`, `settingsChanged` or `settings/get`. */
    settings = {};
    /** The active workspace, or null. */
    workspace = null;
    /** `startup`'s parameters once it arrived. */
    startupParams;
    transport;
    reader = new framing_1.MessageReader();
    diagnostics;
    shutdownGrace;
    requestTimeout;
    nextID = exports.FIRST_REQUEST_ID;
    pending = new Map();
    inFlight = new Map();
    requestHandlers = new Map();
    notificationHandlers = new Map();
    commands = new Map();
    startupHandlers = [];
    readyHandlers = [];
    shutdownHandlers = [];
    settingsHandlers = [];
    workspaceHandlers = [];
    views = new Map();
    bridges = new Map();
    sidebars = new Map();
    started = false;
    stopping = false;
    constructor(options = {}) {
        this.transport = options.transport ?? (0, transport_1.stdioTransport)();
        this.diagnostics = options.diagnostics ?? transport_1.logToStderr;
        this.shutdownGrace = options.shutdownGrace ?? 1500;
        this.requestTimeout = options.requestTimeout ?? 60;
        const fromEnvironment = Number(process.env.VEKTOR_PLUGIN_API);
        this.api = options.api ?? (Number.isInteger(fromEnvironment) && fromEnvironment >= 1 ? fromEnvironment : 2);
    }
    // --- Registering handlers ----------------------------------------------------------------------------------------------
    /** Runs when `startup` arrives, before it is answered. `settings`, `workspace` and `startupParams` are already set. */
    onStartup(handler) {
        this.startupHandlers.push(handler);
        return this;
    }
    /**
     * Runs right after `startup` has been answered: the place to send a first `view/update`, sidebar items or a badge, so a
     * Settings tab and the sidebar are ready before anyone opens a pane.
     */
    onReady(handler) {
        this.readyHandlers.push(handler);
        return this;
    }
    /** Runs on `shutdown` (after it is answered) and at the end of input: stop what you started. Bounded by the grace period. */
    onShutdown(handler) {
        this.shutdownHandlers.push(handler);
        return this;
    }
    /** `settingsChanged`. `settings` and `workspace` are already updated. */
    onSettingsChanged(handler) {
        this.settingsHandlers.push(handler);
        return this;
    }
    /** The active workspace changed: `workspace/changed` (API 2), or a `settingsChanged` naming another workspace. */
    onWorkspaceChanged(handler) {
        this.workspaceHandlers.push(handler);
        return this;
    }
    /**
     * A command of the manifest (`invoke`). Return nothing for `{}`, a string for a short notice, or an `InvokeResult`.
     * Throw a `PluginError` to show its message in an alert.
     */
    command(name, handler) {
        this.commands.set(name, handler);
        return this;
    }
    /** Any request method from Vektor (`decorations/get`, `info/get`, `footer/get`, or one this SDK does not type). */
    onRequest(method, handler) {
        this.requestHandlers.set(method, handler);
        return this;
    }
    /** Any notification from Vektor. Several handlers may listen to one method. */
    onNotification(method, handler) {
        const list = this.notificationHandlers.get(method) ?? [];
        list.push(handler);
        this.notificationHandlers.set(method, list);
        return this;
    }
    onDecorations(handler) {
        return this.onRequest(messages_1.Methods.decorationsGet, handler);
    }
    onInfo(handler) {
        return this.onRequest(messages_1.Methods.infoGet, handler);
    }
    onFooter(handler) {
        return this.onRequest(messages_1.Methods.footerGet, handler);
    }
    onProcessOutput(handler) {
        return this.onNotification(messages_1.Methods.processOutput, handler);
    }
    onProcessExited(handler) {
        return this.onNotification(messages_1.Methods.processExited, handler);
    }
    /** The state of a view the plugin describes: its description, revision, patches and event routing. */
    view(id, options) {
        let state = this.views.get(id);
        if (!state) {
            state = new view_1.ViewState(this, id, options);
            this.views.set(id, state);
        }
        return state;
    }
    /** The bridge to the plugin's web pages showing view `id` (a `web` view, or `web` blocks in a block view). */
    web(view) {
        let bridge = this.bridges.get(view);
        if (!bridge) {
            bridge = new web_1.WebBridge(this, view);
            this.bridges.set(view, bridge);
        }
        return bridge;
    }
    /** The items listed under sidebar entry `entry` (API 2). */
    sidebar(entry) {
        let items = this.sidebars.get(entry);
        if (!items) {
            items = new sidebar_1.SidebarItems(this, entry);
            this.sidebars.set(entry, items);
        }
        return items;
    }
    /** The storage service on a place (a `place` setting's value, or its `place` string). */
    storage(place) {
        return new storage_1.Storage(this, typeof place === 'string' ? place : place.place);
    }
    // --- Running -----------------------------------------------------------------------------------------------------------
    /** Starts reading messages. Call it once, after registering handlers. */
    start() {
        if (this.started)
            return this;
        this.started = true;
        this.transport.onData((chunk) => this.receive(chunk));
        this.transport.onEnd(() => void this.stop('endOfInput', false));
        return this;
    }
    /** Feeds bytes as if they came from stdin (the transport does this; tests may too). */
    receive(chunk) {
        let messages;
        try {
            messages = this.reader.push(chunk);
        }
        catch (error) {
            // A broken stream cannot be resynchronised: Vektor would end the plugin too.
            this.diagnostics(`vektor-sdk: ${error.message} Stopping.`);
            this.transport.exit(1);
            return;
        }
        for (const message of messages)
            this.dispatch(message);
    }
    dispatch(message) {
        if (typeof message.api === 'number' && Number.isInteger(message.api) && message.api >= 1)
            this.api = message.api;
        const { method, id } = message;
        const params = message.params ?? {};
        if (typeof method === 'string') {
            // A message with an id is a request and is answered, even one of a method Vektor usually sends as a notification.
            if (id !== undefined && id !== null)
                void this.handleRequest(id, method, params);
            else
                void this.handleNotification(method, params);
            return;
        }
        if (id !== undefined) {
            const waiting = this.pending.get(Number(id));
            if (!waiting)
                return; // an answer to a request that already timed out
            this.pending.delete(Number(id));
            if (waiting.timer !== undefined)
                clearTimeout(waiting.timer);
            if (message.error) {
                const error = message.error;
                waiting.reject(new errors_1.VektorError(waiting.method, String(error.message ?? 'Vektor refused the request.'), error.code, error.data));
            }
            else {
                waiting.resolve(message.result ?? {});
            }
        }
    }
    async handleRequest(id, method, params) {
        if (method === messages_1.Methods.ping)
            return this.reply(id, {});
        if (method === messages_1.Methods.shutdown) {
            this.reply(id, {});
            return this.stop(params.reason ?? 'quit', true);
        }
        const controller = new AbortController();
        const key = String(id);
        this.inFlight.set(key, controller);
        const context = {
            id, method, signal: controller.signal,
            throwIfCancelled: () => { if (controller.signal.aborted)
                throw new errors_1.CancelledError(); },
        };
        try {
            let result;
            switch (method) {
                case messages_1.Methods.startup:
                    this.startupParams = params;
                    this.settings = params.settings ?? {};
                    this.workspace = params.workspace ?? null;
                    for (const handler of this.startupHandlers)
                        await handler(params);
                    result = {};
                    break;
                case messages_1.Methods.invoke:
                    result = await this.invoke(params.command, params.target ?? {}, context);
                    break;
                default: {
                    const handler = this.requestHandlers.get(method);
                    if (handler) {
                        result = (await handler(params, context)) ?? {};
                    }
                    else if (messages_1.VEKTOR_NOTIFICATIONS.has(method) || this.notificationHandlers.has(method)) {
                        await this.handleNotification(method, params);
                        result = {};
                    }
                    else {
                        throw new errors_1.PluginError(`This plugin does not handle “${method}”.`);
                    }
                }
            }
            this.reply(id, result);
        }
        catch (error) {
            this.replyError(id, error);
            return;
        }
        finally {
            this.inFlight.delete(key);
        }
        if (method === messages_1.Methods.startup) {
            for (const handler of this.readyHandlers) {
                try {
                    await handler(params);
                }
                catch (error) {
                    this.report('a ready handler failed', error);
                }
            }
        }
    }
    async invoke(command, target, context) {
        const handler = this.commands.get(command);
        if (!handler)
            throw new errors_1.PluginError(`This plugin has no command “${command}”.`);
        const result = await handler(target, context);
        if (typeof result === 'string')
            return { message: result };
        if (result && typeof result === 'object')
            return result;
        return {};
    }
    async handleNotification(method, params) {
        try {
            switch (method) {
                case messages_1.Methods.cancel:
                    this.inFlight.get(String(params.id))?.abort();
                    break;
                case messages_1.Methods.settingsChanged:
                    await this.applySettings(params);
                    break;
                case messages_1.Methods.workspaceChanged:
                    await this.applyWorkspace({ id: params.id, name: params.name });
                    break;
                case messages_1.Methods.viewOpened:
                case messages_1.Methods.viewClosed:
                case messages_1.Methods.viewEvent:
                case messages_1.Methods.viewRefused: {
                    const state = this.views.get(params.view);
                    if (state)
                        await state.receive(method, params);
                    break;
                }
                case messages_1.Methods.webMessage: {
                    const bridge = this.bridges.get(params.view);
                    if (bridge)
                        await bridge.receive(params);
                    break;
                }
            }
            for (const handler of this.notificationHandlers.get(method) ?? [])
                await handler(params);
        }
        catch (error) {
            this.report(`a “${method}” handler failed`, error);
        }
    }
    async applySettings(params) {
        this.settings = params.settings ?? {};
        const before = this.workspace;
        const workspace = params.workspace === undefined ? before : params.workspace;
        for (const handler of this.settingsHandlers)
            await handler(this.settings, workspace);
        // An API 1 plugin hears of a switch only here; an API 2 one hears it from workspace/changed as well.
        if ((before?.id ?? null) !== (workspace?.id ?? null))
            await this.applyWorkspace(workspace);
    }
    async applyWorkspace(workspace) {
        if ((this.workspace?.id ?? null) === (workspace?.id ?? null) && this.workspace?.name === workspace?.name) {
            this.workspace = workspace;
            return;
        }
        this.workspace = workspace;
        for (const handler of this.workspaceHandlers)
            await handler(workspace);
        for (const items of this.sidebars.values())
            await items.refresh();
    }
    /**
     * Leaves: cancels work in flight, runs the shutdown handlers for at most the grace period, and exits. `shutdown` is
     * answered before this runs; at the end of input there is nobody to answer.
     */
    async stop(reason, answered) {
        if (this.stopping)
            return;
        this.stopping = true;
        void answered;
        for (const controller of this.inFlight.values())
            controller.abort();
        for (const [id, waiting] of this.pending) {
            if (waiting.timer !== undefined)
                clearTimeout(waiting.timer);
            waiting.reject(new errors_1.CancelledError('The plugin is stopping.'));
            this.pending.delete(id);
        }
        const handlers = Promise.all(this.shutdownHandlers.map(async (handler) => {
            try {
                await handler(reason);
            }
            catch (error) {
                this.report('a shutdown handler failed', error);
            }
        }));
        let timer;
        const grace = new Promise((resolve) => {
            timer = setTimeout(() => {
                this.diagnostics(`vektor-sdk: shutdown handlers took longer than ${this.shutdownGrace} ms; leaving anyway.`);
                resolve();
            }, this.shutdownGrace);
        });
        await Promise.race([handlers, grace]);
        clearTimeout(timer);
        this.transport.exit(0);
    }
    // --- Sending -----------------------------------------------------------------------------------------------------------
    write(message) {
        this.transport.write((0, framing_1.encodeMessage)({ api: this.api, ...message }));
    }
    reply(id, result) {
        this.write({ id, result: result ?? {} });
    }
    replyError(id, error) {
        if (error instanceof errors_1.PluginError) {
            const body = { message: error.message };
            if (error.code && !(error instanceof errors_1.VektorError) && !(error instanceof errors_1.CancelledError) && !(error instanceof errors_1.TimeoutError))
                body.code = error.code;
            this.write({ id, error: body });
        }
        else {
            this.report('a request handler failed', error);
            this.write({ id, error: { message: errors_1.GENERIC_FAILURE } });
        }
    }
    report(what, error) {
        const detail = error instanceof Error ? (error.stack ?? error.message) : String(error);
        this.diagnostics(`vektor-sdk: ${what}: ${detail}`);
    }
    notify(method, params) {
        this.write({ method, params: params ?? {} });
    }
    request(method, params, options = {}) {
        if (this.stopping)
            return Promise.reject(new errors_1.CancelledError('The plugin is stopping.'));
        const id = this.nextID++;
        const waitsForUser = method === messages_1.Methods.dialogShow || method === messages_1.Methods.confirm;
        const seconds = options.timeout ?? (waitsForUser ? 0 : this.requestTimeout);
        return new Promise((resolve, reject) => {
            const waiting = { method, resolve, reject };
            if (seconds > 0) {
                waiting.timer = setTimeout(() => {
                    this.pending.delete(id);
                    reject(new errors_1.TimeoutError(method, seconds));
                }, seconds * 1000);
            }
            if (options.signal) {
                if (options.signal.aborted)
                    return reject(new errors_1.CancelledError());
                options.signal.addEventListener('abort', () => {
                    if (!this.pending.delete(id))
                        return;
                    if (waiting.timer !== undefined)
                        clearTimeout(waiting.timer);
                    reject(new errors_1.CancelledError());
                });
            }
            this.pending.set(id, waiting);
            this.write({ id, method, params: params ?? {} });
        });
    }
    // --- Services, typed ---------------------------------------------------------------------------------------------------
    /** A line in the plugin's Log in Vektor. */
    log(message, level = 'info') { this.notify(messages_1.Methods.log, { level, message }); }
    toast(message) { this.notify(messages_1.Methods.toast, { message }); }
    alert(title, message) { this.notify(messages_1.Methods.alert, { title, message }); }
    async confirm(params) {
        return (await this.request(messages_1.Methods.confirm, params)).confirmed === true;
    }
    copyText(text) { this.notify(messages_1.Methods.clipboardWriteText, { text }); }
    /** Asks Vektor for the settings now; also updates `settings` and `workspace`. */
    async getSettings() {
        const result = await this.request(messages_1.Methods.settingsGet, {});
        this.settings = result.settings ?? {};
        if (result.workspace !== undefined)
            this.workspace = result.workspace;
        return result;
    }
    /** A status line under a setting; empty `text` clears it. */
    setStatus(params) { this.notify(messages_1.Methods.settingsStatus, params); }
    showDialog(params) {
        // A cancel may come without `values` (older Vektor): always hand back an object.
        return this.request(messages_1.Methods.dialogShow, params).then((answer) => ({ ...answer, values: answer?.values ?? {} }));
    }
    openURL(url) { return this.request(messages_1.Methods.openURL, { url }); }
    navigate(path, placement) {
        return this.request(messages_1.Methods.navigate, placement ? { path, placement } : { path });
    }
    reveal(path) { return this.request(messages_1.Methods.reveal, { path }); }
    async startProcess(params) { return (await this.request(messages_1.Methods.processStart, params)).processID; }
    stopProcess(processID) { return this.request(messages_1.Methods.processStop, { processID }); }
    async readSecret(key) { return (await this.request(messages_1.Methods.secretsRead, { key })).value; }
    writeSecret(key, value) { return this.request(messages_1.Methods.secretsWrite, { key, value }); }
    deleteSecret(key) { return this.request(messages_1.Methods.secretsDelete, { key }); }
    /** A sidebar entry's badge; neither a count above zero nor a text clears it. */
    setBadge(params) { this.notify(messages_1.Methods.sidebarBadge, params); }
    /** Your decorations went stale: for these paths, or all. */
    decorationsChanged(paths) { this.notify(messages_1.Methods.decorationsChanged, paths ? { paths } : {}); }
    footerChanged() { this.notify(messages_1.Methods.footerChanged, {}); }
    /** The data folder: `startup`'s `dataFolder`, else `$VEKTOR_PLUGIN_DATA`. */
    get dataFolder() {
        return this.startupParams?.dataFolder ?? process.env.VEKTOR_PLUGIN_DATA;
    }
    /** Requests of the plugin still waiting for an answer (diagnostics, tests). */
    get pendingRequests() { return this.pending.size; }
}
exports.Plugin = Plugin;
