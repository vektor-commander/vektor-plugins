// The protocol core: one `Plugin` per program. It reads framed messages from stdin, answers Vektor's requests through the
// handlers you register, sends your requests with ids and timeouts, and handles the parts every plugin gets wrong once:
// `ping`, `$/cancel`, `startup` state, `shutdown` with its grace period, end of input, and errors in plain words.
//
//     const { Plugin } = require('./vektor-sdk');
//     const plugin = new Plugin();
//     plugin.command('hello', (target) => `Hello! You chose ${target.items?.length ?? 0} item(s).`);
//     plugin.start();

import { CancelledError, FramingError, GENERIC_FAILURE, PluginError, TimeoutError, VektorError } from './errors';
import { encodeMessage, MessageReader } from './framing';
import {
  Methods, VEKTOR_NOTIFICATIONS,
  type AlertParams, type ConfirmParams, type DecorationsGetParams, type DecorationsGetResult, type DialogShowParams,
  type DialogShowResult, type FooterGetParams, type FooterGetResult, type InfoGetParams, type InfoGetResult, type InvokeResult,
  type InvokeTarget, type JSONObject, type JSONValue, type LogLevel, type NavigateParams, type PluginNotifications,
  type PluginRequests, type ProcessExitedParams, type ProcessOutputParams, type ProcessStartParams, type SettingsChangedParams,
  type SettingsGetResult, type SettingsStatusParams, type ShutdownReason, type SidebarBadgeParams, type StartupParams,
  type ViewEventParams, type ViewOpenedParams, type ViewClosedParams, type WebMessageParams, type Workspace,
  type WorkspaceChangedParams,
} from './messages';
import { logToStderr, stdioTransport, type Transport } from './transport';
import { ViewState, type ViewStateOptions } from './view';
import { Storage } from './storage';
import { SidebarItems } from './sidebar';
import { WebBridge } from './web';

export interface PluginOptions {
  /** Defaults to stdin/stdout. The test kit passes an in-memory one. */
  transport?: Transport;
  /** The `api` written on every message. Default: what Vektor writes to this plugin (its manifest's), else
   *  `$VEKTOR_PLUGIN_API`, else 2. */
  api?: number;
  /** How long `onShutdown` handlers may take before the plugin leaves anyway, in milliseconds. Vektor's grace period is
   *  about 2 s (about 3 s for all plugins together at quit); the default leaves room for the exit itself. */
  shutdownGrace?: number;
  /** Default timeout of the plugin's own requests, in seconds (dialogs and confirmations wait for the user: no timeout). */
  requestTimeout?: number;
  /** Where the SDK's own diagnostics go. Default: stderr (the plugin's Log in Vektor). */
  diagnostics?: (text: string) => void;
}

/** What a request handler gets besides its parameters. */
export interface RequestContext {
  /** The request's id. */
  id: number | string;
  method: string;
  /** Aborted when Vektor sends `$/cancel` for this request, or the plugin is stopping. */
  signal: AbortSignal;
  /** Throws `CancelledError` once the request was cancelled. Call it between steps of long work. */
  throwIfCancelled(): void;
}

type RequestHandler = (params: any, context: RequestContext) => unknown | Promise<unknown>;
type NotificationHandler = (params: any) => void | Promise<void>;
type Pending = { method: string; resolve: (value: any) => void; reject: (error: Error) => void; timer?: unknown };

/** The first id of the plugin's own requests (the reference: "start yours at 1000 or so"). */
export const FIRST_REQUEST_ID = 1000;

export class Plugin {
  /** The plugin API written on every message. */
  api: number;
  /** Every setting's value (defaults filled in), as of the latest `startup`, `settingsChanged` or `settings/get`. */
  settings: JSONObject = {};
  /** The active workspace, or null. */
  workspace: Workspace | null = null;
  /** `startup`'s parameters once it arrived. */
  startupParams?: StartupParams;

  private readonly transport: Transport;
  private readonly reader = new MessageReader();
  private readonly diagnostics: (text: string) => void;
  private readonly shutdownGrace: number;
  private readonly requestTimeout: number;
  private nextID = FIRST_REQUEST_ID;
  private readonly pending = new Map<number, Pending>();
  private readonly inFlight = new Map<string, AbortController>();
  private readonly requestHandlers = new Map<string, RequestHandler>();
  private readonly notificationHandlers = new Map<string, NotificationHandler[]>();
  private readonly commands = new Map<string, (target: InvokeTarget, context: RequestContext) => unknown>();
  private readonly startupHandlers: ((params: StartupParams) => unknown)[] = [];
  private readonly readyHandlers: ((params: StartupParams) => unknown)[] = [];
  private readonly shutdownHandlers: ((reason: ShutdownReason) => unknown)[] = [];
  private readonly settingsHandlers: ((settings: JSONObject, workspace: Workspace | null) => unknown)[] = [];
  private readonly workspaceHandlers: ((workspace: Workspace | null) => unknown)[] = [];
  private readonly views = new Map<string, ViewState>();
  private readonly bridges = new Map<string, WebBridge>();
  private readonly sidebars = new Map<string, SidebarItems>();
  private started = false;
  private stopping = false;

