import Foundation

// Typed messages: every method in the plugin reference (docs/reference.md), in both directions. Field names are exactly the
// wire's. Unknown fields are ignored when decoding (Vektor adds fields without a version bump); `raw` keeps the whole
// parameters where a type would lose something.

/// The method names, as the wire spells them.
public enum Method {
    // From Vektor
    public static let startup = "startup"
    public static let shutdown = "shutdown"
    public static let invoke = "invoke"
    public static let settingsChanged = "settingsChanged"
    public static let viewOpened = "view/opened"
    public static let viewClosed = "view/closed"
    public static let viewEvent = "view/event"
    /// API 2: Vektor could not show a description or a patch (`ViewRefusal`).
    public static let viewRefused = "view/refused"
    public static let webMessage = "web/message"
    public static let workspaceChanged = "workspace/changed"
    public static let processOutput = "process/output"
    public static let processExited = "process/exited"
    public static let ping = "ping"
    public static let cancel = "$/cancel"
    public static let decorationsGet = "decorations/get"
    public static let infoGet = "info/get"
    public static let footerGet = "footer/get"
    // From the plugin
    public static let log = "log"
    public static let toast = "toast"
    public static let alert = "alert"
    public static let confirm = "confirm"
    public static let clipboardWriteText = "clipboard/writeText"
    public static let settingsGet = "settings/get"
    public static let settingsStatus = "settings/status"
    public static let dialogShow = "dialog/show"
    public static let viewUpdate = "view/update"
    public static let viewPatch = "view/patch"
    public static let sidebarItems = "sidebar/items"
    public static let sidebarBadge = "sidebar/badge"
    public static let webPost = "web/post"
    public static let openURL = "openURL"
    public static let navigate = "navigate"
    public static let reveal = "reveal"
    public static let processStart = "process/start"
    public static let processStop = "process/stop"
    public static let secretsRead = "secrets/read"
    public static let secretsWrite = "secrets/write"
    public static let secretsDelete = "secrets/delete"
    public static let storageStatus = "storage/status"
    public static let storageList = "storage/list"
    public static let storageRead = "storage/read"
    public static let storageWrite = "storage/write"
    public static let storageDelete = "storage/delete"
    public static let storageCreateFolder = "storage/createFolder"
    public static let decorationsChanged = "decorations/changed"
    public static let footerChanged = "footer/changed"

    /// Methods Vektor sends as notifications (no answer). Every other method Vektor sends is a request.
    public static let vektorNotifications: Set<String> = [
        settingsChanged, viewOpened, viewClosed, viewEvent, viewRefused, webMessage, workspaceChanged, processOutput, processExited, cancel,
    ]
}

// MARK: - Common shapes

public enum Tone: String, Codable, Sendable { case positive, neutral, warning, error }

/// The active workspace.
public struct Workspace: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A `place` setting's value: an opaque handle. Pass `place` back unchanged; never store it across runs.
public struct PlaceHandle: Codable, Equatable, Sendable {
    public var place: String
    public var label: String
    public var remote: Bool
}

/// A file or folder Vektor hands the plugin: a `path` on this Mac, or a `location` for an S3, SFTP or container item.
public struct Item: Codable, Equatable, Sendable {
    public var path: String?
    public var location: String?
    public var remote: Bool?
    public var name: String
    public var isFolder: Bool
    public var size: Double?
    public var id: String?
}

public struct InvokeTarget: Codable, Equatable, Sendable {
    public struct Connection: Codable, Equatable, Sendable { public var id: String; public var kind: String }
    public struct Website: Codable, Equatable, Sendable { public var url: String; public var name: String }
    public var menu: String?
    public var items: [Item]?
    /// The folder the menu was opened in: its path (Vektor sends a string here, not an item).
    public var folder: String?
    public var connection: Connection?
    public var website: Website?
    public var text: String?
    /// The sidebar entry a menu belongs to.
    public var entry: String?
    /// API 2: the sidebar item a `sidebarItem` menu belongs to.
    public var item: String?
    /// `drop` or `footer` for those sources.
    public var source: String?
    public var surface: String?
    public var view: String?
    public init() {}

    private enum CodingKeys: String, CodingKey { case menu, items, folder, connection, website, text, entry, item, source, surface, view }

