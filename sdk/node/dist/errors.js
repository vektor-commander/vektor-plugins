"use strict";
// Errors, in plain words. Vektor shows a failed request's `error.message` to the user exactly as written, so every message
// here is a sentence a user can read: no codes, no errno, no stack traces (those go to stderr, which is the plugin's Log).
Object.defineProperty(exports, "__esModule", { value: true });
exports.GENERIC_FAILURE = exports.FramingError = exports.CancelledError = exports.TimeoutError = exports.VektorError = exports.PluginError = void 0;
/**
 * An error whose message is meant for the user. Throw it from a handler and the SDK answers the request with
 * `{"error": {"message": …}}`; any other error becomes "Something went wrong in the plugin; its Log has the details." and
 * its stack goes to stderr.
 */
class PluginError extends Error {
    /** A machine-readable word (`changed`, `notFound`, …) when Vektor sent one, or one you set for your own callers. */
    code;
    /** Extra data a refusal carried (`currentVersion`, `state`). */
    data;
    constructor(message, code, data) {
        super(message);
        this.name = 'PluginError';
        this.code = code;
        this.data = data;
    }
}
exports.PluginError = PluginError;
/** Vektor refused or failed a request of the plugin's. `message` is Vektor's own plain words. */
class VektorError extends PluginError {
    /** The method of the request Vektor refused. */
    method;
    constructor(method, message, code, data) {
        super(message, code, data);
        this.name = 'VektorError';
        this.method = method;
    }
}
exports.VektorError = VektorError;
/** A request of the plugin's got no answer in time. */
class TimeoutError extends PluginError {
    constructor(method, seconds) {
        super(`Vektor did not answer “${method}” within ${seconds} seconds.`, 'timeout');
        this.name = 'TimeoutError';
    }
}
exports.TimeoutError = TimeoutError;
/** The work was cancelled: Vektor sent `$/cancel`, or the plugin is stopping. */
class CancelledError extends PluginError {
    constructor(message = 'Cancelled.') {
        super(message, 'cancelled');
        this.name = 'CancelledError';
    }
}
exports.CancelledError = CancelledError;
/** The stream from Vektor broke the framing rules (a header over 1 KB, no Content-Length, a body over 16 MB, bad JSON). */
class FramingError extends PluginError {
    constructor(message) {
        super(message, 'framing');
        this.name = 'FramingError';
    }
}
exports.FramingError = FramingError;
/** The text used when a handler failed with an error that is not a `PluginError`. */
exports.GENERIC_FAILURE = 'Something went wrong in the plugin; its Log has the details.';