  constructor(options: PluginOptions = {}) {
    this.transport = options.transport ?? stdioTransport();
    this.diagnostics = options.diagnostics ?? logToStderr;
    this.shutdownGrace = options.shutdownGrace ?? 1500;
    this.requestTimeout = options.requestTimeout ?? 60;
    const fromEnvironment = Number(process.env.VEKTOR_PLUGIN_API);
    this.api = options.api ?? (Number.isInteger(fromEnvironment) && fromEnvironment >= 1 ? fromEnvironment : 2);
  }

  // --- Registering handlers ----------------------------------------------------------------------------------------------

  /** Runs when `startup` arrives, before it is answered. `settings`, `workspace` and `startupParams` are already set. */
  onStartup(handler: (params: StartupParams) => unknown): this {
    this.startupHandlers.push(handler);
    return this;
  }

  /**
   * Runs right after `startup` has been answered: the place to send a first `view/update`, sidebar items or a badge, so a
   * Settings tab and the sidebar are ready before anyone opens a pane.
   */
  onReady(handler: (params: StartupParams) => unknown): this {
    this.readyHandlers.push(handler);
    return this;
  }

  /** Runs on `shutdown` (after it is answered) and at the end of input: stop what you started. Bounded by the grace period. */
  onShutdown(handler: (reason: ShutdownReason) => unknown): this {
    this.shutdownHandlers.push(handler);
    return this;
  }

  /** `settingsChanged`. `settings` and `workspace` are already updated. */
  onSettingsChanged(handler: (settings: JSONObject, workspace: Workspace | null) => unknown): this {
    this.settingsHandlers.push(handler);
    return this;
  }

  /** The active workspace changed: `workspace/changed` (API 2), or a `settingsChanged` naming another workspace. */
  onWorkspaceChanged(handler: (workspace: Workspace | null) => unknown): this {
    this.workspaceHandlers.push(handler);
    return this;
  }

  /**
   * A command of the manifest (`invoke`). Return nothing for `{}`, a string for a short notice, or an `InvokeResult`.
   * Throw a `PluginError` to show its message in an alert.
   */
  command(name: string, handler: (target: InvokeTarget, context: RequestContext) => unknown): this {
    this.commands.set(name, handler);
    return this;
  }

  /** Any request method from Vektor (`decorations/get`, `info/get`, `footer/get`, or one this SDK does not type). */
  onRequest(method: string, handler: RequestHandler): this {
    this.requestHandlers.set(method, handler);
    return this;
  }

  /** Any notification from Vektor. Several handlers may listen to one method. */
  onNotification(method: string, handler: NotificationHandler): this {
    const list = this.notificationHandlers.get(method) ?? [];
    list.push(handler);
    this.notificationHandlers.set(method, list);
    return this;
  }

  onDecorations(handler: (params: DecorationsGetParams, context: RequestContext) => DecorationsGetResult | Promise<DecorationsGetResult>): this {
    return this.onRequest(Methods.decorationsGet, handler);
  }
  onInfo(handler: (params: InfoGetParams, context: RequestContext) => InfoGetResult | Promise<InfoGetResult>): this {
    return this.onRequest(Methods.infoGet, handler);
  }
  onFooter(handler: (params: FooterGetParams, context: RequestContext) => FooterGetResult | Promise<FooterGetResult>): this {
    return this.onRequest(Methods.footerGet, handler);
  }
  onProcessOutput(handler: (params: ProcessOutputParams) => void): this {
    return this.onNotification(Methods.processOutput, handler);
  }
  onProcessExited(handler: (params: ProcessExitedParams) => void): this {
    return this.onNotification(Methods.processExited, handler);
  }

  /** The state of a view the plugin describes: its description, revision, patches and event routing. */
  view(id: string, options?: ViewStateOptions): ViewState {
    let state = this.views.get(id);
    if (!state) {
      state = new ViewState(this, id, options);
      this.views.set(id, state);
    }
    return state;
  }

