"use strict";
// Where the bytes go. A plugin talks to Vektor over its stdin and stdout; the test kit swaps in an in-memory pair, so the
// same plugin code runs under a test runner without a process.
Object.defineProperty(exports, "__esModule", { value: true });
exports.stdioTransport = stdioTransport;
exports.logToStderr = logToStderr;
/**
 * The real one: stdin and stdout. stdout carries messages and NOTHING else. The SDK keeps the real stdout for itself and
 * points `process.stdout.write` (and with it `console.log`) at stderr: one stray line on stdout would break the framing and
 * Vektor would end the plugin, while on stderr it is a line in the plugin's Log.
 */
function stdioTransport() {
    const write = messageOutput();
    let exiting = false;
    return {
        write(bytes) {
            write(bytes);
        },
        onData(listener) {
            process.stdin.on('data', listener);
        },
        onEnd(listener) {
            process.stdin.on('end', listener);
        },
        exit(code) {
            if (exiting)
                return;
            exiting = true;
            // Leave only once what was written has reached the pipe: an answer to `shutdown` must not be lost.
            write(Buffer.alloc(0), () => process.exit(code));
        },
    };
}
let realStdout;
/** The real stdout's writer, taken once; from then on everything else written to stdout goes to stderr. */
function messageOutput() {
    if (realStdout)
        return realStdout;
    const original = process.stdout.write.bind(process.stdout);
    realStdout = (bytes, done) => { original(bytes, done); };
    const toStderr = process.stderr.write.bind(process.stderr);
    process.stdout.write = ((...args) => toStderr(...args));
    return realStdout;
}
/** A line on stderr: the plugin's Log in Vektor. */
function logToStderr(text) {
    process.stderr.write(`${text}\n`);
}