    /// Field by field: a field whose shape this SDK does not expect (a newer Vektor's, say) is left out on its own. Decoding
    /// the whole target in one go turned one unexpected field into an empty target, so every command saw no items.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menu = try? c.decodeIfPresent(String.self, forKey: .menu)
        items = try? c.decodeIfPresent([Item].self, forKey: .items)
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        connection = try? c.decodeIfPresent(Connection.self, forKey: .connection)
        website = try? c.decodeIfPresent(Website.self, forKey: .website)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        entry = try? c.decodeIfPresent(String.self, forKey: .entry)
        item = try? c.decodeIfPresent(String.self, forKey: .item)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        surface = try? c.decodeIfPresent(String.self, forKey: .surface)
        view = try? c.decodeIfPresent(String.self, forKey: .view)
    }
}

// MARK: - From Vektor

public struct StartupParams: Codable, Equatable, Sendable {
    public var vektorVersion: String
    public var pluginID: String
    public var previousSessionEndedUncleanly: Bool
    public var sessionTemporaryFolder: String
    public var dataFolder: String
    public var settings: [String: JSONValue]
    public var workspace: Workspace?
}

public struct InvokeParams: Codable, Equatable, Sendable {
    public var command: String
    public var target: InvokeTarget
}

/// `{}`, or a message shown as a short notice.
public struct InvokeResult: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    public var message: String?
    public init(message: String? = nil) { self.message = message }
    public init(stringLiteral value: String) { message = value }
}

public struct SettingsChangedParams: Codable, Equatable, Sendable {
    public var settings: [String: JSONValue]
    public var workspace: Workspace?
}

public struct ViewOpenedParams: Codable, Equatable, Sendable {
    public var view: String
    /// API 2: the sidebar item that opened it.
    public var item: String?
}

/// A file dropped on a block (`fileDrop`): local items only.
public struct DroppedFile: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var isFolder: Bool
}

/// `view/event`: what the user did in a view. `raw` holds every parameter as sent.
public struct ViewEvent: Equatable, Sendable {
    public var view: String
    public var action: String
    public var revision: Int?
    // API 1 kinds
    public var card: String?
    public var value: JSONValue?
    public var field: String?
    public var before: String?
    public var index: Int?
    public var group: String?
    // Block views (API 2)
    public var block: String?
    public var item: String?
    public var from: String?
    public var target: String?
    public var files: [DroppedFile]?
    public var column: String?
    public var ascending: Bool?
    public var selected: [String]?
    /// The event was made against an older revision than the one sent last (set by `ViewState`).
    public var isStale = false
    public var raw: JSONValue

    public init(_ params: JSONValue) {
        raw = params
        view = params["view"]?.stringValue ?? ""
        action = params["action"]?.stringValue ?? ""
        revision = params["revision"]?.intValue
        card = params["card"]?.stringValue
        value = params["value"]
        field = params["field"]?.stringValue
        before = params["before"]?.stringValue
        index = params["index"]?.intValue
        group = params["group"]?.stringValue
        block = params["block"]?.stringValue
        item = params["item"]?.stringValue
        from = params["from"]?.stringValue
        target = params["target"]?.stringValue
        files = try? params["files"]?.decode([DroppedFile].self)
        column = params["column"]?.stringValue
        ascending = params["ascending"]?.boolValue
        selected = params["selected"]?.arrayValue?.compactMap(\.stringValue)
    }

    /// The event moves an item (a drag, ⌥ + an arrow, a list reorder): its position means what the user saw.
    public var isMove: Bool { target != nil || item != nil || before != nil || index != nil }
    /// `value` as text, when it is text.
    public var text: String? { value?.stringValue }
}

/// `view/refused` (API 2): Vektor could not show what the plugin sent for a view — a description (`view/update`) or a patch
/// (`view/patch`) — and keeps showing what it showed. `revision` is the revision Vektor **still shows** (nil while the view has
/// no numbered description): every `view/event` keeps carrying it until the plugin sends something Vektor can show, so an event
/// made against it is not stale. The answer is the whole description again, numbered above anything sent (`ViewState` does
/// that for a refused patch). An `"api": 1` plugin is never sent one; its refusals are only in the Log.
public struct ViewRefusal: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A whole description (`view/update`) that could not be shown.
        case description
        /// A patch (`view/patch`) that could not apply, or patched a view with nothing to patch.
        case patch
    }
    public var view: String
    /// nil for a kind this SDK does not know (a newer Vektor's).
    public var kind: Kind?
    /// The revision Vektor still shows: the one its events carry. nil while the view has no numbered description.
    public var revision: Int?
    /// The revision the refused message carried, when it had one.
    public var refusedRevision: Int?
    /// Why, in plain words (as the Log says it).
    public var problem: String
    public var raw: JSONValue

    public init(view: String, kind: Kind, revision: Int?, refusedRevision: Int? = nil, problem: String) {
        self.view = view
        self.kind = kind
        self.revision = revision
        self.refusedRevision = refusedRevision
        self.problem = problem
        var object: [String: JSONValue] = [
            "view": .string(view), "kind": .string(kind.rawValue), "revision": revision.map(JSONValue.int) ?? .null, "problem": .string(problem),
        ]
        if let refusedRevision { object["refusedRevision"] = .int(refusedRevision) }
        raw = .object(object)
    }

    public init(_ params: JSONValue) {
        raw = params
        view = params["view"]?.stringValue ?? ""
        kind = params["kind"]?.stringValue.flatMap(Kind.init(rawValue:))
        revision = params["revision"]?.intValue
        refusedRevision = params["refusedRevision"]?.intValue
        problem = params["problem"]?.stringValue ?? ""
    }

    /// The notification's parameters, as Vektor sends them (`revision` always present, `null` when there is none).
    public var json: JSONValue { raw }
}

