import { type JSONObject, type JSONValue, type ViewRefusedParams } from './messages';
import { Plugin } from './plugin';
/** The PATH Vektor gives a plugin. */
export declare const PLUGIN_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin";
/** A message as the test host sees it: `{kind, id?, method?, params?, result?, error?}` — the shape scripts match against. */
export interface Envelope {
    kind: 'request' | 'notification' | 'response' | 'failure';
    id?: number | string;
    method?: string;
    params?: any;
    result?: any;
    error?: any;
}
export interface Expectation {
    kind?: Envelope['kind'];
    method?: string;
    /** Paths (`params.description.blocks.children.0.title`) to a value, or a test: `{exists}`, `{contains}`, `{matches}`, `{count}`. */
    match?: Record<string, JSONValue>;
}
export interface TestHostOptions {
    /** The plugin folder (its plugin.json gives the setting defaults, the id and the program). */
    folder: string;
    /** In memory: registers the plugin's handlers on the SDK `Plugin` it is given. */
    setup?: (plugin: Plugin) => unknown;
    /** Start the folder's program as a process instead. */
    spawn?: boolean;
    /** Extra environment for a spawned program (e.g. a PATH for an interpreter elsewhere — Vektor would not find it). */
    environment?: Record<string, string>;
    settings?: JSONObject;
    workspace?: {
        id: string;
        name: string;
    } | null;
    previousSessionEndedUncleanly?: boolean;
    /** Answers to the plugin's requests by method; `{"$error": "words"}` refuses. Default `{}`. */
    autoReply?: Record<string, JSONValue>;
    /** Keep the temporary folder (to look at what the plugin wrote). */
    keep?: boolean;
}
export declare function valueAt(root: unknown, dotted: string): unknown;
export declare function valueMatches(actual: unknown, expected: JSONValue): boolean;
export declare function envelopeMatches(envelope: Envelope, expectation: Expectation, requestID?: number): boolean;
export declare function describeExpectation(expectation: Expectation): string;
/** The storage service of the test host, on folders under a temporary folder. */
export declare class TestPlaces {
    readonly work: string;
    private readonly places;
    private readonly uploads;
    private readonly cursors;
    readonly trash: string;
    constructor(work: string);
    /** Replaces each `{"$place": name}` setting with a handle; answers `place.<name>` variables (the folders). */
    substitute(settings: JSONObject): {
        settings: JSONObject;
        variables: Record<string, string>;
    };
    static isStorageMethod(method: string): boolean;
    /** The answer to one storage request: a result, or an error object with message, code and data. */
    answer(method: string, params: any): {
        result?: JSONValue;
        error?: JSONObject;
    };
    private version;
    private respond;
}
export declare class TestHost {
    private readonly options;
    /** Every message the plugin sent, in order. */
    readonly received: Envelope[];
    /** A readable record of the conversation (→ to the plugin, ← from it, ! a problem). */
    readonly transcript: string[];
    /** The folders behind fake places, by name (`${place.<name>}`). */
    readonly variables: Record<string, string>;
    /** The plugin object, in memory mode. */
    plugin?: Plugin;
    /** The exit status once the plugin left. */
    exitCode?: number;
    readonly work: string;
    readonly dataFolder: string;
    readonly sessionFolder: string;
    readonly places: TestPlaces;
    readonly manifest: any;
    private nextID;
    private readonly waiters;
    private writeToPlugin;
    private closeInput;
    private child?;
    private settings;
    private constructor();
    /** Starts the plugin (in memory with `setup`, or as a process with `spawn`). Does not send `startup`: call `startup()`. */
    static start(options: TestHostOptions): Promise<TestHost>;
    private startInMemory;
    private spawnProcess;
    private log;
    private wake;
    private fromPlugin;
    /** A block description is checked the way Vektor checks it; what it would refuse goes into the transcript. */
    private checkView;
    private answer;
    /** `startup`'s parameters, as Vektor (and `vektor-plugin test`) sends them. */
    startupParams(): JSONObject;
    /** Sends a message: a request (answers its id) unless the method is one Vektor sends as a notification. */
    send(method: string, params?: JSONValue, kind?: 'request' | 'notification'): number | undefined;
    /** Waits until a message received after `since` satisfies `test`. */
    private waitUntil;
    /** Waits for a message the plugin sends after `since` (an index into `received`) that fits `expectation`. */
    waitFor(expectation: Expectation, options?: {
        since?: number;
        requestID?: number;
        timeout?: number;
    }): Promise<Envelope>;
    /** Sends a request and waits for its answer (a response or a failure). */
    request(method: string, params?: JSONValue, timeout?: number): Promise<Envelope>;
    /** Sends `startup` and waits for its answer. */
    startup(): Promise<Envelope>;
    /** Sends `view/opened`. */
    openView(view: string, item?: string): void;
    /** Sends a `view/event`; `revision` defaults to the last one the plugin sent for that view. */
    viewEvent(view: string, action: string, fields?: JSONObject): void;
    /** Sends `web/message` as a page would. */
    webMessage(view: string, message: JSONValue, block?: string): void;
    /**
     * Simulates Vektor refusing what the plugin sent last for `view` (`view/refused`, plugin API 2). `kind` defaults to whichever
     * the plugin sent last (`description` for a `view/update`, `patch` for a `view/patch`), `refusedRevision` to its revision, and
     * `revision` — what Vektor still shows — to the revision the plugin sent before it (`null` when there was none). `viewEvent`
     * keeps defaulting to the plugin's last revision: pass `revision` to make an event against the one Vektor still shows.
     */
    refuse(view: string, options?: {
        problem?: string;
        kind?: 'description' | 'patch';
        revision?: number | null;
        refusedRevision?: number;
    }): ViewRefusedParams;
    /** The revision of the description the plugin sent last for `view` (`view/update` or `view/patch`). */
    lastRevision(view: string): number | undefined;
    /** Every notification of `method` received so far. */
    notifications(method: string): Envelope[];
    /** Waits for the plugin to leave by itself; true when it did. */
    waitForExit(timeout?: number): Promise<boolean>;
    /** Sends `shutdown`, expects its answer and the plugin's exit. */
    shutdown(reason?: string): Promise<void>;
    /** Ends the plugin if it is still there and removes the temporary folder (unless `keep`). */
    close(): Promise<void>;
}
export interface TestScript {
    settings?: JSONObject;
    workspace?: {
        id: string;
        name: string;
    } | null;
    previousSessionEndedUncleanly?: boolean;
    autoReply?: Record<string, JSONValue>;
    steps: {
        name: string;
        startup?: boolean;
        send?: {
            method: string;
            params?: JSONValue;
            kind?: 'request' | 'notification';
        };
        expect?: (Expectation & {
            absent?: boolean;
            capture?: Record<string, string>;
        })[];
        timeout?: number;
        expectExit?: boolean;
    }[];
}
export interface ScriptReport {
    passed: boolean;
    steps: {
        name: string;
        failures: string[];
    }[];
    transcript: string[];
}
/**
 * Plays a `test/checks.json` script the way `vektor-plugin test` does, against the plugin in memory (`setup`) or as a process.
 * Each step sends one message (or `startup`), then waits until every expectation is met (or its timeout, default 5 s);
 * `absent` expectations must not arrive; `capture` stores values for `${name}` in later steps.
 */
export declare function runScript(script: TestScript | string, options: Omit<TestHostOptions, 'settings' | 'workspace' | 'autoReply' | 'previousSessionEndedUncleanly'>): Promise<ScriptReport>;
/** One line per step (`PASS name` / `FAIL name: why`), as `vektor-plugin test` prints them. */
export declare function formatReport(report: ScriptReport): string;