  /** The bridge to the plugin's web pages showing view `id` (a `web` view, or `web` blocks in a block view). */
  web(view: string): WebBridge {
    let bridge = this.bridges.get(view);
    if (!bridge) {
      bridge = new WebBridge(this, view);
      this.bridges.set(view, bridge);
    }
    return bridge;
  }

  /** The items listed under sidebar entry `entry` (API 2). */
  sidebar(entry: string): SidebarItems {
    let items = this.sidebars.get(entry);
    if (!items) {
      items = new SidebarItems(this, entry);
      this.sidebars.set(entry, items);
    }
    return items;
  }

  /** The storage service on a place (a `place` setting's value, or its `place` string). */
  storage(place: string | { place: string }): Storage {
    return new Storage(this, typeof place === 'string' ? place : place.place);
  }

  // --- Running -----------------------------------------------------------------------------------------------------------

  /** Starts reading messages. Call it once, after registering handlers. */
  start(): this {
    if (this.started) return this;
    this.started = true;
    this.transport.onData((chunk) => this.receive(chunk));
    this.transport.onEnd(() => void this.stop('endOfInput', false));
    return this;
  }

  /** Feeds bytes as if they came from stdin (the transport does this; tests may too). */
  receive(chunk: Uint8Array): void {
    let messages: unknown[];
    try {
      messages = this.reader.push(chunk);
    } catch (error) {
      // A broken stream cannot be resynchronised: Vektor would end the plugin too.
      this.diagnostics(`vektor-sdk: ${(error as Error).message} Stopping.`);
      this.transport.exit(1);
      return;
    }
    for (const message of messages) this.dispatch(message as Record<string, any>);
  }

  private dispatch(message: Record<string, any>): void {
    if (typeof message.api === 'number' && Number.isInteger(message.api) && message.api >= 1) this.api = message.api;
    const { method, id } = message;
    const params = message.params ?? {};
    if (typeof method === 'string') {
      // A message with an id is a request and is answered, even one of a method Vektor usually sends as a notification.
      if (id !== undefined && id !== null) void this.handleRequest(id, method, params);
      else void this.handleNotification(method, params);
      return;
    }
    if (id !== undefined) {
      const waiting = this.pending.get(Number(id));
      if (!waiting) return; // an answer to a request that already timed out
      this.pending.delete(Number(id));
      if (waiting.timer !== undefined) clearTimeout(waiting.timer);
      if (message.error) {
        const error = message.error;
        waiting.reject(new VektorError(waiting.method, String(error.message ?? 'Vektor refused the request.'), error.code, error.data));
      } else {
        waiting.resolve(message.result ?? {});
      }
    }
  }

  private async handleRequest(id: number | string, method: string, params: any): Promise<void> {
    if (method === Methods.ping) return this.reply(id, {});
    if (method === Methods.shutdown) {
      this.reply(id, {});
      return this.stop(params.reason ?? 'quit', true);
    }
    const controller = new AbortController();
    const key = String(id);
    this.inFlight.set(key, controller);
    const context: RequestContext = {
      id, method, signal: controller.signal,
      throwIfCancelled: () => { if (controller.signal.aborted) throw new CancelledError(); },
    };
    try {
      let result: unknown;
      switch (method) {
        case Methods.startup:
          this.startupParams = params;
          this.settings = params.settings ?? {};
          this.workspace = params.workspace ?? null;
          for (const handler of this.startupHandlers) await handler(params);
          result = {};
          break;
        case Methods.invoke:
          result = await this.invoke(params.command, params.target ?? {}, context);
          break;
        default: {
          const handler = this.requestHandlers.get(method);
          if (handler) {
            result = (await handler(params, context)) ?? {};
          } else if (VEKTOR_NOTIFICATIONS.has(method) || this.notificationHandlers.has(method)) {
            await this.handleNotification(method, params);
            result = {};
          } else {
            throw new PluginError(`This plugin does not handle “${method}”.`);
          }
        }
      }
      this.reply(id, result);
    } catch (error) {
      this.replyError(id, error);
      return;
    } finally {
      this.inFlight.delete(key);
    }
    if (method === Methods.startup) {
      for (const handler of this.readyHandlers) {
        try { await handler(params); } catch (error) { this.report('a ready handler failed', error); }
      }
    }
  }

  private async invoke(command: string, target: InvokeTarget, context: RequestContext): Promise<InvokeResult> {
    const handler = this.commands.get(command);
    if (!handler) throw new PluginError(`This plugin has no command “${command}”.`);
    const result = await handler(target, context);
    if (typeof result === 'string') return { message: result };
    if (result && typeof result === 'object') return result as InvokeResult;
    return {};
  }

