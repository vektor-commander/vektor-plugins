import Foundation
import VektorPlugin

@MainActor
func framingTests() async {
    await test("framing: the byte count of the UTF-8 body, not the character count") {
        let message: JSONValue = ["api": 2, "method": "toast", "params": ["message": "Příliš žluťoučký kůň 👍"]]
        let framed = try Framing.encode(message)
        let text = String(decoding: framed, as: UTF8.self)
        let body = message.jsonData
        try check(text.hasPrefix("Content-Length: \(body.count)\r\n\r\n"))
        try check(body.count != message.jsonText.count, "bytes and characters must differ here")
    }

    await test("framing: the reference example frames to Content-Length 44") {
        let framed = try Framing.encode(["api": 1, "id": 1, "method": "ping", "params": [:]])
        try checkEqual(String(decoding: framed, as: UTF8.self), "Content-Length: 44\r\n\r\n{\"api\":1,\"id\":1,\"method\":\"ping\",\"params\":{}}")
    }

    await test("framing: fed one byte at a time — split header, split multi-byte characters") {
        let messages: [JSONValue] = [
            ["api": 2, "method": "web/message", "params": ["view": "v", "message": ["text": "é"]]],
            ["api": 2, "id": 7, "method": "invoke", "params": ["command": "x", "target": ["text": "日本語 🇨🇿 e\u{301}"]]],
        ]
        var bytes = Data()
        for message in messages { bytes += try Framing.encode(message) }
        var reader = MessageReader()
        var out: [JSONValue] = []
        for index in bytes.indices { out += try reader.push(bytes.subdata(in: index..<(index + 1))) }
        try checkEqual(out, messages)
        try checkEqual(reader.bufferedBytes, 0)
    }

    await test("framing: several messages in one chunk, and a partial one kept") {
        let one = try Framing.encode(["api": 2, "method": "a", "params": [:]])
        let two = try Framing.encode(["api": 2, "method": "b", "params": ["x": "ž"]])
        var reader = MessageReader()
        let cut = two.count - 3
        try checkEqual(try reader.push(one + two.prefix(cut)).compactMap { $0["method"]?.stringValue }, ["a"])
        try checkEqual(try reader.push(two.suffix(from: cut)).compactMap { $0["method"]?.stringValue }, ["b"])
    }

    await test("framing: other header lines and any case of Content-Length") {
        let body = Data("{\"api\":2,\"method\":\"x\"}".utf8)
        var reader = MessageReader()
        let framed = Data("Content-Type: application/json\r\ncontent-length: \(body.count)\r\n\r\n".utf8) + body
        try checkEqual(try reader.push(framed).first?["method"], "x")
    }

    await test("framing: a header over 1 KB is refused, even before it ends") {
        var reader = MessageReader()
        try checkThrows({ _ = try reader.push(Data(("X-Padding: " + String(repeating: "a", count: 1100)).utf8)) }, matching: "longer than 1 KB")
        var ended = MessageReader()
        try checkThrows({ _ = try ended.push(Data("X: \(String(repeating: "a", count: 1100))\r\nContent-Length: 2\r\n\r\n{}".utf8)) }, matching: "longer than 1 KB")
    }

    await test("framing: no Content-Length, not an object, bad JSON, over 16 MB") {
        var a = MessageReader()
        try checkThrows({ _ = try a.push(Data("Foo: 1\r\n\r\n{}".utf8)) }, matching: "no Content-Length")
        var b = MessageReader()
        try checkThrows({ _ = try b.push(Data("Content-Length: 2\r\n\r\n[]".utf8)) }, matching: "not a JSON object")
        var c = MessageReader()
        try checkThrows({ _ = try c.push(Data("Content-Length: 2\r\n\r\n{x".utf8)) }, matching: "not valid JSON")
        var d = MessageReader()
        try checkThrows({ _ = try d.push(Data("Content-Length: \(16 * 1024 * 1024 + 1)\r\n\r\n".utf8)) }, matching: "16 MB")
    }

    await test("JSON: escaping, numbers, sorted keys, round trip") {
        let value: JSONValue = ["b": "line\nbreak \"quoted\" \\ tab\t\u{1}", "a": 1.5, "c": [true, nil, 3]]
        try checkEqual(value.jsonText, #"{"a":1.5,"b":"line\nbreak \"quoted\" \\ tab\t\u0001","c":[true,null,3]}"#)
        try checkEqual(try JSONValue.parse(value.jsonText), value)
        try checkEqual(try JSONValue.parse("[1, true, 0]"), [1, true, 0])
    }
}
