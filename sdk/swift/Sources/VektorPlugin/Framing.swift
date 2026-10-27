import Foundation

// The wire: JSON messages framed like a language server's.
//
//     Content-Length: <bytes>\r\n
//     \r\n
//     <JSON body>
//
// `Content-Length` counts BYTES of the UTF-8 body, never characters. The reader works on `Data` and decodes a body only
// when all of its bytes are there, so a character split across reads is never broken, and a header split across reads
// simply waits for the rest.

public enum Framing {
    /// A header larger than this ends the plugin in Vektor; the SDK refuses one too.
    public static let maxHeaderBytes = 1024
    /// A body larger than this ends the plugin in Vektor.
    public static let maxBodyBytes = 16 * 1024 * 1024

    /// One framed message: the header with the body's byte count, then the body.
    public static func encode(_ message: JSONValue) throws -> Data {
        let body = message.jsonData
        guard body.count <= maxBodyBytes else {
            throw PluginError.framing("A message of \(body.count) bytes is larger than Vektor accepts (16 MB).")
        }
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

/// Collects bytes as they arrive and hands back whole messages. A broken stream throws a framing `PluginError`; the caller
/// should stop then (Vektor would end the plugin too).
public struct MessageReader: Sendable {
    private var pending = Data()
    private static let separator = Data("\r\n\r\n".utf8)

    public init() {}

    /// Bytes received that are not yet part of a whole message.
    public var bufferedBytes: Int { pending.count }

    /// Adds `chunk` and returns every message that is now complete, in order.
    public mutating func push(_ chunk: Data) throws -> [JSONValue] {
        pending.append(chunk)
        var messages: [JSONValue] = []
        while true {
            guard let headerEnd = pending.range(of: Self.separator) else {
                if pending.count > Framing.maxHeaderBytes + Self.separator.count {
                    throw PluginError.framing("A message header is longer than 1 KB.")
                }
                return messages
            }
            let headerBytes = pending.distance(from: pending.startIndex, to: headerEnd.lowerBound)
            guard headerBytes <= Framing.maxHeaderBytes else { throw PluginError.framing("A message header is longer than 1 KB.") }
            let header = String(decoding: pending[pending.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var length: Int?
            for line in header.components(separatedBy: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
                let digits = parts[1].trimmingCharacters(in: .whitespaces)
                guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let value = Int(digits) else {
                    throw PluginError.framing("A message header has a Content-Length that is not a number.")
                }
                length = value
            }
            guard let length else { throw PluginError.framing("A message header has no Content-Length.") }
            guard length <= Framing.maxBodyBytes else { throw PluginError.framing("A message body is larger than 16 MB.") }
            let bodyStart = headerEnd.upperBound
            guard pending.distance(from: bodyStart, to: pending.endIndex) >= length else { return messages }
            let bodyEnd = pending.index(bodyStart, offsetBy: length)
            let body = pending.subdata(in: bodyStart..<bodyEnd)
            pending = pending.subdata(in: bodyEnd..<pending.endIndex)
            let message: JSONValue
            do {
                message = try JSONValue.parse(body)
            } catch {
                throw PluginError.framing("A message body is not valid JSON.")
            }
            guard case .object = message else { throw PluginError.framing("A message is not a JSON object.") }
            messages.append(message)
        }
    }
}
