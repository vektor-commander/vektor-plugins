# Board: how it is built

Kanban boards for each workspace: columns, tasks and tags, kept locally or in a folder on one of the workspace's
connections. Written in Swift on the [Swift SDK](../../docs/sdk-swift.md) — a compiled program the user installs nothing for — and
the SDK's proof of completeness: storage places, sync, sidebar items, workspaces and block views.

What it shows:

| Feature | Where |
|---|---|
| Boards per workspace, listed under the sidebar entry; New, Rename and Delete in the entry's and the items' menus | `BoardPlugin.swift` (`setup`), `plugin.json` ▸ `contributes` |
| A per-workspace **place** setting: a local folder or on a connection, reached only through Vektor's storage service | `plugin.json` ▸ `settings`, `Place.swift` |
| A data model that merges record by record: stable ids, `updatedAt` on every record, order as ranks | `Model.swift`, `Rank.swift` |
| Saved on every change locally; for a connection marked unsynced until **Sync** | `LocalStore.swift`, `BoardController.swift` |
| A three-way sync against the last synced base that asks the user, with both versions, whenever both sides changed one thing | `Merge.swift`, `SyncEngine.swift` |
| One controller the views call (commands and queries), so the views draw and nothing else | `BoardController.swift`, `BoardQueries.swift` |
| The board, the list, one task, Board settings and the sync questions, built from blocks only (Swift SDK builders, no layout) | `BoardScreens.swift`, `BoardViewModel.swift` |
| Every redraw through the SDK's `ViewState.show`: a patch by id, in time linear in the number of cards, so a board of thousands stays usable | `BoardViewModel.swift` (`present`) |
| Tests on the SDK's test kit: two "copies" sharing a fake place, a plugin stopped between two writes, a place changed behind its back | `Sources/board-tests/` |

## Where the boards are kept

With no place chosen, a workspace's boards are in the plugin's own data folder. A place is chosen per workspace in the plugin's
settings: **Local** (a folder; every change is written there at once) or a folder on one of the workspace's connections (S3,
SFTP, SMB …; every change is saved locally at once and marked unsynced, and **Sync** sends and receives). The plugin never
sees an address or a password: Vektor reads and writes for it, through the connection the user already has.

In the place (and in the data folder) the boards are plain, readable JSON:

    index.json              the workspace's boards: id, name, rank, updatedAt
    boards/<board id>.json  one board: columns, tasks, tags and comments, each with an id, a rank and updatedAt

A path is made from a board's id, never from its name, so one board's changes can never reach another board's file. Colours are
the theme's colour roles (`label1` … `label8`, `neutral` …) by name, never a colour value.

## Sync

A sync compares three copies of every record — the local, the place's, and the base (what both last agreed on):

* a record only one side changed (added, changed, deleted) takes that side's version; both made the same change: taken;
* a record one side deleted and the other left as it was is deleted;
* a record both sides changed differently, or one deleted while the other changed it, is **asked about**, with both versions
  side by side: keep mine, keep theirs, or (for a task) keep both. Nothing is overwritten without an answer.

Comments are records of their own, so two people commenting on one task never conflict; a task deleted on one side while it was
commented on the other is asked about. Writes carry `ifVersion`: if the place changed meanwhile Vektor refuses, and the sync
starts again instead of overwriting. When nothing changed on either side the sync only lists the place: nothing is read or
written. Each write is whole (never half a file), board files come before the index that lists them, and a journal locally
lets the next sync finish what a quit or a lost connection interrupted.

## The views

All of it is blocks the Swift SDK builds (plugin API 2); Vektor draws them with the active theme, and colours are theme roles
(`label1` … `label8`, `neutral` …), never values.

| What the user sees | Blocks |
|---|---|
| Sidebar: the **Board** entry lists the workspace's boards, the one shown marked; New Board… on the entry's menu and in the empty state; Rename and Delete on an item | `sidebar/items` (`SidebarItem` with a symbol), the manifest's `sidebarEntry` and `sidebarItem` menus, `view` empty state with a `button` |
| Header: the board's name and **Add task**; beside the bar a switcher between the workspace's boards | the view header (`title`, `primary`), a `picker` |
| Bar: **All tasks** (all, open, done), **Tags** (several, with a check mark), search, **Sync** with progress and "Last synced …", board/list toggle, "…" | `picker`, a titled `menu`, `searchField`, `button` (`busy`, `enabled`) with a caption `text`, a segmented `picker`, an untitled `menu` |
| Columns side by side, filling the pane and scrolling sideways when narrower than 260 points; colour role, count, "+", "…" (rename, colour, move, delete asking what to do with the tasks) | a horizontal `scroll` of `panel`s with `grow` and `minWidth`, a `count` or `badge`, an icon `button`, a `menu` |
| Task card: done circle, title (renamed in place), description (Markdown), tags, comment count, drag handle | a `card` with `edit`, `delete`, `check`, in a `list` of the shared `cards` group with `move`; a `markdown`, `badge`s, a `symbol` and a `count`, an icon `button` for the circle |
| A task opened: title, done, column, tags, Markdown description with a preview, comments (author, time, text; add; delete your own) | `textField`, `checkbox`, `picker`, `tagPicker`, `textArea`, `markdown`, `text`, icon `button`s |
| List view: title, column, tags, done, comments, updated; sortable; several rows selected and deleted at once | `table` with `row`s, `selection: multiple`, `sort`, a `button` |
| Board settings: Columns (order, name, colour), Tags, General (name; the place, read-only, in words) | a segmented `picker` choosing what is drawn, `textField`, `rolePicker`, icon `button`s |
| Questions after a sync: each record with both versions side by side, the reason, the choices | a `section` per question with a `diff` (yours left, the place right), `text` and `button`s |
| Empty, loading and error states | `empty`, `spinner`, `banner`, `status`, a "Try Again" `button` |

**What goes over the wire.** The controller keeps an index per board, so drawing is one pass over the tasks. A change asks for a
redraw and several in a row are drawn once. The SDK's `ViewState.show` compares the redraw with the last one by id (in time
proportional to the number of blocks) and sends it as `view/patch`: a card dragged to another column is one `move` and two small
`replace`s for the counts (about 360 bytes, whatever the size of the board); the done circle, a rename or a new card is one
operation. Anything a patch cannot say (another screen) is sent as the whole description. Measured with 3,000 tasks (release
build, wall clock, in the test host): the whole description is 2.8 MB and takes about 0.9 s to build and send; one drag is three
operations in about 0.15 s (handling, redrawing, comparing and
sending). A refused patch is answered by the SDK with the whole description, and the next drop is not dropped as stale.

## Building and testing

From this folder (the Command Line Tools are enough):

    swift run board-tests          the plugin's tests, against the SDK's test kit
    ./build.sh                     bin/board, signed ad hoc
    vektor-plugin validate .
    vektor-plugin test . test/checks.json

The tests never use the network or your Vektor configuration: every place and data folder is a temporary folder.
