# The Vektor plugin SDK for Swift

Write a compiled plugin in Swift without hand-building `Content-Length` frames or whole view descriptions. The SDK does the
protocol, gives typed builders for every block, keeps your view's state and sends **patches**, and ships five
[layouts](sdk-layouts.md) (a board, a list with detail, a table with toolbar, a settings form, a card list). Everything it does
is plain protocol ([`reference.md`](reference.md)); the sources in `sdk/swift/Sources/VektorPlugin/` are commented and short enough
to read.

* **No dependencies** beyond Foundation. macOS 13 or later, Swift 6 (the Command Line Tools are enough; no Xcode needed).
* **Users install nothing.** You ship a compiled program, which **must be signed** (ad hoc is enough: `codesign -s -`, which
  `templates/swift/build.sh` does after the last change). See the reference's [Compiled programs and signing](reference.md#compiled-programs-and-signing).
* The SDK is versioned on its own: see the table in [`sdk/README.md`](../sdk/README.md).

## Start

Copy the template: `cp -R templates/swift ~/my-plugin`, change `id`, `name` and `publisher` in `plugin.json`, then `./build.sh`.
The template's `Package.swift` takes the SDK from this repository — by path while the folder is inside a clone, by URL and
version once it is copied elsewhere:

```swift
.package(url: "https://github.com/vektor-commander/vektor-plugins", from: "0.1.0")
.product(name: "VektorPlugin", package: "vektor-plugins")            // and "VektorPluginTestKit" for tests
```

The plugin lives in a library (`setup(_:)` registers everything it does) and a three-line program calls it, so a test can drive
it in memory:

```swift
import VektorPlugin

@MainActor @discardableResult
public func setup(_ plugin: Plugin) -> Plugin {
    plugin.command("hello") { target, _ in
        InvokeResult(message: "Hello! You chose \(target.items?.count ?? 0) item(s).")   // shown as a short notice
    }
    return plugin
}
// main.swift:   setup(Plugin()).run()
```

`run()` reads stdin and writes stdout. **stdout carries only messages**: use `plugin.log(…)` or `logToStderr` for your own lines. A
stray `print` does not break the stream: the SDK keeps a private copy of stdout for messages and points descriptor 1 at stderr,
the plugin's Log. The SDK answers `ping`, `$/cancel` and `shutdown` itself and exits within the grace period. Everything runs on the main actor.

## The plugin

