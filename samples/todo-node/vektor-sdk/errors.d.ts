/**
 * An error whose message is meant for the user. Throw it from a handler and the SDK answers the request with
 * `{"error": {"message": …}}`; any other error becomes "Something went wrong in the plugin; its Log has the details." and
 * its stack goes to stderr.
 */
export declare class PluginError extends Error {
    /** A machine-readable word (`changed`, `notFound`, …) when Vektor sent one, or one you set for your own callers. */
    readonly code?: string;
    /** Extra data a refusal carried (`currentVersion`, `state`). */
    readonly data?: Record<string, unknown>;
    constructor(message: string, code?: string, data?: Record<string, unknown>);
}
/** Vektor refused or failed a request of the plugin's. `message` is Vektor's own plain words. */
export declare class VektorError extends PluginError {
    /** The method of the request Vektor refused. */
    readonly method: string;
    constructor(method: string, message: string, code?: string, data?: Record<string, unknown>);
}
/** A request of the plugin's got no answer in time. */
export declare class TimeoutError extends PluginError {
    constructor(method: string, seconds: number);
}
/** The work was cancelled: Vektor sent `$/cancel`, or the plugin is stopping. */
export declare class CancelledError extends PluginError {
    constructor(message?: string);
}
/** The stream from Vektor broke the framing rules (a header over 1 KB, no Content-Length, a body over 16 MB, bad JSON). */
export declare class FramingError extends PluginError {
    constructor(message: string);
}
/** The text used when a handler failed with an error that is not a `PluginError`. */
export declare const GENERIC_FAILURE = "Something went wrong in the plugin; its Log has the details.";