public struct WebMessageParams: Equatable, Sendable {
    public var view: String
    /// The `web` block's id, when the page is a block of a block view.
    public var block: String?
    public var message: JSONValue
}

public struct ProcessOutputParams: Codable, Equatable, Sendable {
    public var processID: String
    public var stream: String
    public var text: String
}

public struct ProcessExitedParams: Codable, Equatable, Sendable {
    public var processID: String
    public var status: Int
}

public enum DecorationSymbol: String, Codable, Sendable, CaseIterable {
    case dot, check, modified, added, removed, untracked, conflict, warning, error, ignored, synced, uploading, downloading, cloud,
        locked, star, clock, info
}

public struct DecorationsGetParams: Codable, Equatable, Sendable { public var items: [Item] }
public struct Decoration: Codable, Equatable, Sendable {
    public var id: String
    public var symbol: DecorationSymbol
    public var tone: Tone?
    public var label: String
    public init(id: String, symbol: DecorationSymbol, tone: Tone? = nil, label: String) {
        self.id = id
        self.symbol = symbol
        self.tone = tone
        self.label = label
    }
}
public struct DecorationsGetResult: Codable, Equatable, Sendable {
    public var decorations: [Decoration]
    public init(decorations: [Decoration]) { self.decorations = decorations }
}
public struct InfoGetParams: Codable, Equatable, Sendable { public var item: Item }
public struct InfoRow: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}
public struct InfoGetResult: Codable, Equatable, Sendable {
    public var rows: [InfoRow]
    public init(rows: [InfoRow]) { self.rows = rows }
}
public struct FooterGetParams: Codable, Equatable, Sendable {
    public var folder: Item
    public var location: String?
}
/// `text` nil answers `{}`: nothing in the footer.
public struct FooterGetResult: Codable, Equatable, Sendable {
    public var text: String?
    public var symbol: String?
    public var label: String?
    public init(text: String? = nil, symbol: String? = nil, label: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.label = label
    }
}

// MARK: - From the plugin

public enum LogLevel: String, Codable, Sendable { case debug, info, warning, error }

public struct ConfirmParams: Codable, Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmTitle: String?
    public init(title: String, message: String, confirmTitle: String? = nil) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
    }
}

public struct SettingsGetResult: Codable, Equatable, Sendable {
    public var settings: [String: JSONValue]
    public var workspace: Workspace?
}

public struct SettingsStatusParams: Codable, Equatable, Sendable {
    public var key: String
    public var text: String
    public var tone: Tone?
    public var detail: String?
    public init(key: String, text: String, tone: Tone? = nil, detail: String? = nil) {
        self.key = key
        self.text = text
        self.tone = tone
        self.detail = detail
    }
}

