import Foundation

/// A JSON value: what every message, description and storage document is made of. Literals work:
/// `let value: JSONValue = ["title": "Board", "count": 3, "tags": ["a", "b"]]`.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    /// The value at a dotted path (`params.description.blocks.children.0.title`), or nil.
    public func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for part in path.split(separator: ".", omittingEmptySubsequences: true) {
            switch current {
            case .object(let object)?: current = object[String(part)]
            case .array(let array)?:
                guard let index = Int(part), array.indices.contains(index) else { return nil }
                current = array[index]
            default: return nil
            }
        }
        return current
    }

    public var stringValue: String? { if case .string(let text) = self { return text }; return nil }
    public var numberValue: Double? { if case .number(let number) = self { return number }; return nil }
    public var intValue: Int? {
        if case .number(let number) = self, number.rounded() == number, abs(number) < 9e15 { return Int(number) }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let flag) = self { return flag }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let array) = self { return array }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let object) = self { return object }; return nil }
    public var isNull: Bool { self == .null }

    // MARK: Writing

    /// Compact JSON text, keys sorted (so equal values give equal bytes). Non-ASCII stays UTF-8.
    public var jsonText: String {
        var output = ""
        write(into: &output)
        return output
    }

    /// The UTF-8 bytes of `jsonText`.
    public var jsonData: Data { Data(jsonText.utf8) }

    func write(into output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let number): output += JSONValue.format(number)
        case .string(let text): JSONValue.escape(text, into: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                item.write(into: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                JSONValue.escape(key, into: &output)
                output += ":"
                object[key]!.write(into: &output)
            }
            output += "}"
        }
    }

    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return "\(number)"
    }

    static func escape(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    /// Parses JSON text. Throws a `PluginError` in plain words for text that is not JSON.
    public static func parse(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw PluginError("The text is not valid JSON.", code: "badJSON")
        }
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    // MARK: Codable values

    /// Any `Encodable` value as JSON (a struct of your plugin's, a typed message).
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self = try JSONValue.parse(try encoder.encode(value))
    }

    /// This value decoded as `T`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: jsonData)
        } catch {
            throw PluginError("The data does not have the shape \(T.self) needs.", code: "badJSON")
        }
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonText }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let flag = try? container.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let text = try? container.decode(String.self) { self = .string(text) }
        else if let array = try? container.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// `.number`, from any whole number.
    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    /// `.string`, or `.null` for nil.
    public static func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}

/// An object under construction: fields set to nil are left out, so builders produce exactly the fields you gave.
struct JSONFields {
    var object: [String: JSONValue] = [:]
    subscript(key: String) -> JSONValue? {
        get { object[key] }
        set { object[key] = newValue }
    }
    mutating func set(_ key: String, _ value: String?) { if let value { object[key] = .string(value) } }
    mutating func set(_ key: String, _ value: Bool?) { if let value { object[key] = .bool(value) } }
    mutating func set(_ key: String, _ value: Double?) { if let value { object[key] = .number(value) } }
    mutating func set(_ key: String, _ value: Int?) { if let value { object[key] = .number(Double(value)) } }
    mutating func set(_ key: String, _ value: [String]?) { if let value { object[key] = .array(value.map(JSONValue.string)) } }
    mutating func set(_ key: String, _ value: JSONValue?) { if let value { object[key] = value } }
}
