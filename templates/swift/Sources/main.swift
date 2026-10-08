// Hello Plugin (Swift) - the compiled plugin template (Vektor plugin API 1).
//
// A plugin is a program that Vektor starts when it is needed and talks to over stdin/stdout. Each message is
//
//     Content-Length: <bytes>\r\n
//     \r\n
//     <JSON body>
//
// Vektor sends requests (they carry an "id" and want an answer: startup, shutdown, invoke, ping) and notifications (no id:
// settingsChanged, view/opened, view/event, ...). You answer a request with {"id": ..., "result": ...} or
// {"id": ..., "error": {"message": ...}}. docs/reference.md lists every message with an example.
//
// Rules this file follows:
//   * Content-Length is a BYTE count: it is measured on the encoded `Data`, never on a String.
//   * stdout carries messages and nothing else. Diagnostics go to stderr or to the `log` message.
//   * Answer `shutdown`, then exit.
//   * Keep state in $VEKTOR_PLUGIN_DATA, never inside the plugin folder (it is replaced on update).
//   * The program must be signed, or macOS kills it silently. build.sh signs it ad hoc (`codesign -s -`): no Developer ID and no
//     notarization are needed. Sign AFTER the last change; any change invalidates the signature.
import Foundation

var greeting = "Hello"

// --- Wire -------------------------------------------------------------------------------------------------------------
func send(_ message: [String: Any]) {
    var full = message
    full["api"] = 1
    guard let body = try? JSONSerialization.data(withJSONObject: full) else { return }
    FileHandle.standardOutput.write(Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
}
func notify(_ method: String, _ params: [String: Any]) { send(["method": method, "params": params]) }
func reply(_ id: Any, _ result: [String: Any]) { send(["id": id, "result": result]) }
func refuse(_ id: Any, _ message: String) { send(["id": id, "error": ["message": message]]) }

// --- What the plugin does ---------------------------------------------------------------------------------------------
func onInvoke(_ id: Any, _ params: [String: Any]) {
    let command = params["command"] as? String ?? ""
    switch command {
    case "hello":
        // The items the command was chosen for: params.target.items is a list of {path, name, isFolder}.
        let target = params["target"] as? [String: Any]
        let count = (target?["items"] as? [Any])?.count ?? 0
        // A reply with a "message" is shown to the user as a short notice.
        reply(id, ["message": "\(greeting)! You chose \(count) item(s)."])
    default:
        refuse(id, "This plugin has no command \u{201C}\(command)\u{201D}.")
    }
}

func onMessage(_ message: [String: Any]) {
    let method = message["method"] as? String
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "startup":
        greeting = (params["settings"] as? [String: Any])?["greeting"] as? String ?? greeting
        reply(id ?? 0, [:])
        notify("log", ["level": "info", "message": "Hello Plugin started."])
    case "settingsChanged":
        greeting = (params["settings"] as? [String: Any])?["greeting"] as? String ?? greeting
    case "invoke":
        onInvoke(id ?? 0, params)
    case "shutdown":
        reply(id ?? 0, [:])
        exit(0)
    case "ping":
        reply(id ?? 0, [:])
    case "$/cancel":
        break
    default:
        // An answer to a request of ours has no method (this plugin sends none). Anything else with an id gets an error.
        if method != nil, let id { refuse(id, "unknown method") }
    }
}

// --- Main loop --------------------------------------------------------------------------------------------------------
var pending = Data()
let separator = Data("\r\n\r\n".utf8)

func drain() {
    while let headerEnd = pending.range(of: separator) {
        let header = String(decoding: pending[pending.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
            let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        else {
            FileHandle.standardError.write(Data("a message without Content-Length\n".utf8))
            exit(1)
        }
        let bodyStart = headerEnd.upperBound
        guard pending.distance(from: bodyStart, to: pending.endIndex) >= length else { return }   // the rest has not arrived
        let body = pending[bodyStart..<pending.index(bodyStart, offsetBy: length)]
        pending = Data(pending[pending.index(bodyStart, offsetBy: length)...])
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { onMessage(object) }
    }
}

while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { exit(0) }      // End of file: Vektor is gone. Stop what you started (nothing here) and leave.
    pending.append(chunk)
    drain()
}
