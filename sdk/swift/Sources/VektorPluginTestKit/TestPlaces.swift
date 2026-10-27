import Foundation
import VektorPlugin

/// A refused storage call: the words, the code and the data Vektor would send.
public struct StorageRefusal: Error, Sendable {
    public var code: String
    public var message: String
    public var data: JSONValue?
    public var json: JSONValue {
        var object: [String: JSONValue] = ["message": .string(message), "code": .string(code)]
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// The storage service of the test host, on folders under a temporary folder: the path rules, versions, `ifVersion`,
/// parts, pages with cursors, refusal codes, and a stand-in Trash — what Vektor answers for a folder on this Mac.
@MainActor
public final class TestPlaces {
    public let work: URL
    /// Where deleted items go (never the user's own Trash).
    public let trash: URL
    private var places: [String: (name: String, folder: String)] = [:]
    private var uploads: [String: (place: String, path: String, bytes: Data)] = [:]
    private var cursors: [String: (place: String, path: String, names: [String], offset: Int, created: Date)] = [:]

    static let partBytes = 512 * 1024
    static let fileBytes = 32 * 1024 * 1024
    static let disguisedSlashes: [Character] = ["\\", "\u{2215}", "\u{2044}", "\u{FF0F}", "\u{29F8}", "\u{29F5}", "\u{FE68}"]

    init(work: URL) {
        self.work = work
        trash = work.appendingPathComponent("trash")
    }

    /// Replaces each `{"$place": name}` setting with a handle; answers `place.<name>` variables (the folders).
    func substitute(_ settings: [String: JSONValue]) -> (settings: [String: JSONValue], variables: [String: String]) {
        var result = settings
        var variables: [String: String] = [:]
        for (key, value) in settings {
            guard let object = value.objectValue, object.count == 1, let name = object["$place"]?.stringValue,
                !name.isEmpty, !name.contains("/"), name != ".", name != ".."
            else { continue }
            let folder = work.appendingPathComponent("places/\(name)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
            let token = "pl-" + String((0..<26).map { _ in alphabet[Int.random(in: 0..<32)] })
            places[token] = (name, URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().path)
            result[key] = ["place": .string(token), "label": .string("Test place ▸ \(name)"), "remote": false]
            variables["place.\(name)"] = folder.path
        }
        return (result, variables)
    }

    /// The answer to one storage request.
    public func answer(_ method: String, _ params: JSONValue) -> Result<JSONValue, StorageRefusal> {
        do { return .success(try respond(method, params)) } catch let refusal as StorageRefusal { return .failure(refusal) } catch {
            return .failure(StorageRefusal(code: "failed", message: error.localizedDescription))
        }
    }

    static func problem(_ part: String) -> String? {
        if part.isEmpty { return "it has an empty name (two “/” in a row, or one at the end)." }
        if part == "." || part == ".." { return "“.” and “..” are not names." }
        if part.utf8.count > 255 { return "a name is longer than 255 bytes." }
        if part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) {
            return "a name contains a control character."
        }
        if part.contains(where: { disguisedSlashes.contains($0) }) { return "a name contains a character that looks like a slash." }
        let folded = part.precomposedStringWithCompatibilityMapping
        if folded == "." || folded == ".." || folded.contains("/") || folded.contains(where: { disguisedSlashes.contains($0) }) {
            return "a name reads as “.”, “..” or a slash once its characters are normalised."
        }
        if part.lowercased().hasPrefix(".vektor-") || folded.lowercased().hasPrefix(".vektor-") { return "names starting with “.vektor-” are Vektor's own." }
        if [".trash", ".trashes"].contains(part.lowercased()) || [".trash", ".trashes"].contains(folded.lowercased()) {
            return "“\(part)” is the Trash's own folder."
        }
        return nil
    }

    static func listable(_ name: String) -> Bool {
        !name.lowercased().hasPrefix(".vektor-") && ![".trash", ".trashes"].contains(name.lowercased()) && problem(name) == nil
    }

    private func parsePath(_ value: JSONValue?, allowRoot: Bool) throws -> [String] {
        let raw = value?.stringValue ?? ""
        func bad(_ reason: String) -> StorageRefusal { StorageRefusal(code: "badPath", message: "That path cannot be used: \(reason)") }
        if raw.isEmpty || raw == "." {
            if allowRoot { return [] }
            throw bad("a file or folder name is needed.")
        }
        if raw.utf8.count > 1024 { throw bad("it is longer than 1024 bytes.") }
        if raw.hasPrefix("/") || raw.hasPrefix("~") { throw bad("paths are relative to the place, so they cannot start with “/” or “~”.") }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 32 { throw bad("it is more than 32 folders deep.") }
        for part in parts { if let problem = Self.problem(part) { throw bad(problem) } }
        return parts
    }

    private func version(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return "v1.l.\(info.st_dev).\(info.st_ino).\(nanoseconds).\(info.st_size)"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func respond(_ method: String, _ params: JSONValue) throws -> JSONValue {
        let known = ["storage/status", "storage/list", "storage/read", "storage/write", "storage/delete", "storage/createFolder"]
        guard known.contains(method) else { throw StorageRefusal(code: "badRequest", message: "The request cannot be used: Vektor does not offer “\(method)”.") }
        guard let token = params["place"]?.stringValue, let place = places[token] else {
            throw StorageRefusal(code: "badPlace", message: "That place is not one Vektor gave this plugin. Use the value of the place setting as it was sent.", data: ["state": "missing"])
        }
        let label = "Test place ▸ \(place.name)"
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: place.folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw StorageRefusal(code: "missing", message: "The folder “\(label)” no longer exists.", data: ["state": "missing"])
        }
        func shown(_ parts: [String]) -> String { parts.isEmpty ? "/" : parts.joined(separator: "/") }
        func parent(of parts: [String]) throws -> String {
            guard parts.count > 1 else { return place.folder }
            let joined = place.folder + "/" + parts.dropLast().joined(separator: "/")
            guard manager.fileExists(atPath: joined) else { throw StorageRefusal(code: "notFound", message: "“\(shown(Array(parts.dropLast())))” does not exist.") }
            let real = URL(fileURLWithPath: joined).resolvingSymlinksInPath().path
            guard real == place.folder || real.hasPrefix(place.folder + "/") else {
                throw StorageRefusal(code: "badPath", message: "“\(shown(parts))” leads outside the place, so Vektor refused it.")
            }
            var folder: ObjCBool = false
            guard manager.fileExists(atPath: real, isDirectory: &folder), folder.boolValue else {
                throw StorageRefusal(code: "wrongKind", message: "“\(shown(Array(parts.dropLast())))” is not a folder.")
            }
            return real
        }
        func changed(_ parts: [String], _ now: String?) -> StorageRefusal {
            StorageRefusal(code: "changed", message: "“\(shown(parts))” changed since you read it.", data: now.map { ["currentVersion": .string($0)] })
        }
        enum Condition { case any, absent, version(String) }
        // As Vektor: a version must look like one it gives (`v1.` …); null ("only if nothing is there") only for a write. Vektor
        // checks this while parsing the request, so a malformed one is badRequest before the file is looked at.
        func condition() throws -> Condition {
            guard let raw = params["ifVersion"] else { return .any }
            if raw == .null {
                if method == "storage/write" { return .absent }
                throw StorageRefusal(code: "badRequest", message: "The request cannot be used: “ifVersion” must be a version here.")
            }
            guard let version = raw.stringValue, version.hasPrefix("v1."), version.count <= 200,
                version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else {
                throw StorageRefusal(code: "badRequest", message: "The request cannot be used: “ifVersion” must be a version Vektor gave, or null.")
            }
            return .version(version)
        }

        switch method {
        case "storage/status":
            return ["state": "available", "label": .string(label), "remote": false, "writes": "atomic", "conditional": "checked"]

        case "storage/list":
            let parts = try parsePath(params["path"], allowRoot: true)
            var limit = 1000
            if let raw = params["limit"], raw != .null {
                guard let number = raw.intValue, (1...5000).contains(number) else {
                    throw StorageRefusal(code: "badRequest", message: "The request cannot be used: “limit” must be a whole number from 1 to 5000.")
                }
                limit = number
            }
            let folder = parts.isEmpty ? place.folder : try parent(of: parts) + "/" + parts.last!
            var listing: (place: String, path: String, names: [String], offset: Int, created: Date)
            if let raw = params["cursor"], raw != .null {
                guard let cursor = raw.stringValue, let held = cursors[cursor] else {
                    throw StorageRefusal(code: "badCursor", message: "That cursor cannot be used: it has expired, or Vektor did not give it. List the folder again from the start.")
                }
                guard held.place == token, held.path == shown(parts) else {
                    throw StorageRefusal(code: "badCursor", message: "That cursor cannot be used: it was given for another folder, place or plugin. List this folder again from the start.")
                }
                guard Date().timeIntervalSince(held.created) < 600 else {
                    cursors[cursor] = nil
                    throw StorageRefusal(code: "badCursor", message: "That cursor cannot be used: it has expired, or Vektor did not give it. List the folder again from the start.")
                }
                listing = held
            } else {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: folder, isDirectory: &isDirectory) else {
                    throw StorageRefusal(code: "notFound", message: "“\(shown(parts))” does not exist.")
                }
                guard isDirectory.boolValue else { throw StorageRefusal(code: "wrongKind", message: "“\(shown(parts))” is not a folder.") }
                let names = ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).filter(Self.listable).sorted()
                listing = (token, shown(parts), names, 0, Date())
            }
            var entries: [JSONValue] = []
            var offset = listing.offset
            while offset < listing.names.count, entries.count < limit {
                let name = listing.names[offset]
                offset += 1
                let full = folder + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: full) else { continue }
                var type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    let real = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
                    guard real == place.folder || real.hasPrefix(place.folder + "/"), let target = try? manager.attributesOfItem(atPath: real) else { continue }
                    type = target[.type] as? FileAttributeType
                }
                let modified = (attributes[.modificationDate] as? Date).map(Self.timestamp)
                if type == .typeDirectory {
                    entries.append(["name": .string(name), "isFolder": true, "modified": .text(modified)])
                } else if type == .typeRegular {
                    entries.append([
                        "name": .string(name), "isFolder": false, "size": .number(Double((attributes[.size] as? NSNumber)?.int64Value ?? 0)),
                        "modified": .text(modified), "version": .text(version(full)),
                    ])
                }
            }
            var result: [String: JSONValue] = ["entries": .array(entries)]
            if offset < listing.names.count {
                let cursor = "cu-" + UUID().uuidString.lowercased()
                listing.offset = offset
                cursors[cursor] = listing
                result["next"] = .string(cursor)
            }
            return .object(result)

