import Foundation
import VektorPlugin
import VektorPluginTestKit

/// Runs `body(storage, host)` inside the plugin (a command), so every call goes over the wire to the test host's fake place.
@MainActor
private func inside(_ body: @escaping @MainActor (Storage, TestHost) async throws -> Void) async throws {
    let folder = try pluginFolder([
        "permissions": ["storage"], "settings": ["items": [["key": "boards", "kind": "place", "label": "Boards"]]],
    ])
    var options = TestHost.Options()
    options.settings = ["boards": ["$place": "boards"]]
    var failure: Error?
    var hostReference: TestHost?
    let host = try TestHost.start(folder: folder, options: options) { plugin in
        plugin.command("run") { _, _ in
            do { try await body(plugin.storage(plugin.place("boards")!), hostReference!) } catch { failure = error }
            return "ok"
        }
    }
    hostReference = host
    defer { Task { @MainActor in await host.close() } }
    try await host.startup()
    let answer = try await host.request("invoke", ["command": "run", "target": [:]], timeout: 30)
    if let failure { throw failure }
    try checkEqual(answer.kind, .response, "\(answer)")
}

@MainActor
func storageTests() async {
    await test("storage: the handle and status are what Vektor sends") {
        try await inside { storage, _ in
            try check(storage.place.range(of: "^pl-[a-z2-7]{26}$", options: .regularExpression) != nil)
            let status = try await storage.status()
            try checkEqual(status.state, .available)
            try checkEqual(status.label, "Test place ▸ boards")
            try checkEqual(status.conditional, "checked")
        }
    }

    await test("storage: JSON documents — write as new, read with its version, nil when missing") {
        try await inside { storage, host in
            try check(try await storage.readJSON("board.json", as: [String: [String]].self) == nil)
            let version = try await storage.writeJSON("board.json", ["cards": ["é", "👍"]], ifVersion: .absent)
            let read = try await storage.readJSON("board.json", as: [String: [String]].self)
            try checkEqual(read, StoredFile(value: ["cards": ["é", "👍"]], version: version))
            try check(FileManager.default.fileExists(atPath: host.variables["place.boards"]! + "/board.json"))
        }
    }

    await test("storage: writeIfUnchanged gives a Conflict with both versions when someone else wrote meanwhile") {
        try await inside { storage, host in
            _ = try await storage.writeIfUnchanged("board.json", ["title": "Base"], baseVersion: nil)
            let base = try await storage.readJSON("board.json", as: [String: String].self)!
            try Data(#"{"title":"Theirs"}"#.utf8).write(to: URL(fileURLWithPath: host.variables["place.boards"]! + "/board.json"))
            let outcome = try await storage.writeIfUnchanged("board.json", ["title": "Mine"], baseVersion: base.version)
            guard let conflict = outcome.conflict else { throw Failure(description: "expected a conflict") }
            try checkEqual(conflict.mine, ["title": "Mine"])
            try checkEqual(conflict.baseVersion, base.version)
            try checkEqual(conflict.theirs?.value, ["title": "Theirs"])
            try check(conflict.currentVersion != base.version)
            let merged = try await storage.writeIfUnchanged("board.json", ["title": "Mine + Theirs"], baseVersion: conflict.currentVersion)
            try check(merged.version != nil)
        }
    }

    await test("storage: expecting no file when one appeared, or a deleted file: conflicts") {
        try await inside { storage, host in
            try await storage.writeJSON("a.json", ["n": 1])
            let appeared = try await storage.writeIfUnchanged("a.json", ["n": 2], baseVersion: nil)
            try checkEqual(appeared.conflict?.theirs?.value, ["n": 1])
            let version = try await storage.writeJSON("gone.json", ["n": 1])
            try FileManager.default.removeItem(atPath: host.variables["place.boards"]! + "/gone.json")
            let gone = try await storage.writeIfUnchanged("gone.json", ["n": 2], baseVersion: version)
            try check(gone.conflict != nil && gone.conflict?.theirs == nil && gone.conflict?.currentVersion == nil)
        }
    }

    await test("storage: list follows every page; a made-up cursor is refused with badCursor") {
        try await inside { storage, host in
            let folder = host.variables["place.boards"]!
            for index in 0..<25 { try Data("{}".utf8).write(to: URL(fileURLWithPath: folder + String(format: "/card-%02d.json", index))) }
            try Data("hidden".utf8).write(to: URL(fileURLWithPath: folder + "/.vektor-temp"))
            try FileManager.default.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: false)
            let page = try await storage.listPage(limit: 10)
            try checkEqual(page.entries.count, 10)
            try check(page.next != nil)
            let all = try await storage.list(limit: 10)
            try checkEqual(all.count, 26)
            try check(!all.contains { $0.name.hasPrefix(".vektor-") })
            try check(all.first { $0.name == "sub" }?.isFolder == true)
            try await checkThrowsAsync({ _ = try await storage.listPage(cursor: "cu-forged") }, matching: "cursor cannot be used")
            try await checkThrowsAsync({ _ = try await storage.listPage("sub", cursor: page.next) }, matching: "another folder")
        }
    }

    await test("storage: a large file in parts both ways, multi-byte text intact") {
        try await inside { storage, _ in
            let text = String(repeating: "žluťoučký kůň 👍\n", count: 60000)
            try await storage.write("big.txt", text: text)
            try checkEqual(try await storage.readText("big.txt").value, text)
        }
    }

    await test("storage: delete answers trashed; refusal codes come through") {
        try await inside { storage, host in
            let version = try await storage.write("x.txt", text: "x")
            try check(try await storage.delete("x.txt", ifVersion: version))
            try checkEqual(try FileManager.default.contentsOfDirectory(atPath: host.places.trash.path).count, 1)
            do { _ = try await storage.readText("x.txt"); throw Failure(description: "read a deleted file") } catch let error as PluginError {
                try checkEqual(error.code, "notFound")
                try checkEqual(error.message, "“x.txt” does not exist.")
            }
            do { try await storage.write("../escape.txt", text: "x") } catch let error as PluginError { try checkEqual(error.code, "badPath") }
            do { try await storage.write("a/b.txt", text: "x") } catch let error as PluginError { try checkEqual(error.code, "notFound") }
            try await storage.createFolders("a/b")
            try await storage.createFolders("a/b")
            try await storage.write("a/b/c.txt", text: "deep")
            do { try await storage.createFolder("a") } catch let error as PluginError { try checkEqual(error.code, "exists") }
            do { try await storage.write("a/b/c.txt", text: "x", ifVersion: .version("made-up")); throw Failure(description: "accepted a made-up version") }
            catch let error as PluginError { try checkEqual(error.code, "badRequest") }
        }
    }

    await test("storage + sync: a three-way merge of cards, written back if unchanged") {
        try await inside { storage, host in
            let base: [JSONValue] = [["id": "a", "title": "A"], ["id": "b", "title": "B"]]
            try await storage.writeJSON("cards.json", base)
            try Data(#"[{"id":"a","title":"A"},{"id":"b","title":"B (there)"},{"id":"c","title":"C"}]"#.utf8)
                .write(to: URL(fileURLWithPath: host.variables["place.boards"]! + "/cards.json"))
            let theirs = try await storage.readJSON("cards.json", as: [JSONValue].self)!
            let result = try threeWayMerge(base: base, mine: [["id": "a", "title": "A (here)"], ["id": "b", "title": "B"]], theirs: theirs.value)
            try checkEqual(result.status, .merged)
            try check(try await storage.writeIfUnchanged("cards.json", result.records, baseVersion: theirs.version).version != nil)
            try checkEqual(try await storage.readJSON("cards.json", as: [JSONValue].self)!.value.compactMap { $0["title"]?.stringValue }, ["A (here)", "B (there)", "C"])
        }
    }

    await test("storage: a read in parts is checked whole — an empty part before the end, another offset, a short total, bad base64") {
        let refusals: [JSONValue] = [
            ["content": "", "encoding": "text", "version": "v1.x", "size": 10, "offset": 0, "eof": false],
            ["content": "abc", "encoding": "text", "version": "v1.x", "size": 3, "offset": 7, "eof": true],
            ["content": "abc", "encoding": "text", "version": "v1.x", "size": 10, "offset": 0, "eof": true],
            ["content": "not base64!", "encoding": "base64", "version": "v1.x", "size": 0, "offset": 0, "eof": true],
        ]
        for reply in refusals {
            let folder = try pluginFolder(["permissions": ["storage"]])
            var options = TestHost.Options()
            options.autoReply = ["storage/read": reply]
            var failure: Error?
            let host = try TestHost.start(folder: folder, options: options) { plugin in
                plugin.command("run") { _, _ in
                    do { _ = try await plugin.storage(place: "pl-test").readData("f.bin") } catch { failure = error }
                    return "ok"
                }
            }
            try await host.startup()
            _ = try await host.request("invoke", ["command": "run", "target": [:]], timeout: 30)
            await host.close()
            guard let error = failure as? PluginError else { throw Failure(description: "read \(reply) without an error: \(String(describing: failure))") }
            try checkEqual(error.code, "failed", "\(reply)")
            try checkEqual(error.message, "“f.bin” was not read whole.")
        }
    }

    await test("storage: the test host reads a file byte for byte — a UTF-8 BOM is kept, bytes that are not UTF-8 come as base64") {
        try await inside { storage, host in
            let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a":1}"#.utf8)
            try bom.write(to: URL(fileURLWithPath: host.variables["place.boards"]! + "/bom.json"))
            try checkEqual(try await storage.readData("bom.json").value, bom)
            let binary = Data([0xFF, 0x00, 0xFE])
            try binary.write(to: URL(fileURLWithPath: host.variables["place.boards"]! + "/bin"))
            try checkEqual(try await storage.readData("bin").value, binary)
        }
    }

    await test("storage: list ends at a page whose next is null, as at one without next") {
        let folder = try pluginFolder(["permissions": ["storage"]])
        var options = TestHost.Options()
        options.autoReply = ["storage/list": ["entries": [["name": "a", "isFolder": false]], "next": .null]]
        var names: [String]?
        var failure: Error?
        let host = try TestHost.start(folder: folder, options: options) { plugin in
            plugin.command("run") { _, _ in
                do { names = try await plugin.storage(place: "pl-test").list().map(\.name) } catch { failure = error }
                return "ok"
            }
        }
        try await host.startup()
        _ = try await host.request("invoke", ["command": "run", "target": [:]], timeout: 30)
        await host.close()
        if let failure { throw failure }
        try checkEqual(names, ["a"])
    }

    await test("storage: the test host checks ifVersion first, as Vektor parses it — before the file is looked at, on every part of a write") {
        try await inside { storage, host in
            @MainActor func code(_ method: String, _ params: [String: JSONValue]) -> String? {
                guard case .failure(let refusal) = host.places.answer(method, .object(params.merging(["place": .string(storage.place)]) { a, _ in a })) else { return nil }
                return refusal.code
            }
            try checkEqual(code("storage/read", ["path": "missing.txt", "ifVersion": .null]), "badRequest")
            try checkEqual(code("storage/delete", ["path": "missing.txt", "ifVersion": .null]), "badRequest")
            try checkEqual(code("storage/read", ["path": "missing.txt", "ifVersion": "made-up"]), "badRequest")
            try checkEqual(code("storage/delete", ["path": "missing.txt", "ifVersion": "made-up"]), "badRequest")
            try checkEqual(code("storage/write", ["path": "part.txt", "content": "x", "more": true, "ifVersion": "made-up"]), "badRequest")
            guard case .success(let started) = host.places.answer("storage/write", ["place": .string(storage.place), "path": "part.txt", "content": "x", "more": true]),
                let upload = started["upload"]
            else { throw Failure(description: "no upload") }
            try checkEqual(code("storage/write", ["path": "part.txt", "content": "y", "more": true, "upload": upload, "ifVersion": 7]), "badRequest")
            // A well-formed version of a file that is not there: Vektor answers notFound for a delete (it looks the item up first).
            try checkEqual(code("storage/delete", ["path": "missing.txt", "ifVersion": "v1.l.1.2.3.4"]), "notFound")
        }
    }
}
