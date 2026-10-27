import Foundation

// The storage service (API 2) on one place the user chose: files read and written by Vektor through its own connections.
//
//     guard let boards = plugin.place("boards") else { return }      // the `place` setting's handle
//     let storage = plugin.storage(boards)
//     let doc = try await storage.readJSON("board.json", as: Board.self)        // (value, version) or nil
//     switch try await storage.writeIfUnchanged("board.json", board, baseVersion: doc?.version) {
//     case .written(let version): …
//     case .conflict(let conflict): …   // someone else wrote it meanwhile: conflict.theirs
//     }
//
// Large files go in parts automatically (512 KB per message, files up to 32 MB). Versions are opaque strings: compare them
// for equality only. Never store a place handle: use the latest one Vektor sent.

public enum StorageLimits {
    /// Bytes of content in one message (Vektor's limit).
    public static let partBytes = 512 * 1024
    /// The largest file the storage service reads or writes.
    public static let fileBytes = 32 * 1024 * 1024
}

/// A file read: its value and the version it is.
public struct StoredFile<Value> {
    public var value: Value
    public var version: String
    public init(value: Value, version: String) {
        self.value = value
        self.version = version
    }
}
extension StoredFile: Equatable where Value: Equatable {}
extension StoredFile: Sendable where Value: Sendable {}

/// Someone else changed the file since you read it. You decide: merge (see `threeWayMerge`), ask your user, or overwrite.
public struct Conflict<Value> {
    public var path: String
    /// What you tried to write.
    public var mine: Value
    /// The version your write was based on (nil: you expected no file).
    public var baseVersion: String?
    /// What the place holds now, and its version — nil when the file is gone.
    public var theirs: StoredFile<Value>?
    /// The version to pass as `ifVersion` once you have merged (nil: the file is gone, write as new).
    public var currentVersion: String? { theirs?.version }
}

/// What `writeIfUnchanged` did.
public enum WriteOutcome<Value> {
    case written(version: String)
    case conflict(Conflict<Value>)

    public var version: String? { if case .written(let version) = self { return version }; return nil }
    public var conflict: Conflict<Value>? { if case .conflict(let conflict) = self { return conflict }; return nil }
}

/// `ifVersion`: any file, only if there is none, or only if it is still this version.
public enum IfVersion: Sendable, Equatable {
    case any
    case absent
    case version(String)

    init(_ base: String?) { self = base.map(IfVersion.version) ?? .absent }
    var json: JSONValue? {
        switch self {
        case .any: return nil
        case .absent: return .null
        case .version(let version): return .string(version)
        }
    }
}

@MainActor
public struct Storage {
    public let plugin: Plugin
    public let place: String

    public init(plugin: Plugin, place: String) {
        self.plugin = plugin
        self.place = place
    }

    /// `available`, `offline`, `needsSignIn` or `missing`, and what the place promises.
    public func status() async throws -> StorageStatus {
        try await plugin.request(Method.storageStatus, ["place": .string(place)]).decode(StorageStatus.self)
    }

    /// One page of a folder's entries; pass `next` back as `cursor` for the following page.
    public func listPage(_ path: String = "", cursor: String? = nil, limit: Int? = nil) async throws -> StorageListPage {
        var params: [String: JSONValue] = ["place": .string(place)]
        if !path.isEmpty { params["path"] = .string(path) }
        if let cursor { params["cursor"] = .string(cursor) }
        if let limit { params["limit"] = .int(limit) }
        return try await plugin.request(Method.storageList, .object(params)).decode(StorageListPage.self)
    }

    /// Every entry of a folder, following `next` until the last page (a page may hold fewer than `limit`, even none).
    public func list(_ path: String = "", limit: Int? = nil) async throws -> [StorageEntry] {
        var entries: [StorageEntry] = []
        var cursor: String?
        repeat {
            let page = try await listPage(path, cursor: cursor, limit: limit)
            entries += page.entries
            cursor = page.next
        } while cursor != nil
        return entries
    }

    /// A whole file as bytes, read in parts when it is large; every part is checked to be of the same version, to start where
    /// the previous one ended, and the whole to be the file's size — a file is never returned shorter than it is.
    public func readData(_ path: String) async throws -> StoredFile<Data> {
        var bytes = Data()
        var version: String?
        let notWhole = PluginError("“\(path)” was not read whole.", code: "failed")
        while true {
            var params: [String: JSONValue] = [
                "place": .string(place), "path": .string(path), "offset": .int(bytes.count), "length": .int(StorageLimits.partBytes),
            ]
            if let version { params["ifVersion"] = .string(version) }
            let part = try await plugin.request(Method.storageRead, .object(params)).decode(StorageReadPart.self)
            guard part.offset == Double(bytes.count) else { throw notWhole }
            let chunk: Data
            if part.encoding == "base64" {
                // Bad base64 is an error, never an empty part.
                guard let decoded = Data(base64Encoded: part.content) else { throw notWhole }
                chunk = decoded
            } else {
                chunk = Data(part.content.utf8)
            }
            bytes.append(chunk)
            if version == nil { version = part.version }
            if part.eof {
                guard part.size == Double(bytes.count) else { throw notWhole }
                break
            }
            // An empty part before the end would never get further: ending here returned a truncated file as if it were whole.
            if chunk.isEmpty { throw notWhole }
        }
        return StoredFile(value: bytes, version: version ?? "")
    }