/// A dialog field: the same kinds and rules as a setting, plus `readOnlyPath`.
public struct DialogField: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, number, toggle, choice, path, secret, list, readOnlyPath }
    public struct Choice: Codable, Equatable, Sendable {
        public var value: String
        public var title: String
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }
    public struct Banner: Codable, Equatable, Sendable {
        public var text: String
        public var linkTitle: String?
        public var link: String?
        public init(text: String, linkTitle: String? = nil, link: String? = nil) {
            self.text = text
            self.linkTitle = linkTitle
            self.link = link
        }
    }
    public var key: String
    public var kind: Kind
    public var label: String
    public var help: String?
    public var `default`: JSONValue?
    public var required: Bool?
    public var placeholder: String?
    public var pattern: String?
    public var multiline: Bool?
    public var min: Double?
    public var max: Double?
    public var unit: String?
    public var integer: Bool?
    public var options: [Choice]?
    public var style: String?
    public var pathKind: String?
    public var itemKind: String?
    public var path: String?
    public var banner: Banner?

    public init(
        key: String, kind: Kind, label: String, help: String? = nil, default: JSONValue? = nil, required: Bool? = nil,
        placeholder: String? = nil, pattern: String? = nil, multiline: Bool? = nil, min: Double? = nil, max: Double? = nil,
        unit: String? = nil, integer: Bool? = nil, options: [Choice]? = nil, style: String? = nil, pathKind: String? = nil,
        itemKind: String? = nil, path: String? = nil, banner: Banner? = nil
    ) {
        self.key = key
        self.kind = kind
        self.label = label
        self.help = help
        self.default = `default`
        self.required = required
        self.placeholder = placeholder
        self.pattern = pattern
        self.multiline = multiline
        self.min = min
        self.max = max
        self.unit = unit
        self.integer = integer
        self.options = options
        self.style = style
        self.pathKind = pathKind
        self.itemKind = itemKind
        self.path = path
        self.banner = banner
    }
}

public struct DialogSection: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var open: Bool?
    public var fields: [DialogField]
    public init(id: String, title: String, open: Bool? = nil, fields: [DialogField]) {
        self.id = id
        self.title = title
        self.open = open
        self.fields = fields
    }
}

public struct DialogShowParams: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var primary: String?
    public var cancel: String?
    public var fields: [DialogField]?
    public var sections: [DialogSection]?
    public init(title: String, subtitle: String? = nil, primary: String? = nil, cancel: String? = nil, fields: [DialogField]? = nil, sections: [DialogSection]? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.cancel = cancel
        self.fields = fields
        self.sections = sections
    }
}

public struct DialogShowResult: Codable, Equatable, Sendable {
    public var result: String
    /// The fields' values; empty when the dialog was cancelled (an older Vektor sends no `values` then).
    public var values: [String: JSONValue]
    public var submitted: Bool { result == "submit" }
    public init(result: String, values: [String: JSONValue] = [:]) {
        self.result = result
        self.values = values
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(String.self, forKey: .result)
        values = try container.decodeIfPresent([String: JSONValue].self, forKey: .values) ?? [:]
    }
}

public struct SidebarItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    /// A short word or a count beside the title.
    public var badge: String?
    public init(id: String, title: String, symbol: String? = nil, badge: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.badge = badge
    }
}

public struct SidebarBadgeParams: Codable, Equatable, Sendable {
    public var entry: String
    public var count: Int?
    public var text: String?
    public var tone: Tone?
    public var symbol: String?
    public var label: String?
    public init(entry: String, count: Int? = nil, text: String? = nil, tone: Tone? = nil, symbol: String? = nil, label: String? = nil) {
        self.entry = entry
        self.count = count
        self.text = text
        self.tone = tone
        self.symbol = symbol
        self.label = label
    }
}

public struct ProcessStartParams: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]?
    public var environment: [String: String]?
    public var workingDirectory: String?
    public init(executable: String, arguments: [String]? = nil, environment: [String: String]? = nil, workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum StorageState: String, Codable, Sendable { case available, offline, needsSignIn, missing }

public struct StorageStatus: Codable, Equatable, Sendable {
    public var state: StorageState
    /// The place in words; empty when Vektor could not say (a place it cannot find answers only `state`).
    public var label: String
    /// `false`, and `writes`/`conditional` empty, when the place could not be reached to ask (`missing`, `offline`…).
    public var remote: Bool
    public var writes: String
    public var conditional: String
}

extension StorageStatus {
    /// Vektor answers only `state` (and sometimes `label`) for a place it cannot reach: the rest decodes as empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(StorageState.self, forKey: .state)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        remote = try container.decodeIfPresent(Bool.self, forKey: .remote) ?? false
        writes = try container.decodeIfPresent(String.self, forKey: .writes) ?? ""
        conditional = try container.decodeIfPresent(String.self, forKey: .conditional) ?? ""
    }
}

public struct StorageEntry: Codable, Equatable, Sendable {
    public var name: String
    public var isFolder: Bool
    public var size: Double?
    public var modified: String?
    public var version: String?
}

public struct StorageListPage: Codable, Equatable, Sendable {
    public var entries: [StorageEntry]
    public var next: String?
}

public struct StorageReadPart: Codable, Equatable, Sendable {
    public var content: String
    public var encoding: String
    public var version: String
    public var size: Double
    public var offset: Double
    public var eof: Bool
}