| | |
|---|---|
| `plugin.command(name) { target, context in InvokeResult }` | a command of the manifest (`invoke`); throw a `PluginError` for an alert in plain words |
| `plugin.onStartup`, `onReady`, `onShutdown`, `onSettingsChanged`, `onWorkspaceChanged` | lifecycle. `onReady` runs right after `startup` is answered: send the first views there |
| `plugin.settings`, `plugin.workspace`, `plugin.dataFolder` | the latest values (defaults filled in), the active workspace, `$VEKTOR_PLUGIN_DATA` |
| `try await plugin.request(method, params)` | a request of your own, answered by id; `confirm`, `showDialog`, `getSettings`, `navigate` … are typed wrappers |
| `plugin.notify`, `log`, `toast`, `alert` | notifications |
| `plugin.onRequest(method)`, `onNotification(method)` | anything the SDK does not type |
| `plugin.view(id)` | the [view state](#views-and-patches) of a view |
| `plugin.sidebar(entry)`, `plugin.web(view)`, `plugin.storage(place)` | [sidebar items](#sidebar-items-and-workspaces), [web views](#web-views), [storage](#storage-and-sync) |

Values are `JSONValue` (an enum with literals: `["title": "Board", "count": 3]`). Errors are `PluginError` (your words, shown to
the user) or `VektorError` (Vektor refused something: `code`, `message`, `data`).

## Blocks

`Block` has a builder for every block of the reference; each gives exactly the JSON the reference documents (the tests check
them against `sdk/fixtures/blocks.json`, the same file the Node SDK's tests use). Containers take their children first; ids of
collections' items, inputs, sections, tabs, splits, nodes and web blocks are required and **must be stable**. Fields every block
may carry are modifiers: `.menu([…])`, `.tooltip(…)`, `.label(…)`, `.drag(…)`, `.drop(action:accepts:)`, `.enabled(_)`, and the
widths `.width(_)`, `.minWidth(_)`, `.maxWidth(_)`, `.grow()`.

```swift
Block.vstack([
    .textField("name", action: "add", placeholder: "Type a name"),
    .list("names", names.map { Block.row($0.id, title: $0.name, delete: "remove") }, placeholder: "Nobody yet."),
])
```

You never send a colour value, only a `Role` (`.accent`, `.positive`, `.warning`, `.danger`, `.neutral`, `.label1` … `.label8`).
`validateBlocks(_:)` reports, in plain words, what Vektor would refuse — `ViewState` runs it before every send. Like Vektor, it
trims required strings: an option's `value` or `title`, a menu item's `title` or `action`, a column's `id` or `title` that is
empty or only white space counts as missing, and Vektor refuses the whole description for it.

**Widths** are structural numbers in points, never a theme's, from 20 to 4000 (`BlockLimits.widths`): `.width(300)` asks for a
width (never wider than the row offers), `.maxWidth(600)` caps it, `.minWidth(240)` is honoured inside a horizontal `scroll` (which
shows the rest by scrolling; on a `grid`, `minWidth` is the tile minimum) and `.grow()` takes a share of the width the row leaves.
Vektor ignores a value outside that range and says so in the Log; `validateBlocks` reports it as a warning. Columns that fill the
pane and scroll once they no longer fit:

```swift
Block.scroll([
    Block.panel(todo, id: "col-todo", title: "To do").grow().minWidth(240),
    Block.panel(done, id: "col-done", title: "Done").grow().minWidth(240),
], axis: .horizontal, spacing: 12)
```

## Views and patches

```swift
let view = plugin.view("hello")
@MainActor func describe() throws {
    try view.show(ViewDescription(header: Header(title: "Hello"), root: tree()))
}
view.onOpen { _ in try describe() }
view.on("add") { event in names.append(Name(id: "n\(next)", name: event.text ?? "")); next += 1; try describe() }
```

* `view.show(_:)` keeps the description and its revision, and sends a **patch** (`view/patch`) when one says the change (computed
  by id and checked to rebuild the new tree exactly) and the whole description otherwise. It returns what it sent (`.patch`,
  `.update`, `.unchanged`). `update(_:)` always sends the whole; `patch(_:)` sends operations you built.
* `view.on(action, stale:) { event in … }` routes `view/event`s by the action string your blocks carried. An event made against
  an older revision: a **move** is dropped (`.ignoreMoves`, the default — "put it at index 3" no longer means what the user saw),
  anything else is delivered with `event.isStale`; `.ignore` and `.deliver` choose otherwise. `event.text`, `event.block`,
  `event.item`, `event.target`, `event.index`, `event.selected` … are the reference's event fields.
* `view.onOpen`, `onClose`, `view.isOpen`, `view.item` (the sidebar item the view was opened for), `view.invalidate()`.
* `view.onRefused { refusal in … }` (API 2): Vektor could not show a description or a patch (`view/refused`). `refusal.problem`
  says why in plain words, `refusal.kind` is `.description` or `.patch`, `refusal.revision` is what Vektor still shows. Events
  made against that revision are not stale (they keep carrying it until Vektor shows something newer). The next `show` sends the
  whole description; after a refused **patch** the SDK sends the kept description again by itself, numbered above anything sent,
  unless your handler sent something (`view.resendsAfterRefusal = false` turns that off). A refused whole description is not
  resent — it would be refused again — so fix what `problem` names and `show` again. `view.refusal` is the last one.

## Layouts

Each layout is a small type: set its properties, read `.block` to draw it, and call `route(on:_:)` **once** to send its events to
callbacks. The full description of each — what it shows and every callback — is in [`sdk-layouts.md`](sdk-layouts.md); the source is
`sdk/swift/Sources/VektorPlugin/Layouts/`, one short file each, meant to be copied.

```swift
import VektorPlugin

@MainActor
func boardPlugin(_ plugin: Plugin) {
    var columns = [
        BoardColumn(id: "todo", title: "To do", role: .label6, cards: [BoardCard(id: "c1", title: "Write the spec", tags: [BoardTag("docs")])]),
        BoardColumn(id: "done", title: "Done", role: .label4),
    ]
    var search = ""
    var next = 2
    let view = plugin.view("board")

    func layout() -> Board {
        var board = Board(columns: columns)
        board.search = search
        return board
    }
    func draw() throws { try view.show(ViewDescription(header: Header(title: "Roadmap"), root: layout().block)) }

    view.onOpen { _ in try draw() }
    layout().route(on: view, BoardHandlers(
        onAdd: { column in
            if let at = columns.firstIndex(where: { $0.id == column }) { columns[at].cards.append(BoardCard(id: "c\(next)", title: "New card")); next += 1 }
            try draw()
        },
        onRename: { card, title in
            for c in columns.indices { for k in columns[c].cards.indices where columns[c].cards[k].id == card { columns[c].cards[k].title = title } }
            try draw()
        },
        onRemove: { card in
            for c in columns.indices { columns[c].cards.removeAll { $0.id == card } }
            try draw()
        },
        onMove: { move in
            if Board.apply(move, to: &columns, isShown: layout().shows) { try draw() }
        },
        onSearch: { text in search = text; try draw() }))
}
```

The manifest needs `"api": 2`, a view `{"id": "board", "kind": "blocks"}` and a sidebar entry for it. The other layouts are used
the same way:

| Layout | Draw | Listen (`route(on: view, …)`) |
|---|---|---|
| `Board(columns:)` | `.search`, `.filterOptions`, `.filter`, `.toolbar`, `.columnMenu` | `BoardHandlers(onAdd:onOpen:onRename:onRemove:onMove:onColumnAction:onSearch:onFilter:)` |
| `ListDetail(items:)` | `.selected`, `.search`, `.detail = DetailPanel(title:).blocks` | `ListDetailHandlers(onSelect:onOpen:onSearch:onDetailAction:)` |
| `TableWithToolbar(columns:rows:)` | `.sorted`, `.selected`, `.search`, `.toolbar`, `.extra`; `TableRow.sorted(rows, columns:, by:)` | `TableHandlers(onSort:onSelect:onToolbar:onSearch:onOpen:onDelete:)` |
| `SettingsForm(sections:)` | `SettingsSection(id:title:fields:)`, `SettingsField(key:label:kind: .toggle(value: true))` | `SettingsFormHandlers(onChange:onButton:)` |
| `CardList(cards:)` | `CardItem(id:title:…)`, `.empty`; `try cards.block` (it throws for a button key with a dot) | `route(on: view, menuKeys: ["delete"], CardListHandlers(onOpen:onButton:onMenu:))` |

The layout you route must be one you draw with: the same `id` (and, for the board, `columnMenu`). A callback may be async and may
throw; the SDK logs a throw and goes on. It is given what the layout reads from the event (a card id, a column); the whole event
is `ViewEvent.current` while it runs, so `ViewEvent.current?.isStale` says whether the user acted on an older description (in
Node.js the event is the callbacks' last argument).

## Sidebar items and workspaces

```swift
plugin.sidebar("boards").provide { workspace in boards.map { SidebarItem(id: $0.id, title: $0.name) } }   // sent after startup and each workspace switch
plugin.sidebar("boards").onMenu("rename") { item, target, context in … }                                  // a `sidebarItem` menu's command
view.onOpen { opened in try show(opened.item) }                                                           // the item that opened the view
```

`plugin.onWorkspaceChanged` runs on a switch (also for an `"api": 1` plugin, from `settingsChanged`); `WorkspaceState` keeps one
value per workspace in the data folder, written atomically.

## Storage and sync

With the `storage` permission and a `place` setting, `plugin.storage(place:)` reads and writes inside the folder the user chose,
wherever it is (this Mac, S3, SFTP …). Paths are relative to the place.

```swift
let store = plugin.storage(plugin.place("board")!)                       // the handle from the latest startup / settingsChanged
let file = try await store.readJSON("board.json", as: BoardFile.self)     // StoredFile<BoardFile>? : value and version
switch try await store.writeIfUnchanged("board.json", board, baseVersion: file?.version) {
case .written(let version): …
case .conflict(let conflict):                                            // someone changed it meanwhile: mine, theirs, versions
    let merged = try threeWayMerge(base: baseCards, mine: board.cards, theirs: conflict.theirs!.value.cards)
    // merged.result.status is .unchanged, .merged or .conflicts; with conflicts YOU choose (the Board asks the user)
}
```

`threeWayMerge(base:mine:theirs:)` compares records by stable `id` and `updatedAt` and returns merged, conflicts (both changed
a field, both added, one deleted while the other changed) or unchanged. It reports conflicts and never resolves them.
**Do not write `records` while there are conflicts**: resolve each one first. Until then a conflicting record holds theirs'
version (mine's when they deleted it), so a write by mistake loses nothing on the place; mine's version is only in the conflict.
Listing is paged (`list` follows the pages, `listPage` gives one), large files go in parts, `delete` answers whether the item
went to the Trash. Versions are opaque: compare for equality, pass back as `ifVersion`.

`updatedAt` is optional and only says which side changed a record last; both SDKs read it the same way. A number is
milliseconds since 1970 (JavaScript's `Date.now()`); text is an ISO 8601 date-time — `2026-10-23T10:00:00Z`, with optional
fractional seconds and `Z` or an offset such as `+02:00` — read to the millisecond. Anything else (a date without a time,
seconds since 1970 written as text, another date format, an impossible date) counts as no timestamp.

## Web views

`plugin.web("sketch")` receives what the page posted with `vektor.post({ type: 'save', … })` and `.post(_:)` reaches your pages.
The page side is `sdk/web/vektor-bridge.js`; `sdk/web/vektor.css` is a starter stylesheet on the theme's CSS properties. When to
use a web view rather than blocks: [`sdk-layouts.md`](sdk-layouts.md#when-to-use-blocks-and-when-a-web-view).

## Testing

`VektorPluginTestKit` is an in-memory Vektor. The template's `hello-check` target plays `test/checks.json` (the same script as
`vektor-plugin test`) against the plugin without a build or a signature: `swift run hello-check`. `TestHost` also lets you drive
the plugin by hand — `startup`, `openView`, `viewEvent`, `refuse` (Vektor refusing what the plugin sent last: `view/refused`),
`waitFor`, `shutdown` — for any test runner. The Command Line Tools ship
neither XCTest nor Swift Testing, so the SDK's own tests are a plain executable: `swift run vektor-sdk-tests` in `sdk/swift`.

`vektor-plugin validate` and `vektor-plugin test` work on the built program like on any other.
