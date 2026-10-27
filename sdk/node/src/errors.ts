// Errors, in plain words. Vektor shows a failed request's `error.message` to the user exactly as written, so every message
// here is a sentence a user can read: no codes, no errno, no stack traces (those go to stderr, which is the plugin's Log).

/**
 * An error whose message is meant for the user. Throw it from a handler and the SDK answers the request with
 * `{"error": {"message": …}}`; any other error becomes "Something went wrong in the plugin; its Log has the details." and
 * its stack goes to stderr.
 */
export class PluginError extends Error {
  /** A machine-readable word (`changed`, `notFound`, …) when Vektor sent one, or one you set for your own callers. */
  readonly code?: string;
  /** Extra data a refusal carried (`currentVersion`, `state`). */
  readonly data?: Record<string, unknown>;
  constructor(message: string, code?: string, data?: Record<string, unknown>) {
    super(message);
    this.name = 'PluginError';
    this.code = code;
    this.data = data;
  }
}

/** Vektor refused or failed a request of the plugin's. `message` is Vektor's own plain words. */
export class VektorError extends PluginError {
  /** The method of the request Vektor refused. */
  readonly method: string;
  constructor(method: string, message: string, code?: string, data?: Record<string, unknown>) {
    super(message, code, data);
    this.name = 'VektorError';
    this.method = method;
  }
}

/** A request of the plugin's got no answer in time. */
export class TimeoutError extends PluginError {
  constructor(method: string, seconds: number) {
    super(`Vektor did not answer “${method}” within ${seconds} seconds.`, 'timeout');
    this.name = 'TimeoutError';
  }
}

/** The work was cancelled: Vektor sent `$/cancel`, or the plugin is stopping. */
export class CancelledError extends PluginError {
  constructor(message = 'Cancelled.') {
    super(message, 'cancelled');
    this.name = 'CancelledError';
  }
}

/** The stream from Vektor broke the framing rules (a header over 1 KB, no Content-Length, a body over 16 MB, bad JSON). */
export class FramingError extends PluginError {
  constructor(message: string) {
    super(message, 'framing');
    this.name = 'FramingError';
  }
}

/** The text used when a handler failed with an error that is not a `PluginError`. */
export const GENERIC_FAILURE = 'Something went wrong in the plugin; its Log has the details.';