  private async handleNotification(method: string, params: any): Promise<void> {
    try {
      switch (method) {
        case Methods.cancel:
          this.inFlight.get(String(params.id))?.abort();
          break;
        case Methods.settingsChanged:
          await this.applySettings(params);
          break;
        case Methods.workspaceChanged:
          await this.applyWorkspace({ id: params.id, name: params.name });
          break;
        case Methods.viewOpened:
        case Methods.viewClosed:
        case Methods.viewEvent:
        case Methods.viewRefused: {
          const state = this.views.get(params.view);
          if (state) await state.receive(method, params);
          break;
        }
        case Methods.webMessage: {
          const bridge = this.bridges.get(params.view);
          if (bridge) await bridge.receive(params as WebMessageParams);
          break;
        }
      }
      for (const handler of this.notificationHandlers.get(method) ?? []) await handler(params);
    } catch (error) {
      this.report(`a “${method}” handler failed`, error);
    }
  }

  private async applySettings(params: SettingsChangedParams): Promise<void> {
    this.settings = params.settings ?? {};
    const before = this.workspace;
    const workspace = params.workspace === undefined ? before : params.workspace;
    for (const handler of this.settingsHandlers) await handler(this.settings, workspace);
    // An API 1 plugin hears of a switch only here; an API 2 one hears it from workspace/changed as well.
    if ((before?.id ?? null) !== (workspace?.id ?? null)) await this.applyWorkspace(workspace);
  }

  private async applyWorkspace(workspace: Workspace | null): Promise<void> {
    if ((this.workspace?.id ?? null) === (workspace?.id ?? null) && this.workspace?.name === workspace?.name) {
      this.workspace = workspace;
      return;
    }
    this.workspace = workspace;
    for (const handler of this.workspaceHandlers) await handler(workspace);
    for (const items of this.sidebars.values()) await items.refresh();
  }

