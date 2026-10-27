import { type ConfirmParams, type DecorationsGetParams, type DecorationsGetResult, type DialogShowParams, type DialogShowResult, type FooterGetParams, type FooterGetResult, type InfoGetParams, type InfoGetResult, type InvokeTarget, type JSONObject, type JSONValue, type LogLevel, type NavigateParams, type PluginNotifications, type PluginRequests, type ProcessExitedParams, type ProcessOutputParams, type ProcessStartParams, type SettingsGetResult, type SettingsStatusParams, type ShutdownReason, type SidebarBadgeParams, type StartupParams, type ViewEventParams, type ViewOpenedParams, type ViewClosedParams, type Workspace, type WorkspaceChangedParams } from './messages';
import { type Transport } from './transport';
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
/** The first id of the plugin's own requests (the reference: "start yours at 1000 or so"). */
export declare const FIRST_REQUEST_ID = 1000;
export declare class Plugin {
    /** The plugin API written on every message. */
    api: number;
    /** Every setting's value (defaults filled in), as of the latest `startup`, `settingsChanged` or `settings/get`. */
    settings: JSONObject;
    /** The active workspace, or null. */
    workspace: Workspace | null;
    /** `startup`'s parameters once it arrived. */
    startupParams?: StartupParams;
    private readonly transport;
    private readonly reader;
    private readonly diagnostics;
    private readonly shutdownGrace;
    private readonly requestTimeout;
    private nextID;
    private readonly pending;
    private readonly inFlight;
    private readonly requestHandlers;
    private readonly notificationHandlers;
    private readonly commands;
    private readonly startupHandlers;
    private readonly readyHandlers;
    private readonly shutdownHandlers;
    private readonly settingsHandlers;
    private readonly workspaceHandlers;
    private readonly views;
    private readonly bridges;
    private readonly sidebars;
    private started;
    private stopping;
    constructor(options?: PluginOptions);
    /** Runs when `startup` arrives, before it is answered. `settings`, `workspace` and `startupParams` are already set. */
    onStartup(handler: (params: StartupParams) => unknown): this;
    /**
     * Runs right after `startup` has been answered: the place to send a first `view/update`, sidebar items or a badge, so a
     * Settings tab and the sidebar are ready before anyone opens a pane.
     */
    onReady(handler: (params: StartupParams) => unknown): this;
    /** Runs on `shutdown` (after it is answered) and at the end of input: stop what you started. Bounded by the grace period. */
    onShutdown(handler: (reason: ShutdownReason) => unknown): this;
    /** `settingsChanged`. `settings` and `workspace` are already updated. */
    onSettingsChanged(handler: (settings: JSONObject, workspace: Workspace | null) => unknown): this;
    /** The active workspace changed: `workspace/changed` (API 2), or a `settingsChanged` naming another workspace. */
    onWorkspaceChanged(handler: (workspace: Workspace | null) => unknown): this;
    /**
     * A command of the manifest (`invoke`). Return nothing for `{}`, a string for a short notice, or an `InvokeResult`.
     * Throw a `PluginError` to show its message in an alert.
     */
    command(name: string, handler: (target: InvokeTarget, context: RequestContext) => unknown): this;
    /** Any request method from Vektor (`decorations/get`, `info/get`, `footer/get`, or one this SDK does not type). */
    onRequest(method: string, handler: RequestHandler): this;
    /** Any notification from Vektor. Several handlers may listen to one method. */
    onNotification(method: string, handler: NotificationHandler): this;
    onDecorations(handler: (params: DecorationsGetParams, context: RequestContext) => DecorationsGetResult | Promise<DecorationsGetResult>): this;
    onInfo(handler: (params: InfoGetParams, context: RequestContext) => InfoGetResult | Promise<InfoGetResult>): this;
    onFooter(handler: (params: FooterGetParams, context: RequestContext) => FooterGetResult | Promise<FooterGetResult>): this;
    onProcessOutput(handler: (params: ProcessOutputParams) => void): this;
    onProcessExited(handler: (params: ProcessExitedParams) => void): this;
    /** The state of a view the plugin describes: its description, revision, patches and event routing. */
    view(id: string, options?: ViewStateOptions): ViewState;
    /** The bridge to the plugin's web pages showing view `id` (a `web` view, or `web` blocks in a block view). */
    web(view: string): WebBridge;
    /** The items listed under sidebar entry `entry` (API 2). */
    sidebar(entry: string): SidebarItems;
    /** The storage service on a place (a `place` setting's value, or its `place` string). */
    storage(place: string | {
        place: string;
    }): Storage;
    /** Starts reading messages. Call it once, after registering handlers. */
    start(): this;
    /** Feeds bytes as if they came from stdin (the transport does this; tests may too). */
    receive(chunk: Uint8Array): void;
    private dispatch;
    private handleRequest;
    private invoke;
    private handleNotification;
    private applySettings;
    private applyWorkspace;
    /**
     * Leaves: cancels work in flight, runs the shutdown handlers for at most the grace period, and exits. `shutdown` is
     * answered before this runs; at the end of input there is nobody to answer.
     */
    stop(reason: ShutdownReason, answered: boolean): Promise<void>;
    private write;
    private reply;
    private replyError;
    private report;
    /** Sends a notification. */
    notify<M extends keyof PluginNotifications>(method: M, params: PluginNotifications[M]): void;
    notify(method: string, params: unknown): void;
    /**
     * Sends a request and resolves with its result. Rejects with `VektorError` (Vektor refused, in plain words; `code` and
     * `data` when it gave them), `TimeoutError`, or `CancelledError` (the `signal` was aborted, or the plugin is stopping).
     * `timeout` is in seconds; `0` waits for ever (the default for `dialog/show` and `confirm`, which wait for the user).
     */
    request<M extends keyof PluginRequests>(method: M, params: PluginRequests[M][0], options?: {
        timeout?: number;
        signal?: AbortSignal;
    }): Promise<PluginRequests[M][1]>;
    request(method: string, params: unknown, options?: {
        timeout?: number;
        signal?: AbortSignal;
    }): Promise<any>;
    /** A line in the plugin's Log in Vektor. */
    log(message: string, level?: LogLevel): void;
    toast(message: string): void;
    alert(title: string, message: string): void;
    confirm(params: ConfirmParams): Promise<boolean>;
    copyText(text: string): void;
    /** Asks Vektor for the settings now; also updates `settings` and `workspace`. */
    getSettings(): Promise<SettingsGetResult>;
    /** A status line under a setting; empty `text` clears it. */
    setStatus(params: SettingsStatusParams): void;
    showDialog(params: DialogShowParams): Promise<DialogShowResult>;
    openURL(url: string): Promise<unknown>;
    navigate(path: string, placement?: NavigateParams['placement']): Promise<unknown>;
    reveal(path: string): Promise<unknown>;
    startProcess(params: ProcessStartParams): Promise<string>;
    stopProcess(processID: string): Promise<unknown>;
    readSecret(key: string): Promise<string>;
    writeSecret(key: string, value: string): Promise<unknown>;
    deleteSecret(key: string): Promise<unknown>;
    /** A sidebar entry's badge; neither a count above zero nor a text clears it. */
    setBadge(params: SidebarBadgeParams): void;
    /** Your decorations went stale: for these paths, or all. */
    decorationsChanged(paths?: string[]): void;
    footerChanged(): void;
    /** The data folder: `startup`'s `dataFolder`, else `$VEKTOR_PLUGIN_DATA`. */
    get dataFolder(): string | undefined;
    /** Requests of the plugin still waiting for an answer (diagnostics, tests). */
    get pendingRequests(): number;
}
export type { ViewEventParams, ViewOpenedParams, ViewClosedParams, WorkspaceChangedParams, JSONValue };
