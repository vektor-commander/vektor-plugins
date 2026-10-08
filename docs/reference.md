# Vektor plugin reference (plugin API 1)

Everything a plugin author needs, from the kit alone: the protocol, the manifest, what a plugin can contribute and ask for, the
errors, versioning, how to test and publish. It describes what Vektor does, not what it might do one day. The step-by-step path
from an empty folder to a merged pull request is `CONTRIBUTING.md` (in the plugins repository); this is the reference you look things up in.

Contents: [Quick start](#quick-start) · [How a plugin runs](#how-a-plugin-runs) · [The wire](#the-wire) ·
[The manifest](#the-manifest) · [Settings](#settings) · [Contribution points](#contribution-points) ·
[Messages from Vektor](#messages-from-vektor) · [Messages from the plugin: services](#messages-from-the-plugin-services) ·
[View descriptions](#view-descriptions) · [Dialogs](#dialogs) · [Permissions](#permissions) · [Errors](#errors-and-limits) ·
[API versioning](#api-versioning) · [Writing the program](#writing-the-program) ·
[Compiled programs and signing](#compiled-programs-and-signing) · [Tools](#tools) · [Publishing](#publishing)

## Quick start

1. Get the tools ([Tools](#tools)) and copy a template: `cp -R templates/zsh ~/my-plugin` (or `templates/node`, `templates/swift`).
   Change `id`, `name`, `publisher` in `plugin.json`.
2. `vektor-plugin validate ~/my-plugin` — the manifest check Vektor itself makes.
3. `vektor-plugin test ~/my-plugin ~/my-plugin/test/checks.json` — a simulated Vektor.
4. In Vektor: Settings ▸ Plugins ▸ **Developer mode** on ▸ **Load Plugin from Folder…**. Editing `plugin.json` or the program
   reloads the plugin at once (menus, sidebar and views follow); an invalid manifest leaves it stopped with the reason in its
   **Log**; a change that adds permissions asks again.
5. Publish: `CONTRIBUTING.md` (in the plugins repository).

The complete examples are in `samples/`: `todo` (views, settings, state; `todo-node` is the same plugin in Node.js),
`cloudflare-tunnel` (processes, dialogs, secrets, a sidebar badge) and `folder-drive` (a location). Each has a README that says
what it demonstrates.

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

* `Content-Length` is the **byte** count of the body. A header larger than 1 KB, or a body larger than 1 MB, ends the plugin.
* Every message carries `"api": <number>` (this document: `1`).
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
| `contributes` | object | `commands`, `menus`, `views`, `sidebar`, `settingsTabs`; see [Contribution points](#contribution-points). |
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

A value that fails its rule (pattern, range) is never stored. A plugin may add a **status line** to a setting at any time with
`settings/status` (“cloudflared found”, tone `positive`).

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
`form`, `detail` or `toolbar`, declared here so what it may contain is known before it runs. A sidebar entry appears in the
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

## Messages from Vektor

| Method | Kind | `params` | You answer |
|---|---|---|---|
| `startup` | request | `vektorVersion`, `pluginID`, `previousSessionEndedUncleanly`, `sessionTemporaryFolder`, `dataFolder`, `settings`, `workspace` (`{id, name}` or null) | `{}` |
| `shutdown` | request | `reason` | `{}`, then exit |
| `invoke` | request | `command`, `target` | `{}` or `{"message": "shown as a short notice"}`; an `error` is shown as an alert |
| `settingsChanged` | notification | `settings`, `workspace` | — |
| `view/opened`, `view/closed` | notification | `view` | — (describe the view on `opened`) |
| `view/event` | notification | `view`, `action`, `card`?, `value`?, `field`?, `before`?, `index`?, `group`?, `revision`? | — (describe the view again) |
| `process/output` | notification | `processID`, `stream` (`stdout`/`stderr`), `text` (one line) | — |
| `process/exited` | notification | `processID`, `status` | — |
| `ping` | request | `{}` | `{}` |
| `$/cancel` | notification | `{"id": <request id>}` | — (stop that work) |

```json
{"api":1,"id":1,"method":"startup","params":{"vektorVersion":"1.0.0","pluginID":"com.example.hello","previousSessionEndedUncleanly":false,
 "sessionTemporaryFolder":"/…/session","dataFolder":"/…/data","settings":{"greeting":"Hello"},"workspace":{"id":"…","name":"Default"}}}
{"api":1,"id":2,"method":"invoke","params":{"command":"hello","target":{"menu":"fileItem","items":[{"path":"/Users/me/a.txt","name":"a.txt","isFolder":false}]}}}
```

`target` always has `menu`; it may also have `items` (paths — never file contents), `folder`, `connection` (`{id, kind}`, never a
secret), `website` (`{url, name}`), `text` (a terminal selection) and `entry` (the sidebar entry a menu belongs to).

`previousSessionEndedUncleanly: true` means Vektor was killed last time: Vektor already ended what was recorded; clean up what
only you know about (a remote resource you created). A `view/event`'s `revision` is the revision of the description the user was
looking at — compare it with yours to ignore an event made against a list that has since changed.

## Messages from the plugin: services

Each service is checked against what the user approved. A refusal comes back as an `error` in plain words.

| Method | Kind | `params` → result | Needs |
|---|---|---|---|
| `log` | notification | `level` (`info`, …), `message` → the plugin's Log | — |
| `toast` | notification | `message` → a short notice | — |
| `alert` | notification | `title`, `message` → an alert | — |
| `confirm` | request | `title`, `message`, `confirmTitle` → `{"confirmed": bool}` | — |
| `clipboard/writeText` | notification | `text` (≤ 1 MB) | — |
| `settings/get` | request | → `{"settings", "workspace"}` | — |
| `settings/status` | notification | `key`, `text`, `tone` (`positive`, `neutral`, `warning`, `error`), `detail`? — empty `text` clears | — |
| `dialog/show` | request | a [dialog](#dialogs) → `{"result": "submit"\|"cancel", "values": {…}}` | — |
| `view/update` | notification | `view`, `description` — the whole description | — |
| `sidebar/badge` | notification | `entry`, `count`? or `text`?, `tone`?, `symbol`?, `label`? — neither a count above zero nor a text clears it | — |
| `openURL` | request | `url` (http or https; opened in the default browser) | `openURLs` |
| `navigate` | request | `path`, `placement`? (`newTab`, `otherPane`) | — |
| `reveal` | request | `path` | — |
| `process/start` | request | `executable` (full path), `arguments`?, `environment`?, `workingDirectory`? → `{"processID"}` | `processes` |
| `process/stop` | request | `processID` | — |
| `secrets/read` | request | `key` → `{"value"}` | `secrets` |
| `secrets/write` | request | `key`, `value` (≤ 16 KB) | `secrets` |
| `secrets/delete` | request | `key` | `secrets` |

* **Processes service.** `process/start` runs a program for you in its own group, tracked per plugin; its output arrives as
  `process/output` lines and its end as `process/exited`. Vektor ends every one when the plugin stops. The program is checked
  first (see [Compiled programs](#compiled-programs-and-signing)); `DYLD_*` and `VEKTOR_*` environment values are dropped.
* **Secrets.** Stored in the keychain under the plugin's id. A value you read is removed from the Log automatically.
* `navigate` and `reveal` change what the user's pane shows; they are refused for a path that does not exist.

## View descriptions

A view is described by `view/update` — the **whole** description, every time; Vektor draws it natively. Send one when the view
opens (`view/opened`) and whenever something changes; the samples also send one right after `startup`, so a Settings tab and a
sidebar badge are ready before anyone opens a pane. Everything is clipped and capped (200 cards, 3 lines per card, 3
buttons, 12 menu items, titles to 120 characters); unknown fields are ignored. A description that cannot be shown is refused
with the reason in the Log.

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

* **`cardList`**: `"cards": [{"id", "symbol", "title", "pill": {"label","tone"}, "lines": ["text" | {"text","link"?}] (at most 3), "action"?,
  "buttons": [{"title","symbol","action","enabled"}], "menu": [{"title","symbol","action","destructive","enabled"} | {"separator": true}]}]`.
* **`list`**: `"list": {"input": {"placeholder","action"}, "reorder": "action", "groups": [{"id","title"?,"collapsible","startsCollapsed",
  "rows": [{"id","title","subtitle"?,"symbol"?,"checkbox": {"checked","action"}, "badge": {"label","tone"}, "edit": "action", "action"?, "delete": "action",
  "dimmed", "buttons": [], "menu": []}]}]}`. Events: the `input`'s action with `value` (the text); a checkbox's action with `card` and
  `value` (the new state); `edit` with `card` and `value`; `delete` with `card`; `reorder` with `card`, `before`, `index`, `group`.
* **`form`**: `"form": {"buttons": [], "sections": [{"id","title"?,"description"?,"fields": [{"key","kind": "text|toggle|choice|label|button","label","value","options"?,"help"?,"placeholder"?,"enabled"?,"action"?}]}]}`;
  a field's change arrives as its `action` (default `change`) with `field` and `value`; a `button` field sends its `action` (default its `key`).
* **`detail`**: `"detail": {"heading": {"title","subtitle"?,"symbol"?}, "rows": [{"label","value","link"?}], "markdown": "…", "actions": [{"title","symbol","action","enabled"}]}`.
  The Markdown is drawn by the same renderer as the Preview; remote images are not loaded.
* **`toolbar`**: only the `toolbar` object above.

Worked examples: `samples/todo/run.zsh` and `samples/todo-node/run.js` (`list` and `detail`) and `samples/cloudflare-tunnel/run.zsh` (`cardList`).

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
`readOnlyPath` (shown with the item's icon). The primary button stays disabled until required fields are valid. At most 30
fields and 6 sections. Only one dialog shows at a time.

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
* Limits: message body 1 MB; manifest 256 KB; a description is clipped as listed above; a secret 16 KB; clipboard 1 MB.

## API versioning

The manifest's `api` is the plugin API the plugin was written for; every message carries it. This Vektor speaks `api` 1. A plugin
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
  ([Compiled programs and signing](#compiled-programs-and-signing)); `templates/swift/build.sh` builds for arm64 (or a universal
  binary) and signs ad hoc.
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
  then the whole folder is.
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
and `vektor-registry` (the registry check). Nothing to build, nothing to install but the two files:

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
  `view/event`, `process/output`, `process/exited`, `$/cancel`); `"kind"` overrides.
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
* The test host does not simulate the Processes service (`process/start` is answered with `{}` unless you script it): test the
  logic around it, and use the real Vektor with Developer mode for the rest.

## Publishing

Zip the plugin folder, host the zip at an https address, and open a pull request against the plugins repository with
`plugins/<id>.json`. The automatic check (`vektor-registry check`) validates the manifest, downloads the package, compares its
SHA-256 and permissions with your entry and refuses id collisions. The whole path, step by step, and the entry format are in
`CONTRIBUTING.md` and `index.schema.json` of the plugins repository. Vektor shows the plugin in Get Plugins once the maintainer
has signed the new index.
