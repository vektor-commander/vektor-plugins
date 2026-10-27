# Vektor plugin reference (plugin API 2)

Everything a plugin author needs, from the kit alone: the protocol, the manifest, what a plugin can contribute and ask for, the
errors, versioning, how to test and publish. It describes what Vektor does, not what it might do one day. The step-by-step path
from an empty folder to a merged pull request is `CONTRIBUTING.md` (in the plugins repository); this is the reference you look things up in.

Contents: [Quick start](#quick-start) · [How a plugin runs](#how-a-plugin-runs) · [The wire](#the-wire) ·
[The manifest](#the-manifest) · [Settings](#settings) · [Contribution points](#contribution-points) ([Locations](#locations), [Event hooks](#event-hooks)) ·
[Messages from Vektor](#messages-from-vektor) · [Messages from the plugin: services](#messages-from-the-plugin-services) ·
[View descriptions](#view-descriptions) · [Block views](#block-views-api-2) · [Dialogs](#dialogs) · [Permissions](#permissions) · [Errors](#errors-and-limits) ·
[API versioning](#api-versioning) · [Writing the program](#writing-the-program) ·
[Compiled programs and signing](#compiled-programs-and-signing) · [Tools](#tools) · [Publishing](#publishing)

## Quick start

1. Get the tools ([Tools](#tools)) and copy a template: `cp -R templates/zsh ~/my-plugin` (or `templates/node`, `templates/swift`).
   Change `id`, `name`, `publisher` in `plugin.json`.
2. `vektor-plugin validate ~/my-plugin` — the manifest check Vektor itself makes.
3. `vektor-plugin test ~/my-plugin ~/my-plugin/test/checks.json` — a simulated Vektor.
4. In Vektor: Settings ▸ Plugins ▸ **Developer mode** on ▸ **Load Plugin from Folder…**. Changing any file in the plugin's
   folder — `plugin.json`, the program, a helper or SDK copied into a subfolder, a page's files — reloads the plugin at once
   (menus, sidebar and views follow); an invalid manifest leaves it stopped with the reason in its **Log**; a change that adds
   permissions asks again. Not counted: `.git/`, `.build/`, `node_modules/.cache/`, `.DS_Store` and editors' temporary files
   (`*.swp`, `*.swo`, `*.swx`, `*~`, `.#*`, `#*#`, `4913`, `*___jb_tmp___`, `*___jb_old___`), and what the plugin itself writes
   into its folder while it starts. A plugin that keeps changing its own folder right after each start is reloaded three
   times, then only `plugin.json` and the program reload it (the Log says so) — keep data in `$VEKTOR_PLUGIN_DATA`.
5. Publish: `CONTRIBUTING.md` (in the plugins repository).

The complete examples are in `samples/`: `todo` (views, settings, state; `todo-node` is the same plugin in Node.js),
`cloudflare-tunnel` (processes, dialogs, secrets, a sidebar badge), `folder-drive` (a location) and `sketch` (a web view).
Each has a README that says what it demonstrates.

## How a plugin runs

A plugin is a **folder** holding `plugin.json` and a **program** (a script — zsh, or Node.js the user has installed — or a compiled and signed program). Vektor starts
the program only when something needs it — a menu command, an opened view, a Settings tab with status lines — never to draw a
menu, and never before the user has **approved its permissions**. The program talks to Vektor over its **stdin and stdout**.

* **One process per plugin**, in its own process group. Everything it starts through the Processes service is tracked.
* **Minimal environment**: `PATH` (fixed: `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` — a program installed
  by nvm, fnm or Volta is not on it), `HOME`, `TMPDIR` (inside the session folder), `LANG`, and
  `VEKTOR_PLUGIN_ID`, `VEKTOR_PLUGIN_DATA`, `VEKTOR_PLUGIN_SESSION`, `VEKTOR_PLUGIN_API`. No Vektor secrets, nothing from other
  plugins.
* **Data**: `$VEKTOR_PLUGIN_DATA` is yours and survives updates. The plugin's own folder is Vektor's copy and is replaced on
  update — never write there.
* **Cleanup**: every plugin cleans up after itself. Vektor sends `shutdown { reason }` (`quit`, `disable`, `uninstall`,
  `update`, `crashRestart`); you answer, stop what you started and exit within the grace period (about 2 s; about 3 s for all
  plugins together at quit). After that Vektor ends the process, its group and everything it started. Nothing outlives Vektor.
* **A crash** restarts the plugin, up to a limit; then it is turned off and says why.

## The wire

Messages are JSON objects framed like a language server's:

```
Content-Length: 44\r\n
\r\n
{"api":1,"id":1,"method":"ping","params":{}}
```

* `Content-Length` is the **byte** count of the body. A header larger than 1 KB, or a body larger than 16 MB, ends the plugin.
* Every message carries `"api": <number>`. Vektor writes the version your manifest declares (an `"api": 1` plugin keeps
  reading `1`); you may write `1` or `2`.
* A **request** has `id`, `method` and `params`; it must be answered: `{"api":1,"id":N,"result":{…}}` or
  `{"api":1,"id":N,"error":{"message":"plain words"}}`. A **notification** has no `id` and no answer.
* Either side may send either kind. Ids belong to the sender; start yours at 1000 or so.
* Unknown fields are ignored; unknown methods from Vektor get `error`; unknown methods from the plugin are refused with
  “Vektor does not offer …”.
* stdout is **only** messages. Diagnostics go to stderr (shown in the plugin's Log) or to the `log` message.

## The manifest

`plugin.json`, UTF-8, at most 256 KB. Unknown top-level fields are ignored.

| Field | Type | Meaning |
|---|---|---|
| `id` | text, required | Reverse domain, lowercase letters, digits and inner hyphens: `com.example.thing` (at most 100 characters). Never changes. |
| `name`, `publisher`, `summary`, `description` | text, required | Shown in Settings and Get Plugins. |
| `version` | `1.2.3`, required | Semantic version. |
| `api` | whole number ≥ 1, required | The plugin API it was written for (`1`). |
| `minVektor` | `1.2.3`, required | The oldest Vektor it runs on. |
| `executable` | path, required | Inside the folder; never absolute, never `..`. Symlinks that leave the folder are refused. |
| `arguments` | list of text | Passed to the program. |
| `permissions` | list of names | See [Permissions](#permissions). Unknown names are refused. |
| `settings` | object | `groups` and `items`; see [Settings](#settings). A `secret` setting needs the `secrets` permission. |
| `contributes` | object | `commands`, `menus`, `views`, `sidebar`, `settingsTabs`, `decorations`, `infoRows`, `footer`, `locations`, `hooks`; see [Contribution points](#contribution-points). |
| `icon`, `readme` | path | Inside the folder. SVG or PNG; Markdown. |
| `homepage`, `repository`, `license` | text | Shown on the plugin's page. |

Vektor refuses a manifest with a **command no menu names**, a **view no sidebar entry or Settings tab names**, a menu item
naming an unknown command, or a sidebar-entry menu without a sidebar entry. `vektor-plugin validate` tells you in the same words.

## Settings

Vektor draws a plugin's settings page from `settings` and stores the values: application-wide in the plugins configuration,
per-workspace values with the workspace, **secrets in the keychain**. The plugin gets them in `startup` and `settingsChanged`,
or asks with `settings/get`. A secret is never written to a file and never appears in the plugin's Log.

```json
"settings": {
  "groups": [ {"id": "defaults", "title": "Defaults", "description": "…", "collapsible": true, "collapsed": true} ],
  "items": [
    {"key": "prefix", "kind": "text", "label": "Name prefix", "group": "defaults", "default": "vektor-",
     "help": "…", "pattern": "^[A-Za-z0-9._-]*$", "placeholder": "…", "multiline": false, "required": false, "scope": "application"}
  ]
}
```

Every item has `key` (letters, digits, `.`, `-`, `_`), `kind`, `label`, optional `help`, `default`, `required`, `group`,
`scope` (`application`, or `workspace` for a value remembered per workspace), and an optional `banner`
(`{"text", "linkTitle", "link"}`, an info line under the setting). The kinds:

| `kind` | Extra fields | Value |
|---|---|---|
| `text` | `placeholder`, `pattern` (regular expression), `multiline` | text |
| `number` | `min`, `max`, `unit`, `integer` | number |
| `toggle` | | true / false |
| `choice` | `options: [{"value","title"}]`, `style`: `picker` or `radio` | the option's `value` |
| `path` | `pathKind`: `folder` or `file` | a path |
| `secret` | `placeholder` | text, never stored by the plugin |
| `list` | `itemKind`: `text` or `number` | a list |
| `place` (API 2) | — (no `default`: the user chooses) | a handle: `{"place", "label", "remote"}`, or `null` when not chosen |

**`place`** is a folder the user picks for your data: **This Mac** (a folder chooser) or a folder on **one of the workspace's
connections** (S3, SFTP, SSH, SMB), browsed with Vektor's own folder browser. It needs `"api": 2` and the `storage`
permission (an `"api": 1` manifest with a `place` setting or the `storage` permission is refused, in plain words). You never
receive a path, a connection's address or a password: you receive an opaque handle such as
`{"place": "pl-k2v7…", "label": "neon (SFTP) ▸ /home/me/boards", "remote": true}` and use it with the
[storage service](#storage-service-api-2). Show `label` to your user if you like; pass `place` back unchanged. A handle is valid
for this run of Vektor, in the workspace it was sent for, while the setting holds that folder: **do not store it** — use the
value from the latest `startup`, `settingsChanged` or `settings/get`. After a workspace switch you receive that workspace's value
(and any older handle is refused). A place cannot be a dialog field.

A value that fails its rule (pattern, range) is never stored. A plugin may add a **status line** to a setting at any time with
`settings/status` (“cloudflared found”, tone `positive`).

Settings with `"scope": "workspace"` are edited in Vektor's **Settings ▸ Workspace ▸ Plugins**, for the workspace the user
chooses there (any of them, not only the active one); **Settings ▸ Application ▸ Plugins** shows your application settings and a
line that leads to the workspace page. A `place` on the workspace page offers the folders of **that** workspace's connections. You
only ever receive the active workspace's values: a change made to another workspace is not sent, and reaches you in
`settingsChanged` when the user switches to it. To send your user to your settings from your own view, ask `settings/open`
(API 2, below).

## Contribution points

### Commands and menus

```json
"contributes": {
  "commands": [ {"id": "publish", "title": "Publish…", "symbol": "icloud.and.arrow.up", "timeout": 120,
                 "applies": {"to": "files|folders|both", "minCount": 1, "maxCount": 1, "extensions": ["md"], "locations": ["local"]}} ],
  "menus": [ {"target": "fileItem", "items": ["publish"]},
             {"target": "folderBackground", "title": "Tools", "symbol": "wrench", "items": ["a", "b"]} ]
}
```

A command is a name Vektor calls with `invoke`. A menu places commands: **items directly** in the menu, or — with `title` —
**one entry with a submenu**. `applies` decides when an item is shown (what is selected, how many, which extensions, local or
remote). Targets:

| `target` | Menu |
|---|---|
| `fileItem` | the file or folder context menu |
| `folderBackground` | the context menu of the empty part of a folder |
| `sidebarFavorites`, `sidebarLocations`, `sidebarConnections`, `sidebarWebsites` | the sidebar sections' menus |
| `sidebarEntry` | the menu of the plugin's own sidebar entries (its items, then **Plugin Settings…**) |
| `sidebarItem` | API 2: the menu of the items the plugin lists under its sidebar entry (`target` has `entry` and `item`) |
| `previewMore` | Preview ▸ More |
| `terminal` | the terminal's menu (with a selection) |

The user can hide a plugin from any menu in its Permissions tab. Opening a menu **never starts a plugin**: the manifest is enough.

### Sidebar entries, views and Settings tabs

```json
"views":    [ {"id": "tunnels", "title": "Tunnels", "kind": "cardList"} ],
"sidebar":  [ {"id": "tunnels", "title": "Tunnels", "symbol": "point.3.connected.trianglepath.dotted", "view": "tunnels"} ],
"settingsTabs": [ {"id": "tunnels", "title": "Tunnels", "symbol": "…", "view": "tunnels"} ]
```

A **view** is described by the plugin as data (see [View descriptions](#view-descriptions)); its `kind` is `cardList`, `list`,
`form`, `detail`, `toolbar` or — with `"api": 2` — `blocks` (see [Block views](#block-views-api-2)) or `web` (a page of your
own files, see [Web views](#web-views-api-2)), declared here so what it may contain is known before it runs. A sidebar entry appears in the
sidebar's **Plugins** section and opens its view in the active pane; a Settings tab shows the same view inside the plugin's
page. `symbol` is an SF Symbol name.

### File decorations, info rows, footer item and drop targets

```json
"permissions": ["decorate"],
"contributes": {
  "decorations": {"locations": ["local"], "to": "both"},
  "infoRows":    {"locations": ["local", "sftp"]},
  "footer":      {"locations": ["local"], "command": "status", "symbol": "arrow.triangle.branch"},
  "sidebar": [ {"id": "tunnels", "title": "Tunnels", "view": "tunnels",
                "drop": {"command": "publish", "accepts": {"to": "folders", "maxCount": 1, "locations": ["local", "remote"]}}} ]
}
```

* **Decorations** — one small badge per file from you, beside the name in the list and at a tile's corner in the grid (never in
  place of the icon). Vektor asks only about rows on screen, in batches (`decorations/get`), one request at a time, and caches each
  answer per file version (path, size, modification date). Not answering is allowed: your badges simply do not appear. At most two
  plugins' badges show on a row; the rest are listed in Get Info. `locations` are `local`, `s3`, `sftp`, `docker`, `plugin` (default
  `local`) — you are never asked about a place you did not list. Needs `decorate`; the user can turn it off for you.
* **Info rows** — rows in Get Info and Preview's Info view under your name (`info/get`, a 3 s timeout). Needs `decorate`.
* **Footer item** — one short text beside a pane's item count (`footer/get` per folder); a click runs `command` on the folder or
  opens `view` in that pane. At most two plugins' items per footer; the user can hide yours.
* **Drop targets** — `drop` on a sidebar entry or a view: files and folders dropped there invoke `command`. Whether the drop is
  taken is decided **from `accepts` alone** while the user drags (`to`, `minCount`, `maxCount`, `extensions`, `locations`); you are
  not asked until it is released.

An item is `{"path", "name", "isFolder", "size"?, "modified"?}` when it is on this Mac and `{"location", "remote": true, "name",
"isFolder", …}` when it is in an S3 bucket, on an SFTP server or in a container — **never** a path or a `file://` URL for those.

| Method | Kind | `params` | You answer |
|---|---|---|---|
| `decorations/get` | request | `items`: up to 64, each with an `id` | `{"decorations": [{"id", "symbol", "tone"?, "label"}]}` — one per `id` (the first counts); leave an item out for no badge |
| `info/get` | request | `item` | `{"rows": [{"label", "value"}]}` (≤ 12) |
| `footer/get` | request | `folder` (an item), `location` | `{"text", "symbol"?, "label"?}` (≤ 40 characters), or `{}` for nothing |
| `invoke` (a drop) | request | `command`, `target`: `{"source": "drop", "surface": "sidebarEntry"\|"view", "entry"\|"view", "items"}` | as any `invoke` |
| `invoke` (footer) | request | `command`, `target`: `{"source": "footer", "folder"}` | as any `invoke` |

`symbol` is one of `dot check modified added removed untracked conflict warning error ignored synced uploading downloading cloud
locked star clock info` (each a different shape); `tone` is `positive`, `neutral` (default), `warning` or `error`; `label` (≤ 60
characters) is what VoiceOver and the tooltip say. Send the notification `decorations/changed` (`{"paths": [...]}` or `{}` for
everything) when your answers went stale, and `footer/changed` (`{}`) when your footer text did.

### Locations

A **location** is a kind of connection your plugin serves: the user adds one in Vektor's connections with the fields you
declare, opens it in a pane, and Vektor lists, reads and writes through your plugin — its pane, copy, move, rename, delete and
preview work as for S3 or SFTP. Needs the `location` permission (a `secret` field also `secrets`). The complete example is
`samples/folder-drive` (a folder on this Mac served as a location, with an access code).

```json
"permissions": ["location", "secrets"],
"contributes": {
  "locations": [ {"id": "drive", "title": "Folder Drive", "scheme": "folder-drive", "symbol": "externaldrive",
     "fields": [ {"key": "root", "kind": "text", "label": "Folder", "required": true},
                 {"key": "accessCode", "kind": "secret", "label": "Access code"} ],
     "summaryField": "root", "timeoutSeconds": 20, "pageSize": 200, "changeFeed": false,
     "capabilities": {"write": true, "rename": true, "move": true, "delete": true, "createFolder": true, "hiddenFiles": "dotPrefix"}} ]
}
```

* At most 8 locations. `scheme`: 2–32 lower-case letters, digits and `-`, starting with a letter and not ending with `-`; not
  one of Vektor's own (`file`, `s3`, `sftp`, `ssh`, `smb`, `docker`, `http`, `https`, `archive`, `plugin`, `vektor`, …) nor
  `x-apple…`; two locations of one manifest never share one, and when two plugins declare the same scheme the first in the
  user's order serves it (the other's Log says so). `symbol` defaults to `externaldrive.connected.to.line.below`.
* `fields`: at most 16, of the kinds `text`, `number`, `toggle`, `choice`, `secret` (no `scope`, keys unique, at most one
  `secret`). `summaryField` names a non-secret field shown beside the connection's name.
* `pageSize` 1–1000 (default 500), `timeoutSeconds` 1–300 (default 30) for each request, `changeFeed` (default `false`).
* `capabilities` are all `false` unless given (a read-only location): `write`, `rename`, `move`, `delete`, `trash` (needs
  `delete`), `createFolder`, `share`, `convert`, `diskSpace`; plus `hiddenFiles` (`dotPrefix`, the default, or `none`) and
  `thumbnailsMaxMB` (default 20, at most 50). An unknown key refuses the manifest.

Vektor's requests all carry `connection: {id}`; a place is given as `location` (Vektor's address of it,
`<scheme>://<connection id>/<path>`) and `remotePath` (absolute, `/`-separated, no trailing `/` but for the root) — **never**
`path`. Files Vektor hands you are local paths in `file`.

| Method | Kind | `params` | You answer |
|---|---|---|---|
| `location/connect` | request | `connection: {id, type (the location's id), values (the non-secret fields), secret?}` — the only message that carries the secret | `{}` |
| `location/disconnect` | request | `connection` (Close Connection; not awaited past 3 s) | `{}` |
| `location/list` | request | `connection`, `location`, `remotePath`, `pageSize`, `cursor`? | `{"items": [{"name", "kind": "file"\|"folder", "size"?, "modified"?, "created"?, "hidden"?}], "cursor"?}` |
| `location/read` | request | `connection`, `location`, `remotePath`, `file` — write the item's bytes to `file` | `{"size"?}` |
| `location/write` | request | `connection`, `location`, `remotePath`, `file`, `size` — store the bytes of `file` at `remotePath` | `{}` |
| `location/createFolder` | request | `connection`, `location`, `remotePath` — fail when the name is taken | `{}` |
| `location/rename` | request | `connection`, `location`, `remotePath`, `newName` — fail when the name is taken | `{}` |
| `location/move` | request | `connection`, `location`, `remotePath`, `destinationPath` (within the connection) — fail when it exists | `{}` |
| `location/delete` | request | `connection`, `location`, `remotePath` — recursive; Vektor lists the folder afterwards to check | `{}` |
| `location/watch` | notification | `connection: {id}`, `remotePaths` — the folders shown now (only for a `changeFeed` location) | — |

* **Listing**: `modified`/`created` are seconds since 1970 or ISO 8601; a folder's `size` is ignored. A non-empty `cursor` (at
  most 4096 bytes) means another page follows — pass it back; repeating a cursor, or an answer without `items`, is a protocol
  error. Names that are empty, `.`/`..`, contain `/` or NUL, or are longer than 255 bytes, unknown kinds and repeated names
  are dropped; items past `pageSize` are cut; Vektor stops at 100,000 entries in one folder.
* **Reading**: after you answer, `file` must be a regular file (not a link) of `size` bytes if you gave one, or the read fails
  as incomplete. **Writing**: Vektor writes to a temporary name and renames it into place.
* A request that times out, or your plugin ending, marks the connection lost; the pane offers Reconnect. An `error.message` is
  shown to the user (clipped to 200 characters). Vektor sends `$/cancel` for a request the user no longer waits for.
* **`location/changed`** (a notification from you, only for a `changeFeed` location of yours): `{"connection": "<id>",
  "remotePaths": [...]}` — `connection` is the id as a **string** here — and those folders list again (without `remotePaths`,
  every folder of the connection shown).

### Event hooks

With the `events` permission a plugin can be **told** about things the user does (it never acts on them in Vektor's place):

```json
"permissions": ["events"],
"contributes": { "hooks": { "events": ["folderEntered", "filesChanged", "transferFinished"],
                            "watch": { "settings": ["inbox"], "dataFolder": false } } }
```

`events` (not empty) lists the hooks: `folderEntered`, `filesChanged`, `transferFinished`, `conversionFinished`,
`actionFinished`, `workspaceChanged`. Each is **off** until the user turns it on in the plugin's Permissions ▸ Events. `watch`
names up to 8 `path` settings whose folders `filesChanged` watches (only a value the user stored, never a default) and,
optionally, the data folder. Vektor sends the notification `events` — `{"events": [{"hook", …}]}`, never awaited:

| Hook | Fields |
|---|---|
| `folderEntered` | `pane`, `folder` (an item) |
| `filesChanged` | `folder`, `changes`: `[{path, name, change: created\|changed\|removed}]` |
| `transferFinished` | `operation`, `destination`, `succeeded`, `failed`, `skipped`, `cancelled`, `items` (at most 20) |
| `conversionFinished` | `conversion: {id, title}`, `destination`, `converted`, `failed`, `cancelled`, `outputs` (at most 20) |
| `actionFinished` | `action: {id, name}`, `outcome` |
| `workspaceChanged` | `workspace: {id, name}` |

Events are gathered for a quarter of a second and sent at most 4 times a second; more than 100 changes in one folder, or 50
other events in one batch, arrive as a summary `{"hook", "summary": true, "count", "reason": "many"|"behind", "folder"?}` —
and so does everything while more than 64 KB you have not read is waiting. Items are `{path, …}` on this Mac and `{location,
"remote": true, …}` elsewhere, as everywhere.

## Messages from Vektor

| Method | Kind | `params` | You answer |
|---|---|---|---|
| `startup` | request | `vektorVersion`, `pluginID`, `previousSessionEndedUncleanly`, `sessionTemporaryFolder`, `dataFolder`, `settings`, `workspace` (`{id, name}` or null) | `{}` |
| `shutdown` | request | `reason` | `{}`, then exit |
| `invoke` | request | `command`, `target` | `{}` or `{"message": "shown as a short notice"}`; an `error` is shown as an alert |
| `settingsChanged` | notification | `settings`, `workspace` — also after a workspace switch, to a plugin with a per-workspace or `place` setting | — |
| `view/opened`, `view/closed` | notification | `view`, `item`? (API 2: the sidebar item that opened it) | — (describe the view on `opened`) |
| `view/event` | notification | `view`, `action`, `card`?, `value`?, `field`?, `before`?, `index`?, `group`?, `revision`?; block views: `block`?, `item`?, `from`?, `target`?, `files`?, `column`?, `ascending`?, `selected`? | — (describe the view again) |
| `view/refused` | notification | API 2: `view`, `kind` (`description` or `patch`), `revision` (the revision Vektor still shows, or `null`), `refusedRevision`? (the one you sent), `problem` (plain words) — Vektor could not show what you sent ([Patches](#patches)) | — (send the whole description again) |
| `web/message` | notification | API 2: `view`, `block`? (a `web` block's id), `message` — what one of your [web pages](#web-views-api-2) posted with `vektor.post` | — |
| `workspace/changed` | notification | `id`, `name` — API 2: the active workspace changed (sent to every running `"api": 2` plugin; an `"api": 1` plugin is never sent it and learns of a switch from `settingsChanged`, if it has a per-workspace setting) | — |
| `process/output` | notification | `processID`, `stream` (`stdout`/`stderr`), `text` (one line) | — |
| `process/exited` | notification | `processID`, `status` | — |
| `ping` | request | `{}` | `{}` |
| `$/cancel` | notification | `{"id": <request id>}` | — (stop that work) |

`$/cancel` goes one way only: Vektor cancels its own requests to you. A `$/cancel` you send is ignored (sent as a request it is
answered "Vektor does not offer …"); you cannot cancel a request you made of Vektor — wait for its answer.

```json
{"api":1,"id":1,"method":"startup","params":{"vektorVersion":"1.0.0","pluginID":"com.example.hello","previousSessionEndedUncleanly":false,
 "sessionTemporaryFolder":"/…/session","dataFolder":"/…/data","settings":{"greeting":"Hello"},"workspace":{"id":"…","name":"Default"}}}
{"api":1,"id":2,"method":"invoke","params":{"command":"hello","target":{"menu":"fileItem","items":[{"path":"/Users/me/a.txt","name":"a.txt","isFolder":false}]}}}
```

`target` always has `menu`; it may also have `items` (`[{path, name, isFolder}]` — paths, never file contents), `folder`,
`connection` (`{id, kind}`, never a secret), `website` (`{url, name}`), `text` (a terminal selection), `entry` (the sidebar entry
a menu belongs to) and `item` (API 2: the sidebar item a `sidebarItem` menu belongs to). In a menu's `target`, **`folder` is a
path string** (the pane's folder for `fileItem` and `folderBackground`; for a folder in an S3 bucket, on a server or in a
container it is only the path part of its address, without the connection). The footer's `invoke` is different: its `folder`
is an item object (see the table above).

`previousSessionEndedUncleanly: true` means Vektor was killed last time: Vektor already ended what was recorded; clean up what
only you know about (a remote resource you created). A `view/event`'s `revision` is the revision of the description the user was
looking at — compare it with yours to ignore an event made against a list that has since changed.

## Messages from the plugin: services

Each service is checked against what the user approved. A refusal comes back as an `error` in plain words.

| Method | Kind | `params` → result | Needs |
|---|---|---|---|
| `log` | notification | `level`?, `message` → the plugin's Log. `level` is any word (default `info`): `info` is written as the message alone, any other word as `<level>: <message>` | — |
| `toast` | notification | `message` → a short notice | — |
| `alert` | notification | `title`, `message` → an alert | — |
| `confirm` | request | `title`, `message`, `confirmTitle` → `{"confirmed": bool}` | — |
| `clipboard/writeText` | notification | `text` (≤ 1 MB) | — |
| `settings/get` | request | → `{"settings", "workspace"}` | — |
| `settings/status` | notification | `key`, `text`, `tone` (`positive`, `neutral`, `warning`, `error`), `detail`? — empty `text` clears | — |
| `settings/open` | request | API 2: `scope`? (`workspace` or `application`; without it, `workspace` when you have workspace settings) → `{}`: opens Vektor's Settings on your settings — the workspace page shows the **active** workspace. Changes no value; refused when you have no settings in that scope | — |
| `dialog/show` | request | a [dialog](#dialogs) → `{"result": "submit"\|"cancel", "values": {…}}` (`values` is `{}` on cancel; Vektor before this answer sent none) | — |
| `view/update` | notification | `view`, `description` — the whole description | — |
| `view/patch` | notification | API 2: `view`, `revision`?, `ops` — a change to a block view by id ([Patches](#patches)) | — |
| `sidebar/items` | notification | API 2: `entry`, `items` (`[{id, title, symbol?, badge?}]`, in your order; `[]` clears) | — |
| `sidebar/badge` | notification | `entry`, `count`? or `text`?, `tone`?, `symbol`?, `label`? — neither a count above zero nor a text clears it | — |
| `web/post` | notification | API 2: `view`, `block`?, `message` (any JSON value, ≤ 1 MB) → delivered to **your** pages showing that view (and that block) | — |
| `openURL` | request | `url` (http or https; opened in the default browser) | `openURLs` |
| `navigate` | request | `path`, `placement`? (`newTab`, `otherPane`) | — |
| `reveal` | request | `path` | — |
| `process/start` | request | `executable` (full path), `arguments`?, `environment`?, `workingDirectory`? → `{"processID"}` | `processes` |
| `process/stop` | request | `processID` | — |
| `secrets/read` | request | `key` → `{"value"}` | `secrets` |
| `secrets/write` | request | `key`, `value` (≤ 16 KB) | `secrets` |
| `secrets/delete` | request | `key` | `secrets` |
| `storage/status` (API 2) | request | `place` → `{"state", "label", "remote", "writes", "conditional"}` | `storage` |
| `storage/list` (API 2) | request | `place`, `path`?, `cursor`?, `limit`? → `{"entries": [{"name", "isFolder", "size"?, "modified"?, "version"?}], "next"?}` | `storage` |
| `storage/read` (API 2) | request | `place`, `path`, `offset`?, `length`?, `encoding`?, `ifVersion`? → `{"content", "encoding", "version", "size", "offset", "eof"}` | `storage` |
| `storage/write` (API 2) | request | `place`, `path`, `content`, `encoding`?, `ifVersion`?, `upload`?, `more`? → `{"version"}` (or `{"upload"}` while `more`) | `storage` |
| `storage/delete` (API 2) | request | `place`, `path`, `ifVersion`? → `{"trashed"}` | `storage` |
| `storage/createFolder` (API 2) | request | `place`, `path` → `{}` | `storage` |

* **Processes service.** `process/start` runs a program for you in its own group, tracked per plugin; its output arrives as
  `process/output` lines and its end as `process/exited`. Vektor ends every one when the plugin stops. The program is checked
  first (see [Compiled programs](#compiled-programs-and-signing)); `DYLD_*` and `VEKTOR_*` environment values are dropped.
* **Secrets.** Stored in the keychain under the plugin's id. A value you read is removed from the Log automatically.
* `navigate` and `reveal` change what the user's pane shows; they are refused for a path that does not exist.

### Storage service (API 2)

Needs `"api": 2` and the `storage` permission. Reads and writes **only inside the folder the user chose** in a
[`place` setting](#settings). Vektor does the work through its
own connections — the same sign-in, the same session, the same **Close Connection** — so your plugin needs no S3 or SFTP code
and never asks for a password.

* **Paths are relative to the place**: `"board.json"`, `"cards/42.json"`. Refused: a path starting with `/` or `~`, empty
  names (`a//b`, a trailing `/`), `.` and `..`, control characters, `\` and look-alike slashes (`∕`, `⁄`, `／`…), names that read
  as `..` after Unicode normalisation, names starting with `.vektor-` (Vektor's own temporary files), the Trash's folders
  `.Trash` and `.Trashes`, more than 32 levels, a name over 255 bytes. None of these is ever listed. A symbolic link (on this
  Mac or on a server) whose target is outside the place is refused; links are never written through, and deleting one deletes
  the link, never its target. Folders are not created for you: `storage/createFolder` first.
* **Content** is UTF-8 text (`"encoding": "text"`, the default) or base64 (`"encoding": "base64"`), at most **512 KB of bytes
  per message**. Larger files (up to **32 MB**) go in parts: a read takes `offset` and `length` and answers `eof`; a write
  with `"more": true` answers `{"upload": "up-…"}` and nothing is written yet — send the following parts with that `upload`,
  the last one without `more`. Only the last part writes, all at once. A part that splits a UTF-8 character is answered in base64.
* **Versions.** Every file listed, read or written has a `version`: an opaque string. Compare versions for equality only and
  pass one back as `ifVersion`. It changes whenever the file does.
* **`ifVersion`.** On `storage/write` and `storage/delete`: a version means "only if the file is still this version"; `null`
  means "only if nothing is there" (write only). Otherwise Vektor refuses with `code: "changed"` and
  `data.currentVersion` (absent when the file is gone): **the file was changed since you read it — read it again, merge or ask
  your user.** On `storage/read`, `ifVersion` refuses a read of a newer version (useful between parts). `null` is accepted only
  by `storage/write`; on a read or a delete it is refused with `badRequest`. A version that is not one Vektor could have given —
  not a string, longer than 200 characters, not starting with `v1.`, or with characters other than ASCII letters, digits, `.`
  and `-` — is refused with `badRequest` (a well-formed version that is simply old answers `changed`). `ifVersion` on
  `storage/list`, `storage/status` and `storage/createFolder` is not read.
* **Reading in parts.** `offset` defaults to 0 and `length` to 524,288 bytes (512 KB), which is also the most one read
  answers; a `length` that is not a whole number from 1 to 524,288 is refused with `badRequest`.
* **Writes are all-or-nothing**: the bytes go to a temporary file beside the target and replace it in one step, so a reader
  never sees half a file.
* **`storage/status`** answers `state`: `available`, `offline` (closed by the user, lost, or not reachable — Vektor never
  reconnects for you), `needsSignIn` (only the user can sign in, in Vektor), or `missing` (the connection is not one of this
  workspace's, or the folder is gone); and what the place promises: `writes` (`atomic`) and `conditional` (`atomic` or
  `checked`, below). For a place Vektor cannot reach (`missing`, `offline`, `needsSignIn`) the answer may hold only `state` and
`label`, or only `state`. Other calls on such a place are refused with the same words and `code`.
* **Listing in pages.** `storage/list` answers at most `limit` entries (default **1000**, at most **5000**) and, when there are
  more, `next`: an opaque cursor. Pass it back unchanged as `cursor` — with the same `place` and `path` — to get the following
  page; the last page has no `next`. Keep asking while `next` is present: **a page can hold fewer than `limit`** (and on S3
  never more than 1000, the service's own page), even none, when names Vektor hides were in the way. A folder of any size can
  be listed this way. The order is the same on every page of one listing (sorted by name; on S3, by key), and a listing
  is a snapshot of the folder when it began: an entry is never given twice or skipped, a file added meanwhile is not in it, one
  removed meanwhile is left out (on S3 the service decides what a changing bucket shows between pages). Start again from the first page (no `cursor`) to see the folder as it is now.
  A cursor is Vektor's own record, not a path: it stays valid for ten minutes, you may repeat a request with the same cursor,
  and the oldest cursors of a listing (and the oldest of your unfinished listings) expire. A cursor you made up, one that is
  stale, or one from another place, folder or plugin is refused with `code: "badCursor"` and words saying which; it never lists
  anything else. Don't store a cursor: it ends with your plugin.
* **Deletes** answer `{"trashed": true}` when the item went to the **Trash** (the user can put it back) and `{"trashed": false}`
  when it was deleted **permanently** — tell your user which. By place:

  | Place | A delete is |
  |---|---|
  | This Mac | moved to the Trash |
  | A mounted share (SMB) | moved to the Trash if the share's volume has one, else **permanent** (many Samba servers have none) |
  | S3, SFTP / SSH | **permanent** |

  Vektor asks the volume whether it has a Trash; it does not try the Trash and fall back. If a volume has a Trash and moving the
  item there fails (no permission, say), the delete fails with `code: "failed"` and the item stays — it is never made permanent
  as a second try. Either way a deleted item is gone from the place and never listed back; `ifVersion` works as before, and
  a link is deleted, never its target. The Log line says "moved to the Trash" or "deleted permanently". Deleting something
  that is not there answers `notFound` — with or without `ifVersion` (it is never `changed`).

What `ifVersion` can promise depends on the place (measured, not assumed):

| Place | Write | `ifVersion: "<version>"` | `ifVersion: null` | Can still lose a race |
|---|---|---|---|---|
| This Mac | atomic | checked; Vektor's own writers wait for each other | atomic | another program writing the same file within ~0.1 ms |
| A mounted share (SMB) | atomic | checked | checked | another computer within a few milliseconds; a change made in place elsewhere can show a few seconds late |
| S3 | atomic | **atomic** (the service compares) | **atomic** | a write racing a delete can bring the file back |
| SFTP / SSH | atomic | checked | atomic | another writer during your upload; two changes within the same second that keep the size |

"Checked" means Vektor compares the version right before it writes; on S3 the service itself refuses. Design for the rare
lost race the way you design for an offline device: write small files, read before you merge, and keep a version per file.

```json
→ {"api":2,"id":7,"method":"storage/read","params":{"place":"pl-k2v7…","path":"board.json"}}
← {"api":2,"id":7,"result":{"content":"{\"cards\":[]}","encoding":"text","eof":true,"offset":0,"size":12,"version":"v1.m.1792575995.12"}}
→ {"api":2,"id":8,"method":"storage/write","params":{"place":"pl-k2v7…","path":"board.json","content":"{\"cards\":[1]}","ifVersion":"v1.m.1792575995.12"}}
← {"api":2,"error":{"code":"changed","data":{"currentVersion":"v1.m.1792576100.15"},"message":"“board.json” changed since you read it."},"id":8}
```

Refusal codes (`error.code`): `changed`, `notFound`, `exists`, `wrongKind`, `badPath`, `badPlace` (a handle from another
workspace or an older value), `badCursor` (a `storage/list` cursor that is forged, stale or for another listing), `missing`,
`offline`, `needsSignIn`, `unavailable`, `tooLarge`, `badRequest`, `refused`, `failed`.
`error.data.state`, when present, is what `storage/status` would say. Each call is written to your plugin's Log — method, place,
path and result, never the content.

## View descriptions

A view is described by `view/update` — the **whole** description, every time; Vektor draws it natively. Send one when the view
opens (`view/opened`) and whenever something changes; the samples also send one right after `startup`, so a Settings tab and a
sidebar badge are ready before anyone opens a pane. Text is clipped (titles to 120 characters, lines to 300); there is **no
cap on how many** cards, lines, buttons, menu items, rows, groups or fields a view shows. Unknown fields are ignored. A
description that cannot be shown is refused with the reason in the Log, and the view keeps what it showed.

Common to every kind:

```json
{"view": "tunnels", "description": {
   "revision": 12,
   "header":  {"title": "Tunnels", "primary": {"title": "New Tunnel", "symbol": "plus", "action": "new"}, "search": true},
   "banner":  {"text": "…", "tone": "warning", "symbol": "…", "linkTitle": "…", "link": "https://…"},
   "toolbar": {"buttons": [{"title": "Refresh", "symbol": "arrow.clockwise", "action": "refresh"}], "search": {"placeholder": "Filter", "action": "q"}, "message": "3 selected"},
   "empty":   {"title": "Nothing here", "message": "…", "symbol": "tray", "button": {"title": "New", "action": "new"}}
}}
```

`revision` counts up with every description; Vektor ignores one older than what it shows. **An `action` is a string you choose;
Vektor hands it back verbatim in `view/event` and never interprets it.**

* **`cardList`**: `"cards": [{"id", "symbol", "title", "pill": {"label","tone"}, "lines": ["text" | {"text","link"?}], "action"?,
  "buttons": [{"title","symbol","action","enabled"}], "menu": [{"title","symbol","action","destructive","enabled"} | {"separator": true}]}]`.
* **`list`**: `"list": {"input": {"placeholder","action"}, "reorder": "action", "groups": [{"id","title"?,"collapsible","startsCollapsed",
  "rows": [{"id","title","subtitle"?,"symbol"?,"checkbox": {"checked","action"}, "badge": {"label","tone"}, "edit": "action", "action"?, "delete": "action",
  "dimmed", "buttons": [], "menu": []}]}]}`. Events: the `input`'s action with `value` (the text); a checkbox's action with `card` and
  `value` (the new state); `edit` with `card` and `value`; `delete` with `card`; `reorder` with `card`, `before`, `index`, `group`.
  A reorder stays within one group: `group` is that group's `id` (`"rows"` for a list without `groups`), `index` the row's new
  position in it counted once it is out of its old place (0 is the top), and `before` the id of the row it now stands before —
  absent when it moved to the end. A move that changes nothing sends no event.
* **`form`**: `"form": {"buttons": [], "sections": [{"id","title"?,"description"?,"fields": [{"key","kind": "text|toggle|choice|label|button","label","value","options"?,"help"?,"placeholder"?,"enabled"?,"action"?}]}]}`;
  a field's change arrives as its `action` (default `change`) with `field` and `value`; a `button` field sends its `action` (default its `key`).
* **`detail`**: `"detail": {"heading": {"title","subtitle"?,"symbol"?}, "rows": [{"label","value","link"?}], "markdown": "…", "actions": [{"title","symbol","action","enabled"}]}`.
  The Markdown is drawn by the same renderer as the Preview; remote images are not loaded. It is not capped (only the
  2,000,000-character protection a Markdown block has).
* **`toolbar`**: only the `toolbar` object above.

Worked examples: `samples/todo/run.zsh` and `samples/todo-node/run.js` (`list` and `detail`) and `samples/cloudflare-tunnel/run.zsh` (`cardList`).

## Block views (API 2)

A view of `"kind": "blocks"` is a **tree of blocks** you compose; Vektor draws every block natively, so the theme, the keys,
VoiceOver and the rules about what may act behind a dialog stay Vektor's. Anything that draws or takes input is a block;
anything that only arranges blocks — a board, a list beside a detail — is a composition you build from them (the SDKs
offer common ones). The manifest must say `"api": 2`; an older Vektor shows such a plugin as needing a newer Vektor.

```json
{"view": "board", "description": {"revision": 4, "header": {"title": "Roadmap"},
  "blocks": {"type": "hstack", "id": "board", "children": [
    {"type": "panel", "id": "col-todo", "title": "To do", "role": "label6", "children": [
      {"type": "list", "id": "todo", "group": "cards", "move": "move", "children": [
        {"type": "card", "id": "c1", "title": "Write the spec", "edit": "rename", "delete": "remove",
         "children": [{"type": "badge", "id": "c1-tag", "text": "docs", "role": "label3"}]}]}]},
    {"type": "panel", "id": "col-done", "title": "Done", "role": "label4", "children": [
      {"type": "list", "id": "done", "group": "cards", "move": "move", "children": []}]}]}}}
```

`blocks` is one block (the root) or a list (read as a vertical stack). Every block has a `type`; an `id` is required for the
items of a collection, for inputs, sections, tabs, splits and nodes, and for anything that sends an event — and ids are unique
in the view. Header, toolbar and banner work as in every kind. An **unknown `type`** is drawn as a small "This view needs a newer
Vektor" placeholder (so a newer plugin degrades, never blanks); a missing `type`, a repeated id or an item without an id refuses
the description.

**Blocks** (fields in brackets are optional):

| Type | What it draws | Fields |
|---|---|---|
| `vstack`, `hstack` | children in a column / row; a row of one-line blocks (text, symbols, badges, counts, controls, spacers) is centred on its middle, a row holding taller blocks keeps their tops level | [`spacing`] |
| `spacer`, `divider` | flexible space; a line | — |
| `grid` | tiles: `columns` fixed, or as many as fit at `minWidth`; lazy | [`columns`], [`minWidth`] (here: the tile minimum), [`spacing`] |
| `scroll` | scrolls its children (`axis`: `vertical`, `horizontal`, `both`); a vertical one builds only what is on screen; a horizontal one whose children `grow` fills its width (see Widths) and shows a "›" / "‹" on an edge with more beyond it; a vertical one with `"anchor": "end"` opens at its end and stays there as it grows (a conversation) | [`axis`], [`spacing`], [`anchor`] |
| `split` | two children with a divider the user drags | [`axis`: `horizontal`/`vertical`], [`fraction`], [`height`] inside a scroll |
| `section` | a titled group that can fold | `id`, [`title`], [`collapsible`], [`collapsed`], [`count`] |
| `tabs` / `tab` | tabs (or `"style": "segmented"`) over `tab` children; only the chosen one is drawn | `id`; tab: `id`, `title`, [`symbol`]; [`action`] sends the chosen tab |
| `card`, `panel` | an elevated / plain surface; a role draws a stripe — or, with `"filled": true`, fills it with the role's tint and makes it as wide as what it holds, up to its `maxWidth` (a chat bubble); a card with `edit` renames its title in place | [`title`], [`symbol`], [`role`], [`badge`], [`filled`]; as an item: [`edit`], [`action`], [`delete`] |
| `list` | items (any block, usually `row` or `card`), drawn lazily | `id`, [`selection`: `none`/`single`/`multiple`], [`selected`], [`select`], [`group`], [`move`], [`placeholder`], [`spacing`] |
| `row` | a line: checkbox, symbol, title, subtitle, badge, buttons, "…" | [`title`], [`subtitle`], [`symbol`], [`check`]+[`checked`], [`badge`], [`buttons`], [`menu`], [`dimmed`]; as an item: [`edit`], [`action`], [`delete`] |
| `table` | sortable columns, widths the user drags; `row` children with `cells` | `id`, `columns` (`[{id, title, width?, sortable?}]`), [`sorted`: `{column, ascending}`], [`sort`], [`selection`], [`selected`], [`select`] |
| `tree` / `node` | an outline; nodes fold | `id`; node: `id`, `title`, [`symbol`], [`expanded`], node children |
| `text` | `style`: `title`, `heading`, `body`, `caption`, `mono` | `text`, [`style`], [`selectable`], [`link`], [`role`], [`lineLimit`] |
| `symbol`, `badge`, `count` | an SF Symbol; a word on a tinted capsule; a number | `symbol` / `text` / `count`, [`role`], [`label`] for VoiceOver |
| `markdown` | Markdown with the Preview's renderer; remote images are not loaded | `markdown` |
| `empty`, `banner`, `status` | an empty state (it takes the room it is given and sits in its middle; blocks inside it, such as a button, are drawn centred under its text); a note; a one-line status | [`title`], `text`, [`symbol`], [`role`], [`link`]; `empty`: children |
| `diff` | two texts compared by the Diff Tool's engine, read-only | `left`, `right`, [`leftTitle`], [`rightTitle`], [`keepLeft`], [`keepRight`] |
| `button` | `style`: `primary`, `plain`, `destructive`, `icon` (with a tooltip), `borderless` (an icon with no surface: a done circle) | `action` (or a `menu`), [`title`], [`symbol`], [`tooltip`], [`busy`], [`enabled`] |
| `textField`, `searchField`, `textArea` | text; Return commits (⌘Return in a text area), a click away commits; a text area is `lineLimit` lines high (default 4) and grows to twice that | `id`, `action`, [`value`], [`placeholder`], [`title`], [`error`], [`lineLimit`] |
| `toggle`, `checkbox` | on/off | `id`, `action`, [`value`], [`title`] |
| `picker` | a menu, or `"style": "segmented"` | `id`, `action`, `options` (`[{value, title, symbol?}]`), [`value`] |
| `stepper` | a number with − and + | `id`, `action`, [`value`], [`min`], [`max`], [`step`] |
| `menu` | a "…" (or titled) menu; `symbol` is drawn only beside a `title` (an untitled "…" menu ignores it) | `menu`, [`title`], [`symbol`] |
| `datePicker` | a date; the calendar opens over the view | `id`, `action`, [`value`: `yyyy-MM-dd`] |
| `tagPicker` | tags as pills; Return adds one; suggestions while typing | `id`, `action`, [`tags`], [`suggestions`] |
| `rolePicker` | a colour **role** (never a value); sends the role's name | `id`, `action`, [`value`], [`options`] (`[{value, title}]`, `value` a role name) to limit the roles — the swatches show the theme's own names, an unknown role is left out, no options offer all 13 |
| `spinner`, `progress` | busy; a bar (`progress` 0…1, none: indeterminate) | [`text`/`title`], [`progress`] |
| `fileList` | files and folders with Vektor's icons: double-click opens, the menu shows one in a pane, a file drags out | `files` (absolute paths; a folder ends in `/`) |

**On any block**: `menu` (a context menu: `[{title, action, symbol?, destructive?, enabled?} | {separator: true}]`), `tooltip`,
`label` (what VoiceOver reads), `drag` (the block can be dragged; the value is its group), `drop` (`{action, accepts: [groups]}`),
`fileDrop` (`{action, accepts: files|folders|both, extensions?}`: files and folders dropped from Vektor's panes or Finder, sent
as `files: [{path, name, isFolder}]` — local items only), `revealOnHover` (drawn only while the pointer is over it or it has the
keyboard), `enabled`, `error` (an inline error under an input), and the widths below.

**`badge`** (on a card, a panel or a row) is an object `{text, role?}` (`label` is read when there is no `text`): the text is
one line of at most 40 characters, `role` a [colour role](#block-views-api-2) — an unknown role draws the badge without one. A
string is not a badge. **Options** (a `picker`'s, a `rolePicker`'s) are `[{value, title, symbol?}]`; an option whose `value` or
`title` is missing or blank refuses the whole description ("every option of “…” needs a “value” and a “title”"), and so does a
menu item without a `title` or an `action`.

**Widths.** Any block may ask for a width — structural numbers in points, never a theme's: `width` (the width it asks for;
never wider than its row offers, so it cannot push the view past the pane), `maxWidth` (the widest it is drawn), `minWidth`
(the narrowest; honoured inside a horizontal `scroll` only, which shows the rest by scrolling — on a `grid` it keeps its own
meaning, the tile minimum) and `grow: true` (the block takes a share of the width its row leaves; growing siblings share it
equally). Values are 20…4000; another value is ignored and the Log says so. A block without them is drawn as before. A board
whose columns fill the pane and scroll once they no longer fit:

```json
{"type": "scroll", "axis": "horizontal", "spacing": 12, "children": [
  {"type": "panel", "id": "col-todo", "title": "To do", "grow": true, "minWidth": 240, "children": [ … ]},
  {"type": "panel", "id": "col-done", "title": "Done",  "grow": true, "minWidth": 240, "children": [ … ]}]}
```

A horizontal `scroll` with a growing child (directly, or inside its `hstack`) is laid out at least as wide as it is shown.

**Selection.** `selection` is `none`, `single` (the default) or `multiple`. `selected` (item ids) is the selection to *start*
from: Vektor shows it until the user selects, keeps the user's selection while any of its items is still described, and
returns to your `selected` only once none is (it never sends `select` for that). A click, the arrow keys, Home/End, Page
Up/Page Down and Space change the selection the same way and send `select` with `block` (the list or table) and `selected`
(every selected id, in your order) — once per change; while an arrow key is held, only the last selection, once it is let go.
In a `multiple` list or table, ⌘-click adds or removes an item and ⇧-click selects from the last plain or ⌘-clicked item to
this one (in the order drawn).

**Colour roles.** You never send a colour value: name a `role` — `accent`, `positive`, `warning`, `danger`, `neutral`, or
`label1` … `label8` (red, orange, yellow, green, teal, blue, purple, pink in the theme's own register) for tags and columns.
Every theme defines every role, graded for contrast under every accent. A `color`, `background`, `foreground`, `tint` or `fill`
field is ignored and the Log says so; meaning must also be in words (a badge always has its text).

**Events** (`view/event`, besides `view`, `revision`):

| What happened | `params` |
|---|---|
| a button, a menu item, an item's `action` (Return, a double-click, ⌘↓ — below) | `action`, `block` |
| an input changed (text committed, toggle, picker, stepper, date, tags, role, tab) | `action`, `block`, `value` (string, boolean, number, `yyyy-MM-dd` or `null`, list of strings) |
| an item's title edited in place (`edit`) | the `edit` action, `block`, `value` |
| an item's checkbox (`check`) | the `check` action, `block`, `value` (the new state) |
| delete (⌫ or ⌘⌫ on an item with `delete`) | the `delete` action, `block` (the focused item), `selected`? — every selected id, in your order, when the item is part of a `multiple` selection: **one event for the whole selection** |
| an item moved — dragged, or ⌥ + an arrow | the target's `move` (or a block's `drop`) action, `item`, `from`?, `target`, `index` |
| files dropped | the `fileDrop` action, `block`, `files` |
| a table's sort | `sort`, `block`, `column`, `ascending` |
| a list's or a table's selection (`select`) | `select`, `block`, `selected` |

**Which `block` a menu item names**: the block that carries the menu — the block with a context `menu`, the `row` whose "…"
menu it is (a row's `buttons` too), the `menu` block itself, the `button` whose `menu` it is, a table row or a tree node with a
context menu. Read the column or the card from that id.

`index` is the item's position in `target` once it is out of its old place, among the items Vektor **shows** (with a search
or a filter of yours on, only those). Items move between lists of the same `group` (and within a list that has `move`); Vektor
shows the move only when your next description or patch does — you decide.

**Keyboard.** Arrows move the focus within a list and to the neighbouring list (a board's columns), skipping an empty one;
Home, End, Page Up and Page Down move it within the list; ⌥ + an arrow moves the focused item (the same event as a drag);
Space checks it (or, in a `multiple` selection, adds or removes it); ⌫ / ⌘⌫ delete it (only with `delete`); Esc ends an edit
or closes the view; Tab goes to the other pane. **Return renames an item that has `edit` and opens one that has only
`action`; a double-click opens (`action`) and renames only an item without one; ⌘↓ opens** — Finder's rule, so an item
with both (a board card) can be renamed and opened. Renaming in place works on a `row`, a tree `node` and a `card`: the title
becomes a field, Return or a click elsewhere sends `edit`, Esc keeps the old title. While a field edits, every key but Return
and Esc is the text's (⌫ deletes text, never the item), and ⌘A/⌘C/⌘V act on the text — never on files, and no F-key acts behind
the view.

### Patches

`view/patch` changes a block view by id, so a large board is never sent again whole:

```json
{"view": "board", "revision": 5, "ops": [
  {"op": "move", "id": "c1", "parent": "done", "index": 0},
  {"op": "insert", "parent": "todo", "index": 0, "block": {"type": "card", "id": "c9", "title": "New"}},
  {"op": "replace", "id": "c2", "block": {"type": "card", "id": "c2", "title": "Renamed"}},
  {"op": "remove", "id": "c3"}]}
```

`index` is optional on `insert` and `move`: without it the block goes to the end of `parent` (for a move, counted once it is
out of its old place). Present, it must be a whole number from 0 to the number of children — `null` is refused, not read as
absent.

Operations apply in order and **all or nothing**: one that cannot apply (an unknown id, an index past the end, a repeated id)
refuses the patch, the view keeps what it showed and the Log names the operation. A patch needs a described view, and one
older than the shown `revision` is ignored. Patches are optional; measured on a 5,000-card board, a one-card move redraws in
about 70 ms as a patch and about 145 ms as a whole description.

**When Vektor refuses** a description or a patch, it tells you with `view/refused`: `{view, kind, revision, refusedRevision?,
problem}`. `revision` is what Vektor **still shows**, and every `view/event` keeps carrying it until you send something Vektor
can show. So do not count an event made against that revision as stale: send the whole description again (`view/update`),
numbered above anything you sent, and carry on. An `"api": 1` plugin is never sent `view/refused` (its refusals are in the Log
only).

### Sidebar items

`sidebar/items` lists items under one of your sidebar entries (boards, projects), in your order. Vektor remembers them per
workspace, so the sidebar shows them without starting your plugin; send them again when they change and after
`workspace/changed`. A click opens the entry's view with `view/opened` carrying `item`; the `sidebarItem` menu carries `entry`
and `item` in its `target`. When the view switches to another item by itself (a board picked inside the view), put `"item"`
in the description you send with `view/update` — the item's id, or `null` for none — and the sidebar marks that item
instead of the one the view was opened with. Without `"item"` the mark stays where it is.

## Web views (API 2)

**Prefer [block views](#block-views-api-2).** Vektor draws blocks itself, so their keys, VoiceOver, theme and the rules about
what may act behind a dialog are right by construction. A web view is for what blocks will never draw — a canvas, a diagram
editor, an existing web UI. It is a page made of **your plugin's own files**, shown in a sandbox:

```json
"views":   [ {"id": "sketch", "title": "Sketch", "kind": "web", "entry": "web/index.html"} ],
"sidebar": [ {"id": "sketch", "title": "Sketch", "symbol": "scribble.variable", "view": "sketch"} ]
```

`entry` is a path inside the plugin folder (no absolute path, `..`, `~` or backslash; an `.html` or `.htm` file), checked when
the plugin loads with links followed: a page that is missing, or a link that leads out of the folder, refuses the plugin. The
manifest must say `"api": 2`. You do not have to describe a web view; its page is its content. A page can also be **one block** of
a block view, beside native blocks — a toolbar of buttons above a canvas:

```json
{"type": "vstack", "id": "root", "children": [
  {"type": "hstack", "id": "bar", "children": [{"type": "button", "id": "clear", "title": "Clear", "action": "clear"}]},
  {"type": "web", "id": "canvas", "entry": "web/canvas.html"}]}
```

A `web` block needs an `id` and an `entry`; inside a vertical scroll it takes `height` (default 220), elsewhere it fills what the
layout gives it. Describing the blocks again keeps the page (same `id` and `entry`); removing the block ends it.

**The sandbox.** A page is loaded from `vektor-plugin://<your plugin id>/<entry>` and may load only your folder's files from
there (relative URLs work: `app.js`, `style.css`, `data.json`, images, fonts, `fetch('data.json')`). Refused, whatever the page
does: anything on the network (`fetch`, XHR, WebSocket, images, scripts, fonts, styles, beacons), `file://`, another plugin's
files, navigating away, pop-up windows, downloads, form posts, frames, the camera, the microphone, the file chooser, files dropped
on the page, and `alert()`/`confirm()`/`prompt()` (ask your plugin, which can show a [dialog](#dialogs)). A link the **user** clicks
opens in the default browser if your plugin has the `openURLs` permission, and never in the view. Paste gives the page text only.
Nothing a page stores is kept (cookies, `localStorage`, IndexedDB are per page and gone when it closes): keep data in your plugin,
in its data folder. The web inspector is available only in Developer mode, for a plugin loaded from a folder.

**The bridge** is the only way out of the page, and it leads only to your plugin. Vektor defines `vektor` before your scripts run:

```js
vektor.post({ type: 'save', strokes });        // your plugin receives web/message { view, block?, message }
vektor.onmessage = (message) => { … };          // your plugin's web/post { view, block?, message } arrives here
window.addEventListener('vektor-message', (e) => e.detail);   // the same, as an event
```

A message is any JSON value of at most 1 MB (functions and dates do not cross); a page that posts more than 200 messages a second
has the rest dropped (the Log says so). Your `web/post` reaches only **your** pages showing that view — every one of them, or
only the `block` you name — in any tab, shown or hidden. Nothing else of Vektor is reachable from a page.

**The theme.** Vektor sets the active theme on the page's `:root` as CSS custom properties before your first script runs, and
again at once when the theme or the accent changes (then the `vektor-theme` event fires):

* `--vektor-color-<token>`: `background-primary`, `background-secondary` (the pane), `background-elevated` (cards, fields),
  `background-chrome`, `surface-row-alternate`, `surface-row-hover`, `foreground-primary`, `foreground-secondary`,
  `foreground-muted`, `foreground-disabled`, `foreground-on-accent`, `accent-primary`, `accent-secondary`, `accent-destructive`,
  `accent-warning`, `accent-success`, `border-standard`, `border-subtle`, `border-focus`, `selection-background`,
  `selection-foreground`, `selection-inactive`;
* `--vektor-role-<role>-mark`, `-text`, `-fill` for the [colour roles](#block-views-api-2) (`accent`, `positive`, `warning`,
  `danger`, `neutral`, `label1` … `label8`), each graded for contrast in every theme;
* `--vektor-font-family`, `--vektor-font-mono`, `--vektor-font-size`, `--vektor-font-size-small`, `--vektor-font-size-heading`,
  `--vektor-font-size-title`, `--vektor-radius-window`, `-panel`, `-control`, `-menu`, `--vektor-border-width`,
  `--vektor-space-xxs` … `--vektor-space-xl`, `--vektor-theme-light` (`1` or `0`), and `color-scheme`.

The sample's `web/vektor.css` is a **starter stylesheet** built only on these: copy it into your plugin and a plain page looks
like Vektor in every theme. Never hard-code a colour.

**Keys.** While the page has the keyboard, letters, arrows, Tab, Return and the F-keys are the page's, and ⌘A, ⌘C, ⌘V, ⌘X, ⌘⌫
and ⌥⌘⌫ edit the page's text (they never act on files). ⌘Z and ⇧⌘Z undo and redo the page's own text editing; the page does not
receive them as `keydown`. Esc gives the keyboard back to the view (a second Esc closes it). Window commands (⌘W, ⌘T, ⌘1, ⌘2 …)
still work. While anything covers the page — a dialog, a menu, the Diff Tool, a maximized terminal — or its tab is in the
background, it receives no key and no click; it keeps its state and is not reloaded.

**When it goes wrong.** A page that does not answer for five seconds (an endless loop) is reported in your Log and the view says
"This view stopped responding" with **Reload**, which starts it in a new process; so does a page whose process ended. Vektor stays
responsive either way: every page runs in a process of its own (about 20 MB each). Closing the view, closing its tab or stopping
the plugin ends that process.

A minimal page:

```html
<!doctype html>
<html><head><meta charset="utf-8"><link rel="stylesheet" href="vektor.css"></head>
<body>
  <h1>Hello</h1><button class="primary" id="ping">Ping</button> <span id="answer"></span>
  <script>
    vektor.onmessage = (m) => { document.getElementById('answer').textContent = m.text; };
    document.getElementById('ping').onclick = () => vektor.post({ type: 'ping' });
  </script>
</body></html>
```

and its plugin's side (zsh): on `web/message` with `message.type` `ping`, send
`{"api":2,"method":"web/post","params":{"view":"hello","message":{"text":"pong"}}}`. The complete example is `samples/sketch`
(a drawing kept in the data folder, colours by role, a link to the browser).

## Dialogs

`dialog/show` is a request; Vektor answers when the user does:

```json
{"api":1,"id":1001,"method":"dialog/show","params":{
   "title": "Publish Port", "subtitle": "…", "primary": "Start Tunnel", "cancel": "Cancel",
   "fields": [ {"key":"port","kind":"number","label":"Port","integer":true,"min":1,"max":65535,"required":true},
               {"key":"path","kind":"readOnlyPath","label":"Local path","path":"/Users/me/site"} ],
   "sections": [ {"id":"advanced","title":"Advanced","open":false,"fields":[ {"key":"extra","kind":"text","label":"Extra arguments"} ]} ] }}
→ {"api":1,"id":1001,"result":{"result":"submit","values":{"port":"8080","extra":""}}}
```

A field has the same kinds and rules as a [setting](#settings) (`text`, `number`, `toggle`, `choice`, `path`, `secret`, `list`), plus
`readOnlyPath` (shown with the item's icon). The primary button stays disabled until required fields are valid. Cancel, Esc and a
click on the backdrop answer `{"result":"cancel","values":{}}` — an older Vektor leaves `values` out, so read it as optional. There is no
cap on fields or sections (only the protection limit below). Only one dialog shows at a time.

## Permissions

The user approves a plugin's permissions **before it first runs**, and again whenever an update adds one. Nothing runs before.

| Permission | In plain words |
|---|---|
| `processes` | Runs programs on your Mac |
| `network` | Uses the network |
| `readSelection` | Reads the files you choose it for |
| `writeFiles` | Changes files outside its own folder |
| `openURLs` | Opens web pages in your browser |
| `secrets` | Keeps passwords and tokens in your keychain |
| `decorate` | Adds badges and details to your files |
| `events` | Is told about events you turn on for it |
| `location` | Browses and changes files in an account it connects to |
| `storage` (API 2) | Reads and writes files in the place you choose for it |

Ask for what you use and no more: the registry's pull-request check requires the entry's permissions to equal the manifest's.
Permissions describe what Vektor lets the plugin ask of *Vektor*; the program is an ordinary program on the user's Mac, which is
exactly why the user approves it first.

## Errors and limits

* Answer a failed request with `error.message` in **plain words** for the user. No error codes, no `errno`, no stack traces: it is
  shown as written.
* A protocol error (bad header, oversized message, a message that is not an object, no `api`, an `api` this Vektor does not speak)
  is logged; a broken stream ends the plugin.
* A plugin that exits during startup, does not answer `startup`, floods Vektor with messages, or crashes repeatedly is
  turned off after a few tries, with the reason on its page.
* `invoke` has a timeout (`timeout` on the command, in seconds, default 120). `$/cancel` tells you the user cancelled.
* Limits: message body 16 MB; manifest 256 KB; text in a description is clipped as listed above; a block view holds at most
  100,000 blocks nested at most 64 deep, a dialog at most 100,000 fields and sections, and a patch at most 10,000 operations
  (protection against a runaway plugin, far above a board of thousands of cards); Markdown (a block or a `detail`) 2,000,000
  characters; a sidebar entry lists at most 2,000 items; a secret 16 KB; clipboard 1 MB.
* A plugin that sends more than 32 MB or 200 messages a second for two seconds in a row is flooding and is stopped.
* A web page's message (either way) is at most 1 MB; a page posting more than 200 a second has the rest dropped.

## API versioning

The manifest's `api` is the plugin API the plugin was written for; every message carries it. This Vektor speaks `api` 1 and 2
(2 added block views, patches, sidebar items, `workspace/changed`, `view/refused`, colour roles, `place` settings, the storage
service and web views; an
`api` 1 plugin runs unchanged and is never sent an API 2 message). A plugin
needing a higher `api`, or a newer Vektor (`minVektor`), is shown as **Incompatible** and is not run or installed. Vektor keeps
supporting the previous API when a new one arrives, so a working plugin keeps working; new fields are added without a version
bump, so **ignore fields you do not know**.

## Writing the program

Learned from the samples; the templates' comments repeat them where they matter. Pick the language by what the **user** has to
install: nothing (zsh, or a compiled program), or something (Node.js).

* **zsh** (`templates/zsh`): `export LC_ALL=C` (strings are bytes, so `Content-Length` is `${#string}`) and `setopt extended_glob`
  (the header match is an extended glob; without it no message is ever read). Read JSON with `plutil -extract <path> raw -o - -`
  (one field per call) and write it by hand through a function that escapes `\`, `"` and control characters. zsh is on every Mac.
* **Node.js** (`templates/node`, `samples/todo-node`): easy JSON, but **Node is not installed by macOS**, so the user must install
  it, and a Node from nvm, fnm or Volta is not on the plugin's `PATH` (`#!/usr/bin/env node` fails). Say so in a `banner` on a
  setting (the templates do), and in the plugin's README. `Content-Length` is a byte count: measure the encoded `Buffer`
  (`Buffer.byteLength`), never `string.length`, and read stdin as bytes. Never `console.log` (that is stdout); use `console.error`
  or the `log` message. Answer `shutdown`, and exit once the answer is written. Use no npm packages, so the folder is the plugin.
* **Swift or any compiled language** (`templates/swift`): nothing for the user to install. The program must be signed
  ([Compiled programs and signing](#compiled-programs-and-signing)); `templates/swift/build.sh` builds for arm64 (Vektor runs only on
  Apple silicon) and signs ad hoc.
* **Python is not offered.** It is not part of macOS (running `python3` on a Mac without the Command Line Tools opens an
  installer prompt), so a Python plugin would fail on many users' Macs and could not say why. If you need it, bundle a compiled
  program instead.
* Read a message: lines until an empty one (find `Content-Length`), then exactly that many **bytes** — `sysread -i 0 -s N` in a
  loop. At end of file Vektor is gone: clean up and exit.
* Answer `shutdown` and exit. Stop everything you started; keep nothing in the plugin folder.
* Do your slow work without blocking the loop where you can; `ping` is how Vektor tells a hung plugin from a busy one.
* A **compiled** program reads stdin the same way. Anything with a runtime (Node, Ruby) is the user's to install; say so in a
  `banner` on the setting that points to it, as the tunnel sample does for `cloudflared` and the Node ones do for Node.

## Compiled programs and signing

macOS kills an **unsigned or modified compiled program (Mach-O) silently** when it starts, and a compiled program that carries the
quarantine mark (downloaded from the internet) raises a system alert for every start. So:

* **Scripts are fine**, with or without the quarantine mark: zsh and Node are not the marked files, and a script folder
  downloaded in a browser loads in Developer mode. Only a quarantined **compiled program** in the plugin folder is refused, and
  then the whole folder is. Vektor looks at up to 2,000 files before each start; a larger folder (a big `node_modules`) that
  carries the mark anywhere is refused too, since a compiled program further down cannot be ruled out.
* A compiled `executable` must be **signed**: `codesign -s - path/to/program`. **An ad-hoc signature is all that is needed** — no
  Developer ID, no notarization, no Apple account; most compilers already add it. Sign **after** the last change; any change
  invalidates it.
* **Vektor never signs anything for you**, and refuses to install a package whose compiled program is not validly signed.
* A package installed from the registry never carries the quarantine mark (Vektor checks the package's SHA-256 against the
  signed index first). A **folder** you load in Developer mode that holds a compiled program and was downloaded from the internet
  does: remove the mark with `xattr -dr com.apple.quarantine <folder>`; `vektor-plugin validate` says so in the same words
  Vektor does. (`curl` adds no mark.)
* Programs your plugin starts through the Processes service (`cloudflared`, a helper) get the same check before they run.

## Tools

The tools are compiled programs that reuse Vektor's own code, so they cannot disagree with Vektor. They come from the **tools
release** of the plugins repository (`tools-<version>`, the asset `vektor-plugin-tools-macos.zip`): `vektor-plugin` (for authors)
and `vektor-registry` (the registry check), built for Apple silicon (arm64). Nothing to build, nothing to install but the two files:

    curl -fLO https://github.com/vektor-commander/vektor-plugins/releases/download/tools-<version>/vektor-plugin-tools-macos.zip
    unzip vektor-plugin-tools-macos.zip -d ~/vektor-tools

The programs are ad-hoc signed, not notarized. `curl` adds no quarantine mark; if you downloaded the zip in a browser, run
`xattr -d com.apple.quarantine ~/vektor-tools/vektor-plugin ~/vektor-tools/vektor-registry` once (otherwise macOS refuses to open
them). Then:

    ~/vektor-tools/vektor-plugin validate <folder>
    ~/vektor-tools/vektor-plugin test <folder> <script.json> [--verbose] [--keep]

### The test host

`vektor-plugin test` starts the plugin the way Vektor does (its own process group, the minimal environment) and talks to it with
Vektor's own message codec; it answers the plugin's requests (`{}` unless the script says otherwise). A script is JSON:

```json
{ "settings": { "sort": "newest" },
  "workspace": null,
  "autoReply": { "dialog/show": { "result": "cancel" }, "confirm": { "$error": "no" } },
  "steps": [
    { "name": "starts",  "startup": true, "expect": [ { "kind": "response" },
        { "kind": "notification", "method": "view/update", "match": { "params.view": "todos", "params.description.empty.title": "Nothing to do" } } ] },
    { "name": "adds",    "send": { "method": "view/event", "params": { "view": "todos", "action": "add", "value": "Buy milk" } },
      "expect": [ { "method": "view/update", "match": { "params.description.list.groups.0.rows.0.title": "Buy milk" },
                    "capture": { "first": "params.description.list.groups.0.rows.0.id" } } ] },
    { "name": "toggles", "send": { "method": "view/event", "params": { "view": "todos", "action": "toggle", "card": "${first}", "value": true } },
      "expect": [ { "method": "view/update", "match": { "params.description.list.groups.1.id": "done" } } ] },
    { "name": "quiet",   "send": { "method": "ping" }, "expect": [ { "method": "view/update", "absent": true } ] },
    { "name": "ends",    "send": { "method": "shutdown", "params": { "reason": "quit" } }, "expect": [ { "kind": "response" } ], "expectExit": true } ] }
```

* `startup: true` sends `startup` with Vektor's parameters; the manifest's setting defaults sit under the script's `settings`.
* `send` is a request unless the method is one Vektor sends as a notification (`settingsChanged`, `view/opened`, `view/closed`,
  `view/event`, `view/refused`, `web/message`, `process/output`, `process/exited`, `$/cancel`, `workspace/changed`); `"kind"`
  overrides.
* An expectation is satisfied by **any** message the plugin sends during the step that fits: `kind` (`response`, `failure`,
  `notification`, `request`), `method`, and `match` — paths into `{kind, id, method, params, result, error}` (object keys and array
  positions joined by dots) compared with a value, or tested with `{"exists": bool}`, `{"contains": "text"}`,
  `{"matches": "regex"}`, `{"count": n}`. A `response` or `failure` expectation means the answer to *that step's* request.
  `"absent": true` means it must **not** arrive. `capture` stores a value for `${name}` in later steps; `${folder}`, `${data}` and
  `${session}` always exist.
* `timeout` (seconds, default 5) bounds a step; `expectExit` waits for the plugin to leave by itself.
* A script whose first line is `#!/usr/bin/env node` (or another tool) is started with the plugin `PATH` above. If the tool is
  not in one of those folders, `validate` warns and `test` stops with a plain explanation instead of an empty conversation: that
  is what the user's Vektor would see too.
* Exit status 0 when every step passed; on a failure the whole conversation is printed. In CI: one command, no Vektor, no window.
* **Places** (API 2): a setting written `{"$place": "boards"}` in the script's `settings` becomes a fake place — an empty folder
  in the test's temporary folder — and the plugin receives a handle for it (`label` "Test place ▸ boards"). The test host answers
  the storage service on it the way Vektor answers for a folder on this Mac (same path rules, versions and refusal codes; a
  delete moves the item to a stand-in Trash in the test's temporary folder, never yours, and answers `{"trashed": true}`; listing
  pages and refuses a bad cursor exactly as Vektor does).
  `${place.boards}` is that folder's path, for a later step's parameters.
* The test host does not simulate the Processes service (`process/start` is answered with `{}` unless you script it): test the
  logic around it, and use the real Vektor with Developer mode for the rest.

## Publishing

Zip the plugin folder, host the zip at an https address, and open a pull request against the plugins repository with
`plugins/<id>.json`. The automatic check (`vektor-registry check`) validates the manifest, downloads the package, compares its
SHA-256 and permissions with your entry and refuses id collisions. The whole path, step by step, and the entry format are in
`CONTRIBUTING.md` and `index.schema.json` of the plugins repository. Vektor shows the plugin in Get Plugins once the maintainer
has signed the new index.