    /// A whole file as UTF-8 text.
    public func readText(_ path: String) async throws -> StoredFile<String> {
        let file = try await readData(path)
        return StoredFile(value: String(decoding: file.value, as: UTF8.self), version: file.version)
    }

    /// A JSON document and its version, or nil when there is no such file.
    public func readJSON<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> StoredFile<T>? {
        let file: StoredFile<Data>
        do {
            file = try await readData(path)
        } catch let error as PluginError where error.code == "notFound" {
            return nil
        }
        do {
            return StoredFile(value: try JSONDecoder().decode(T.self, from: file.value), version: file.version)
        } catch {
            throw PluginError("“\(path)” is not the JSON document this plugin expects.", code: "badDocument")
        }
    }

    /// Writes bytes all at once (a reader never sees half a file), in parts when it is large. A refusal is a `PluginError`
    /// (`code` "changed" with `data.currentVersion` when the file changed). Returns the new version.
    @discardableResult
    public func write(_ path: String, data: Data, ifVersion: IfVersion = .any) async throws -> String {
        try await write(path, data: data, text: nil, ifVersion: ifVersion)
    }

    /// Writes UTF-8 text.
    @discardableResult
    public func write(_ path: String, text: String, ifVersion: IfVersion = .any) async throws -> String {
        try await write(path, data: Data(text.utf8), text: text, ifVersion: ifVersion)
    }

    private func write(_ path: String, data: Data, text: String?, ifVersion: IfVersion) async throws -> String {
        guard data.count <= StorageLimits.fileBytes else {
            throw PluginError("“\(path)” is larger than the storage service takes (32 MB).", code: "tooLarge")
        }
        var base: [String: JSONValue] = ["place": .string(place), "path": .string(path)]
        if let condition = ifVersion.json { base["ifVersion"] = condition }
        if data.count <= StorageLimits.partBytes {
            var params = base
            if let text { params["content"] = .string(text) } else {
                params["content"] = .string(data.base64EncodedString())
                params["encoding"] = "base64"
            }
            return try await plugin.request(Method.storageWrite, .object(params))["version"]?.stringValue ?? ""
        }
        // In parts: base64, so a part never splits a character. Only the last part writes.
        var upload: String?
        var offset = 0
        while offset < data.count {
            let end = min(offset + StorageLimits.partBytes, data.count)
            var params = base
            params["content"] = .string(data.subdata(in: offset..<end).base64EncodedString())
            params["encoding"] = "base64"
            if let upload { params["upload"] = .string(upload) }
            let more = end < data.count
            if more { params["more"] = true }
            let result = try await plugin.request(Method.storageWrite, .object(params))
            if !more { return result["version"]?.stringValue ?? "" }
            upload = result["upload"]?.stringValue
            offset = end
        }
        throw PluginError("The upload ended without its last part.")
    }

    /// Writes a JSON document (pretty-printed, keys sorted, so a person can read it and a diff stays small).
    @discardableResult
    public func writeJSON<T: Encodable>(_ path: String, _ value: T, ifVersion: IfVersion = .any) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try await write(path, data: try encoder.encode(value) + Data("\n".utf8), ifVersion: ifVersion)
    }

    /// Writes `value` only if the file is still `baseVersion` (nil: only if there is none). If someone changed it meanwhile,
    /// nothing is written and you get a `Conflict` holding what you wanted to write and what is there now — merge, ask your
    /// user, then write again with `conflict.currentVersion`.
    public func writeIfUnchanged<T: Codable>(_ path: String, _ value: T, baseVersion: String?) async throws -> WriteOutcome<T> {
        do {
            return .written(version: try await writeJSON(path, value, ifVersion: IfVersion(baseVersion)))
        } catch let error as PluginError where error.code == "changed" {
            let theirs = try await readJSON(path, as: T.self)
            return .conflict(Conflict(path: path, mine: value, baseVersion: baseVersion, theirs: theirs))
        }
    }

    /// Deletes a file or folder. Answers whether it went to the Trash (true) or was deleted permanently (false).
    @discardableResult
    public func delete(_ path: String, ifVersion: String? = nil) async throws -> Bool {
        var params: [String: JSONValue] = ["place": .string(place), "path": .string(path)]
        if let ifVersion { params["ifVersion"] = .string(ifVersion) }
        return try await plugin.request(Method.storageDelete, .object(params))["trashed"]?.boolValue == true
    }

    /// Creates one folder (its parent must exist).
    public func createFolder(_ path: String) async throws {
        _ = try await plugin.request(Method.storageCreateFolder, ["place": .string(place), "path": .string(path)])
    }

    /// Creates every missing folder of `path` ("a/b/c"), ignoring ones that exist.
    public func createFolders(_ path: String) async throws {
        var sofar = ""
        for name in path.split(separator: "/") {
            sofar = sofar.isEmpty ? String(name) : "\(sofar)/\(name)"
            do {
                try await createFolder(sofar)
            } catch let error as PluginError where error.code == "exists" {
                continue
            }
        }
    }
}