        case "storage/read":
            let parts = try parsePath(params["path"], allowRoot: false)
            let wanted = try condition()
            let file = try parent(of: parts) + "/" + parts.last!
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: file, isDirectory: &isDirectory) else { throw StorageRefusal(code: "notFound", message: "“\(shown(parts))” does not exist.") }
            guard !isDirectory.boolValue, let current = version(URL(fileURLWithPath: file).resolvingSymlinksInPath().path) else {
                throw StorageRefusal(code: "wrongKind", message: "“\(shown(parts))” is a folder, not a file.")
            }
            if case .version(let expected) = wanted, expected != current { throw changed(parts, current) }
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            let offset = max(0, params["offset"]?.intValue ?? 0)
            let length = min(max(0, params["length"]?.intValue ?? Self.partBytes), Self.partBytes)
            let start = min(offset, data.count)
            let bytes = data.subdata(in: start..<min(start + length, data.count))
            var answer: [String: JSONValue] = [
                "version": .string(current), "size": .int(data.count), "offset": .int(offset), "eof": .bool(offset + bytes.count >= data.count),
            ]
            // Text only when it gives back exactly these bytes: `String(data:encoding:)` drops a leading BOM, and repairing
            // decoding would change bytes that are not UTF-8 (a part ending inside a character, a binary file).
            let text = String(decoding: bytes, as: UTF8.self)
            if params["encoding"]?.stringValue != "base64", Data(text.utf8) == bytes {
                answer["content"] = .string(text)
                answer["encoding"] = "text"
            } else {
                answer["content"] = .string(bytes.base64EncodedString())
                answer["encoding"] = "base64"
            }
            return .object(answer)

        case "storage/write":
            let parts = try parsePath(params["path"], allowRoot: false)
            let wanted = try condition()  // on every part: only the last one is checked against the file
            guard let content = params["content"]?.stringValue else {
                throw StorageRefusal(code: "badRequest", message: "The content cannot be used: “content” must be text (or base64 with “encoding”: “base64”).")
            }
            var bytes: Data
            switch params["encoding"]?.stringValue {
            case nil, "text": bytes = Data(content.utf8)
            case "base64":
                guard let decoded = Data(base64Encoded: content) else { throw StorageRefusal(code: "badRequest", message: "The content cannot be used: it is not valid base64.") }
                bytes = decoded
            default: throw StorageRefusal(code: "badRequest", message: "The content cannot be used: “encoding” must be “text” or “base64”.")
            }
            guard bytes.count <= Self.partBytes else { throw StorageRefusal(code: "tooLarge", message: "That is larger than Vektor allows here (\(Self.partBytes / 1024) KB).") }
            let folder = try parent(of: parts)
            let file = folder + "/" + parts.last!
            if let upload = params["upload"]?.stringValue {
                guard let staged = uploads[upload], staged.place == token, staged.path == shown(parts) else {
                    throw StorageRefusal(code: "badRequest", message: "That upload is not one Vektor started for this plugin, or it was abandoned.")
                }
                bytes = staged.bytes + bytes
                guard bytes.count <= Self.fileBytes else { throw StorageRefusal(code: "tooLarge", message: "That is larger than Vektor allows here (\(Self.fileBytes / 1024) KB).") }
            }
            if params["more"] == .bool(true) {
                let id = params["upload"]?.stringValue ?? "up-" + UUID().uuidString.lowercased()
                uploads[id] = (token, shown(parts), bytes)
                return ["upload": .string(id)]
            }
            if let upload = params["upload"]?.stringValue { uploads[upload] = nil }
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: file, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue { throw StorageRefusal(code: "wrongKind", message: "“\(shown(parts))” is a folder, not a file.") }
            let now = version(file)
            switch wanted {
            case .absent where exists: throw changed(parts, now)
            case .version(let expected) where now != expected: throw changed(parts, now)
            default: break
            }
            let staged = folder + "/.vektor-storage-\(UUID().uuidString)"
            try bytes.write(to: URL(fileURLWithPath: staged))
            guard rename(staged, file) == 0 else {
                unlink(staged)
                throw StorageRefusal(code: "failed", message: "“\(shown(parts))” could not be written.")
            }
            return ["version": .text(version(file))]

        case "storage/delete":
            let parts = try parsePath(params["path"], allowRoot: false)
            let wanted = try condition()
            let file = try parent(of: parts) + "/" + parts.last!
            guard (try? manager.attributesOfItem(atPath: file)) != nil else { throw StorageRefusal(code: "notFound", message: "“\(shown(parts))” does not exist.") }
            if case .version(let expected) = wanted {
                guard let now = version(file) else { throw StorageRefusal(code: "wrongKind", message: "“\(shown(parts))” is a folder, not a file.") }
                if now != expected { throw changed(parts, now) }
            }
            try manager.createDirectory(at: trash, withIntermediateDirectories: true)
            try manager.moveItem(atPath: file, toPath: trash.appendingPathComponent("\(UUID().uuidString)-\(parts.last!)").path)
            return ["trashed": true]

        case "storage/createFolder":
            let parts = try parsePath(params["path"], allowRoot: false)
            let folder = try parent(of: parts) + "/" + parts.last!
            if manager.fileExists(atPath: folder) { throw StorageRefusal(code: "exists", message: "“\(shown(parts))” already exists.") }
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: false)
            return [:]

        default:
            return [:]
        }
    }
}
