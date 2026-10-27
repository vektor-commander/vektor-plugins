import Foundation

/// An error in plain words. Vektor shows a failed request's message to the user exactly as written, so the message is a
/// sentence a user can read: no codes, no errno, no stack traces (those go to stderr, which is the plugin's Log).
///
/// Throw one from a handler and the SDK answers the request with `{"error": {"message": …}}`; any other error becomes
/// "Something went wrong in the plugin; its Log has the details." and its description goes to stderr.
///
/// Errors Vektor sends back for the plugin's own requests arrive as a `PluginError` too, with Vektor's `code` and `data`
/// (`changed` and `currentVersion` for a storage write that lost a race) and the `method` it refused.
public struct PluginError: Error, LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// A machine-readable word (`changed`, `notFound`, `timeout`, `cancelled`, …).
    public var code: String?
    /// Extra data a refusal carried.
    public var data: JSONValue?
    /// The method of the plugin's request that Vektor refused (nil for an error the plugin raised itself).
    public var method: String?

    public init(_ message: String, code: String? = nil, data: JSONValue? = nil, method: String? = nil) {
        self.message = message
        self.code = code
        self.data = data
        self.method = method
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    /// Whether Vektor refused the request (as opposed to an error raised in the plugin).
    public var isFromVektor: Bool { method != nil && code != "timeout" && code != "cancelled" }

    /// A request of the plugin's got no answer in time.
    public static func timeout(_ method: String, seconds: Double) -> PluginError {
        let shown = seconds.rounded() == seconds ? String(Int(seconds)) : String(seconds)
        return PluginError("Vektor did not answer “\(method)” within \(shown) seconds.", code: "timeout", method: method)
    }

    /// The work was cancelled: Vektor sent `$/cancel`, or the plugin is stopping.
    public static func cancelled(_ message: String = "Cancelled.") -> PluginError { PluginError(message, code: "cancelled") }

    /// The stream from Vektor broke the framing rules.
    public static func framing(_ message: String) -> PluginError { PluginError(message, code: "framing") }
}

/// The text used when a handler failed with an error that is not a `PluginError`.
public let genericFailureMessage = "Something went wrong in the plugin; its Log has the details."

/// A line on stderr: the plugin's Log in Vektor. stdout carries only messages.
public func logToStderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
