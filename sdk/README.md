# Vektor plugin SDK

Libraries for writing Vektor plugins in **Swift** and **Node.js**, and a helper file for **zsh**. Everything a plugin does is plain protocol
([`docs/reference.md`](../docs/reference.md)); the SDK adds types and does the parts every plugin gets wrong once.

| | Swift | Node.js |
|---|---|---|
| Where | [`sdk/swift`](swift) (SwiftPM; the repository's root `Package.swift` exposes it by URL) | [`sdk/node`](node) (TypeScript in `src/`, compiled JavaScript in `dist/`) |
| Library | `VektorPlugin` | `dist/index.js` |
| Test kit | `VektorPluginTestKit` | `dist/testkit.js` |
| Its tests | `swift run vektor-sdk-tests` in `sdk/swift` | `npm test` (or `node --test test/*.test.js`) in `sdk/node` |
| Template | [`templates/swift`](../templates/swift) | [`templates/node`](../templates/node) (carries a copy in `vektor-sdk/`) |
| Runtime dependencies | none (Foundation) | none (Node's own modules) |
| Guide | [`docs/sdk-swift.md`](../docs/sdk-swift.md) | [`docs/sdk-node.md`](../docs/sdk-node.md) |

zsh has no SDK (no nested data, no JSON parser): [`sdk/zsh/vektor.zsh`](zsh/vektor.zsh) is one file a plugin copies, with framing
by bytes, JSON escaping, field reads, the message loop and small block functions; see [`docs/sdk-zsh.md`](../docs/sdk-zsh.md).

## Versions

The SDK is versioned on its own, not with Vektor.

| SDK | Plugin API it targets | Oldest Vektor it needs |
|---|---|---|
| 0.1.0 | 2 (block views, patches, sidebar items, workspace changes, storage places, web views) | 1.0.0 |

The same numbers are in the code (`SDK.version`, `SDK.pluginAPI`, `SDK.minVektor` in Swift; `SDK_VERSION`, `PLUGIN_API`,
`MIN_VEKTOR` in Node). A plugin built on it still declares its own `api` and `minVektor` in `plugin.json`; an `"api": 1` plugin
can use the SDK too (it answers in the API the plugin's manifest declares), as long as it uses nothing of API 2.

## What is in it

* **Protocol core**: `Content-Length` framing by bytes (a header split across reads, multi-byte UTF-8, the 1 KB header limit),
  requests with ids and timeouts, notifications, `$/cancel`, `ping`, `startup` state, `shutdown` with the grace period, end of
  input, errors in plain words. stdout carries only messages; the SDK's own diagnostics go to stderr.
* **Typed messages** for every method of the reference, both directions.
* **Block builders** for every block of the reference and the colour roles (never a colour value), producing exactly the
  documented JSON; `validateBlocks` checks a tree the way Vektor does before it is sent.
* **View state**: the current description and its revision; `show` sends a patch when one says the change (computed by id,
  checked to rebuild the new tree exactly) and the whole description otherwise; events routed by action, stale moves ignored;
  a refusal from Vektor (`view/refused`) answered with the whole description. Block widths (`width`, `minWidth`, `maxWidth`,
  `grow`) checked against the range Vektor reads.
* **Sidebar items** and **workspaces**: items re-sent after a workspace switch; one value per workspace on disk.
* **Storage**: JSON documents with versions, `writeIfUnchanged` returning a typed `Conflict` with both versions, paged listing,
  large files in parts. **Sync**: a three-way merge of records by id and `updatedAt` that reports conflicts and never resolves
  them for you.
* **Web views**: the plugin side (`plugin.web(view)`), the page side ([`sdk/web/vektor-bridge.js`](web/vektor-bridge.js)) and a
  starter stylesheet on the theme's CSS properties ([`sdk/web/vektor.css`](web/vektor.css)). Copy both into the plugin's folder.
* **Test kit**: an in-memory Vektor stand-in (startup, view events, refusals, storage on a temporary folder, shutdown) for any test
  runner, which also plays `test/checks.json` scripts the way `vektor-plugin test` does.

* **Layouts** ([`docs/sdk-layouts.md`](../docs/sdk-layouts.md)): a board, a list with detail, a table with toolbar, a settings form and
  a card list, each a function or type that returns blocks plus a `route…` function that sends its events to typed callbacks.
  Written to be copied and adapted.

`sdk/fixtures/blocks.json` holds the JSON every builder must produce and `sdk/fixtures/layouts.json` the JSON every layout must
build; both SDKs' tests build against them (the zsh helper's tests use `blocks.json` too).

## Building

* Swift: nothing to do; SwiftPM builds it with the plugin. Command Line Tools are enough (no Xcode).
* Node: `dist/` is committed. After changing `src/`, run `./build.sh` in `sdk/node` (it needs TypeScript: `npm install` there
  first, or `TSC=/path/to/tsc`; the committed `dist/` was built with TypeScript 7.0.2, which reproduces it byte for byte —
  older compilers write different helpers); it also refreshes the copies in `templates/node/vektor-sdk` and `samples/todo-node/vektor-sdk`.
* zsh: `sdk/zsh/sync.sh` copies `vektor.zsh` into `templates/zsh` and `samples/todo`. Tests: `vektor-plugin test sdk/zsh/test sdk/zsh/test/checks.json`
  (or `zsh sdk/zsh/test/selftest.zsh` alone).

## Adding to it

Layouts composed from blocks live in their own files beside the builders — `sdk/node/src/layouts/` (exported from `src/index.ts`) and
`sdk/swift/Sources/VektorPlugin/Layouts/` — returning blocks and routing their events through `ViewState.on`. A new layout gets a
case in `sdk/fixtures/layouts.json` (`WRITE_FIXTURES=1 node --test test/layouts.test.js` in `sdk/node` rewrites it from the Node
layouts: read the diff) and the same case in the Swift tests, so both languages stay alike. New block fields go into the builders
and into `sdk/fixtures/blocks.json`. A change to `sdk/zsh/vektor.zsh` is followed by `sdk/zsh/sync.sh`.