  /**
   * Leaves: cancels work in flight, runs the shutdown handlers for at most the grace period, and exits. `shutdown` is
   * answered before this runs; at the end of input there is nobody to answer.
   */
  async stop(reason: ShutdownReason, answered: boolean): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    void answered;
    for (const controller of this.inFlight.values()) controller.abort();
    for (const [id, waiting] of this.pending) {
      if (waiting.timer !== undefined) clearTimeout(waiting.timer);
      waiting.reject(new CancelledError('The plugin is stopping.'));
      this.pending.delete(id);
    }
    const handlers = Promise.all(this.shutdownHandlers.map(async (handler) => {
      try { await handler(reason); } catch (error) { this.report('a shutdown handler failed', error); }
    }));
    let timer: unknown;
    const grace = new Promise<void>((resolve) => { timer = setTimeout(() => {
      this.diagnostics(`vektor-sdk: shutdown handlers took longer than ${this.shutdownGrace} ms; leaving anyway.`);
      resolve();
    }, this.shutdownGrace); });
    await Promise.race([handlers, grace]);
    clearTimeout(timer);
    this.transport.exit(0);
  }

  // --- Sending -----------------------------------------------------------------------------------------------------------

  private write(message: Record<string, unknown>): void {
    this.transport.write(encodeMessage({ api: this.api, ...message }));
  }

  private reply(id: number | string, result: unknown): void {
    this.write({ id, result: result ?? {} });
  }

  private replyError(id: number | string, error: unknown): void {
    if (error instanceof PluginError) {
      const body: Record<string, unknown> = { message: error.message };
      if (error.code && !(error instanceof VektorError) && !(error instanceof CancelledError) && !(error instanceof TimeoutError)) body.code = error.code;
      this.write({ id, error: body });
    } else {
      this.report('a request handler failed', error);
      this.write({ id, error: { message: GENERIC_FAILURE } });
    }
  }

  private report(what: string, error: unknown): void {
    const detail = error instanceof Error ? (error.stack ?? error.message) : String(error);
    this.diagnostics(`vektor-sdk: ${what}: ${detail}`);
  }

  /** Sends a notification. */
  notify<M extends keyof PluginNotifications>(method: M, params: PluginNotifications[M]): void;
  notify(method: string, params: unknown): void;
  notify(method: string, params: unknown): void {
    this.write({ method, params: params ?? {} });
  }

  /**
   * Sends a request and resolves with its result. Rejects with `VektorError` (Vektor refused, in plain words; `code` and
   * `data` when it gave them), `TimeoutError`, or `CancelledError` (the `signal` was aborted, or the plugin is stopping).
   * `timeout` is in seconds; `0` waits for ever (the default for `dialog/show` and `confirm`, which wait for the user).
   */
  request<M extends keyof PluginRequests>(method: M, params: PluginRequests[M][0], options?: { timeout?: number; signal?: AbortSignal }): Promise<PluginRequests[M][1]>;
  request(method: string, params: unknown, options?: { timeout?: number; signal?: AbortSignal }): Promise<any>;
  request(method: string, params: unknown, options: { timeout?: number; signal?: AbortSignal } = {}): Promise<any> {
    if (this.stopping) return Promise.reject(new CancelledError('The plugin is stopping.'));
    const id = this.nextID++;
    const waitsForUser = method === Methods.dialogShow || method === Methods.confirm;
    const seconds = options.timeout ?? (waitsForUser ? 0 : this.requestTimeout);
    return new Promise((resolve, reject) => {
      const waiting: Pending = { method, resolve, reject };
      if (seconds > 0) {
        waiting.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new TimeoutError(method, seconds));
        }, seconds * 1000);
      }
      if (options.signal) {
        if (options.signal.aborted) return reject(new CancelledError());
        options.signal.addEventListener('abort', () => {
          if (!this.pending.delete(id)) return;
          if (waiting.timer !== undefined) clearTimeout(waiting.timer);
          reject(new CancelledError());
        });
      }
      this.pending.set(id, waiting);
      this.write({ id, method, params: params ?? {} });
    });
  }

  // --- Services, typed ---------------------------------------------------------------------------------------------------

  /** A line in the plugin's Log in Vektor. */
  log(message: string, level: LogLevel = 'info'): void { this.notify(Methods.log, { level, message }); }
  toast(message: string): void { this.notify(Methods.toast, { message }); }
  alert(title: string, message: string): void { this.notify(Methods.alert, { title, message } as AlertParams); }
  async confirm(params: ConfirmParams): Promise<boolean> {
    return (await this.request(Methods.confirm, params)).confirmed === true;
  }
  copyText(text: string): void { this.notify(Methods.clipboardWriteText, { text }); }
  /** Asks Vektor for the settings now; also updates `settings` and `workspace`. */
  async getSettings(): Promise<SettingsGetResult> {
    const result = await this.request(Methods.settingsGet, {});
    this.settings = result.settings ?? {};
    if (result.workspace !== undefined) this.workspace = result.workspace;
    return result;
  }
  /** A status line under a setting; empty `text` clears it. */
  setStatus(params: SettingsStatusParams): void { this.notify(Methods.settingsStatus, params); }
  showDialog(params: DialogShowParams): Promise<DialogShowResult> {
    // A cancel may come without `values` (older Vektor): always hand back an object.
    return this.request(Methods.dialogShow, params).then((answer: DialogShowResult) => ({ ...answer, values: answer?.values ?? {} }));
  }
  openURL(url: string): Promise<unknown> { return this.request(Methods.openURL, { url }); }
  navigate(path: string, placement?: NavigateParams['placement']): Promise<unknown> {
    return this.request(Methods.navigate, placement ? { path, placement } : { path });
  }
  reveal(path: string): Promise<unknown> { return this.request(Methods.reveal, { path }); }
  async startProcess(params: ProcessStartParams): Promise<string> { return (await this.request(Methods.processStart, params)).processID; }
  stopProcess(processID: string): Promise<unknown> { return this.request(Methods.processStop, { processID }); }
  async readSecret(key: string): Promise<string> { return (await this.request(Methods.secretsRead, { key })).value; }
  writeSecret(key: string, value: string): Promise<unknown> { return this.request(Methods.secretsWrite, { key, value }); }
  deleteSecret(key: string): Promise<unknown> { return this.request(Methods.secretsDelete, { key }); }
  /** A sidebar entry's badge; neither a count above zero nor a text clears it. */
  setBadge(params: SidebarBadgeParams): void { this.notify(Methods.sidebarBadge, params); }
  /** Your decorations went stale: for these paths, or all. */
  decorationsChanged(paths?: string[]): void { this.notify(Methods.decorationsChanged, paths ? { paths } : {}); }
  footerChanged(): void { this.notify(Methods.footerChanged, {}); }

  /** The data folder: `startup`'s `dataFolder`, else `$VEKTOR_PLUGIN_DATA`. */
  get dataFolder(): string | undefined {
    return this.startupParams?.dataFolder ?? process.env.VEKTOR_PLUGIN_DATA;
  }

  /** Requests of the plugin still waiting for an answer (diagnostics, tests). */
  get pendingRequests(): number { return this.pending.size; }
}

export type { ViewEventParams, ViewOpenedParams, ViewClosedParams, WorkspaceChangedParams, JSONValue };
