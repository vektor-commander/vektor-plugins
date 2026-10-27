import Foundation
import VektorPlugin

// The place the user chose for a workspace's boards, reached ONLY through Vektor's storage service: this plugin has no
// credentials, no S3, SFTP or SMB code and never learns an address or a password. `VektorPlace` is the real one (the SDK's
// `Storage`); the tests wrap it to stop a sync between two writes or to change the place behind the plugin's back.

/// What a sync needs from a place. Paths are relative to the place.
@MainActor
public protocol PlaceStore: AnyObject {
    /// What to show the user ("neon (SFTP) ▸ /home/me/boards"). Also what tells two places apart between runs.
    var label: String { get }
    /// Whether the place is on a connection (a Sync button) or a local folder (saved on each change).
    var isRemote: Bool { get }
    /// The files of a folder with their versions; empty when the folder is not there.
    func list(_ folder: String) async throws -> [StorageEntry]
    /// A file and its version, or nil when it is not there.
    func read(_ path: String) async throws -> (data: Data, version: String)?
    /// Writes a whole file only if it is still `ifVersion` (`.absent`: only if there is none). Throws `PlaceChanged` otherwise.
    func write(_ path: String, data: Data, ifVersion: IfVersion) async throws -> String
    /// Deletes a file only if it is still `ifVersion`; one that is already gone is fine. Throws `PlaceChanged` otherwise.
    func delete(_ path: String, ifVersion: String) async throws
    /// Creates a folder; one that exists is fine.
    func createFolder(_ path: String) async throws
}

/// The place changed since it was read (`ifVersion` refused): the sync starts again rather than overwrite it.
struct PlaceChanged: Error {}

/// The real place: Vektor's storage service.
@MainActor
public final class VektorPlace: PlaceStore {
    public let storage: Storage
    public let label: String
    public let isRemote: Bool

    public init(plugin: Plugin, handle: PlaceHandle) {
        storage = plugin.storage(handle)
        label = handle.label
        isRemote = handle.remote
    }

    public func list(_ folder: String) async throws -> [StorageEntry] {
        do { return try await storage.list(folder) } catch let error as PluginError where error.code == "notFound" { return [] } catch {
            throw Self.plain(error)
        }
    }

    public func read(_ path: String) async throws -> (data: Data, version: String)? {
        do {
            let file = try await storage.readData(path)
            return (file.value, file.version)
        } catch let error as PluginError where error.code == "notFound" {
            return nil
        } catch {
            throw Self.plain(error)
        }
    }

    public func write(_ path: String, data: Data, ifVersion: IfVersion) async throws -> String {
        do { return try await storage.write(path, data: data, ifVersion: ifVersion) } catch let error as PluginError where error.code == "changed" {
            throw PlaceChanged()
        } catch {
            throw Self.plain(error)
        }
    }

    public func delete(_ path: String, ifVersion: String) async throws {
        do { try await storage.delete(path, ifVersion: ifVersion) } catch let error as PluginError where error.code == "notFound" {
            return
        } catch let error as PluginError where error.code == "changed" {
            throw PlaceChanged()
        } catch {
            throw Self.plain(error)
        }
    }

    public func createFolder(_ path: String) async throws {
        do { try await storage.createFolder(path) } catch let error as PluginError where error.code == "exists" { return } catch {
            throw Self.plain(error)
        }
    }

    /// Vektor's refusals are already plain words; a timeout or anything else becomes a sentence about the place.
    static func plain(_ error: Error) -> Error {
        if let error = error as? PluginError {
            switch error.code {
            case "offline": return BoardError("The place is offline. Connect it in Vektor, then sync again.")
            case "needsSignIn": return BoardError("The place needs you to sign in. Sign in in Vektor, then sync again.")
            case "missing", "badPlace": return BoardError("The place is not available in this workspace any more. Choose it again in the plugin's settings.")
            case "timeout": return BoardError("The place did not answer in time. Nothing was lost; sync again later.")
            default: return BoardError(error.message)
            }
        }
        return error
    }
}
