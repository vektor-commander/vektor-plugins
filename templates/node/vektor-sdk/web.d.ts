import type { JSONValue, WebMessageParams } from './messages';
import type { Plugin } from './plugin';
/** The largest message either way (Vektor's limit). */
export declare const MAX_WEB_MESSAGE_BYTES: number;
export interface WebMessageContext {
    view: string;
    /** The `web` block's id, when the page is a block of a block view. */
    block?: string;
}
type WebHandler = (message: any, context: WebMessageContext) => unknown;
export declare class WebBridge {
    private readonly plugin;
    readonly view: string;
    private readonly handlers;
    private fallback?;
    constructor(plugin: Plugin, view: string);
    /** Handles page messages whose `type` is `type`. For a request, the return value is the reply. */
    on(type: string, handler: WebHandler): this;
    /** Handles messages no `on` claims (and messages that are not objects with a `type`). */
    onAny(handler: WebHandler): this;
    /** Sends `message` to this plugin's pages showing the view — all of them, or only the `web` block `block`. */
    post(message: JSONValue, block?: string): void;
    /** Called by the plugin for this view's `web/message`. */
    receive(params: WebMessageParams): Promise<void>;
}
export {};
