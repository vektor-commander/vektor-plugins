import Foundation

// Settings-style form: sections of labelled fields, the way a preferences page reads.
//
//     try view.show(ViewDescription(root: form.block))
//     form.route(on: view, SettingsFormHandlers(onChange: { key, value in … }, onButton: { key in … }))
//
// Each field is a row: the label (and a line of help under it) on the left, the control on the right. A field has a `key` of
// yours; every change arrives as `onChange(key, value)` with the new value (text, true/false, a number, a date, a list of
// tags, a colour role), and a button field as `onButton(key)`. Keep the values in your own state and draw again: a field shows
// what you pass as `value`, so a value you refuse simply snaps back (and `error` says why).
//
// Blocks cannot show a password field; keep secrets in a `secret` setting of the manifest, which Vektor draws. Copy and adapt.

public struct SettingsField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text(value: String?, placeholder: String?)
        case textArea(value: String?, placeholder: String?)
        case toggle(value: Bool)
        case picker(options: [Option], value: String?, segmented: Bool)
        case stepper(value: Double?, min: Double?, max: Double?, step: Double?)
        /// `yyyy-MM-dd`.
        case date(value: String?)
        case tags(tags: [String], suggestions: [String]?)
        case role(value: Role?, roles: [Role]?)
        /// A button on its own line: `label` is the text beside it, `title` its own.
        case button(title: String, symbol: String?, style: Block.ButtonStyle?)
    }

    public var key: String
    public var label: String
    public var kind: Kind
    public var help: String?
    public var error: String?
    public var enabled: Bool?

    public init(key: String, label: String, kind: Kind, help: String? = nil, error: String? = nil, enabled: Bool? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.help = help
        self.error = error
        self.enabled = enabled
    }
}

public struct SettingsSection: Equatable, Sendable {
    public var id: String
    public var title: String?
    /// A line under the title.
    public var description: String?
    public var collapsible: Bool?
    public var collapsed: Bool?
    public var fields: [SettingsField]
    public init(id: String, title: String? = nil, description: String? = nil, collapsible: Bool? = nil, collapsed: Bool? = nil, fields: [SettingsField]) {
        self.id = id
        self.title = title
        self.description = description
        self.collapsible = collapsible
        self.collapsed = collapsed
        self.fields = fields
    }
}

public struct SettingsFormHandlers {
    /// A field changed. The value is what the control sends: text, true/false, a number, `yyyy-MM-dd`, a list of tags, a role.
    public var onChange: LayoutAction2<String, JSONValue>?
    /// A button field was pressed.
    public var onButton: LayoutAction<String>?
    public init(onChange: LayoutAction2<String, JSONValue>? = nil, onButton: LayoutAction<String>? = nil) {
        self.onChange = onChange
        self.onButton = onButton
    }
}

public struct SettingsForm {
    /// Prefix of every block id and action (default `settings`).
    public var id = "settings"
    public var sections: [SettingsSection]
    public init(sections: [SettingsSection]) { self.sections = sections }

    private var names: LayoutNames { LayoutNames(id) }

    private func control(_ field: SettingsField) -> Block {
        let fieldID = names.id("field", field.key)
        let change = names.id("change")
        var block: Block
        switch field.kind {
        case .text(let value, let placeholder):
            block = .textField(fieldID, action: change, value: value ?? "", placeholder: placeholder, error: field.error)
        case .textArea(let value, let placeholder):
            block = .textArea(fieldID, action: change, value: value ?? "", placeholder: placeholder, error: field.error)
        case .toggle(let value):
            block = .toggle(fieldID, action: change, value: value)
        case .picker(let options, let value, let segmented):
            block = .picker(fieldID, action: change, options: options, value: value, segmented: segmented)
        case .stepper(let value, let min, let max, let step):
            block = .stepper(fieldID, action: change, value: value, min: min, max: max, step: step)
        case .date(let value):
            block = .datePicker(fieldID, action: change, value: value)
        case .tags(let tags, let suggestions):
            block = .tagPicker(fieldID, action: change, tags: tags, suggestions: suggestions)
        case .role(let value, let roles):
            block = .rolePicker(fieldID, action: change, value: value, roles: roles)
        case .button(let title, let symbol, let style):
            block = .button(id: fieldID, title: title, symbol: symbol, action: names.id("press"), style: style)
        }
        if let enabled = field.enabled { block = block.enabled(enabled) }
        return block
    }

    private func row(_ field: SettingsField) -> Block {
        var labels: [Block] = [.text(field.label, id: names.id("label", field.key))]
        if let help = field.help { labels.append(.text(help, id: names.id("help", field.key), style: .caption)) }
        let labelColumn = Block.vstack(labels, id: names.id("text", field.key))
        let rowID = names.id("row", field.key)
        // A text area is wide: its label goes above it instead of beside it.
        if case .textArea = field.kind { return .vstack([labelColumn, control(field)], id: rowID) }
        return .hstack([labelColumn, .spacer(), control(field)], id: rowID)
    }

    public var block: Block {
        .scroll([
            .vstack(sections.map { group in
                var children: [Block] = []
                if let description = group.description { children.append(.text(description, id: names.id("description", group.id), style: .caption)) }
                children += group.fields.map(row)
                return .section(names.id("section", group.id), children, title: group.title, collapsible: group.collapsible, collapsed: group.collapsed)
            }, id: names.id("sections"))
        ], id: id, axis: .vertical)
    }

    /// Sends the form's events to `handlers`. Call once, when the view is set up.
    @MainActor
    public func route(on view: ViewState, _ handlers: SettingsFormHandlers) {
        let names = self.names
        view.on(names.id("change"), stale: .deliver) { event in   // text typed in quick succession must never be lost
            if let key = names.rest("field", of: event.block) { try await handlers.onChange?(key, event.value ?? .null) }
        }
        view.on(names.id("press")) { event in
            if let key = names.rest("field", of: event.block) { try await handlers.onButton?(key) }
        }
    }
}
