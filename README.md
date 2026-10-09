# Vektor plugins

The public plugin registry for Vektor, and everything a developer needs to write a plugin for it. This README has two parts:
[for people who use plugins](#for-people-who-use-plugins) and [for people who write them](#for-people-who-write-plugins).

## For people who use plugins

Open **Vektor ▸ Settings ▸ Plugins ▸ Get Plugins**. That is the only time Vektor looks at this registry.

* The registry is two files in this repository: `index.json` (the list of plugins) and `index.json.sig` (its signature). Vektor
  refuses the list unless the signature verifies with the key built into Vektor, so nobody can change the list by editing a file
  on GitHub or in transit.
* A plugin is installed only if the SHA-256 of its package equals the one in the signed list. A package that was swapped is
  refused.
* **Nothing runs when you install.** A new plugin arrives turned off and shows you, in plain words, what it asks to do (run
  programs, use the network, read the files you choose, …). It starts only after you approve that.
* A plugin the maintainers revoke is turned off in your Vektor the next time you open Get Plugins or check for updates, with the
  reason shown.
* Plugins are small programs running on your Mac with the permissions you approved. Install the ones you trust, as with any
  program. Plugins written by other people are reviewed before they are listed, not audited line by line.

The project website lists the same plugins by reading `index.json`.

## For people who write plugins

You can write a plugin, test it and submit it without ever seeing Vektor's source code. Everything is here:

| What | Where |
|---|---|
| The whole path, step by step | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| The protocol and manifest reference | [`docs/reference.md`](docs/reference.md) |
| Templates: zsh, Node.js, Swift (compiled) | [`templates/`](templates) |
| Complete samples (a list view, a tunnel, a location, Todo in Node) | [`samples/`](samples) |
| An example registry entry | [`examples/plugins/`](examples/plugins) |
| The entry schema | [`index.schema.json`](index.schema.json) |
| The tools (`vektor-plugin`, `vektor-registry`) | the newest `tools-*` release of this repository |

The short path:

1. Download the tools from the Releases page, and copy a template: `cp -R templates/node ~/my-plugin` (or `zsh`, `swift`).
2. Edit `plugin.json` and the program. Check with `vektor-plugin validate ~/my-plugin`, test with
   `vektor-plugin test ~/my-plugin ~/my-plugin/test/checks.json`, and try it in Vektor with **Settings ▸ Plugins ▸ Developer mode ▸
   Load Plugin from Folder…**.
3. Zip it, host the zip at an https address, and add `plugins/<id>.json` (id, permissions equal to the manifest, the zip's URL and
   its SHA-256).
4. Run `vektor-registry check . --plugin <id>`, then open a pull request. The maintainer reviews it; after merging, the maintainer
   signs the new index.

Plugins never need an Apple Developer ID or notarization. Scripts need nothing at all; a compiled program needs only the ad-hoc
signature most compilers add (`codesign -s -` otherwise). Node.js is not installed by macOS, so a Node plugin tells its users to
install it. Python is not offered: it is not on every Mac. [`CONTRIBUTING.md`](CONTRIBUTING.md) explains each of these.

## What is in this repository

```
plugins/<id>.json       one file per plugin: what an author submits by pull request
packages/<id>/          zips, icons and READMEs of first-party plugins (Cloudflare Tunnel), served from raw.githubusercontent.com
revoked.json            versions that must not be installed: [{ "id", "version", "reason" }]
index.json              generated: vektor-registry build        (maintainer, after merging)
index.json.sig          generated: vektor-registry sign         (maintainer; the private key stays on their Mac)
index.schema.json       the JSON Schema of an entry and of the index
docs/reference.md       the plugin reference
templates/              zsh, node, swift
samples/                larger examples, each with test/checks.json
examples/               an example registry entry
ci/                     the pull-request check as a GitHub Actions workflow plus its scripts (not armed yet)
CONTRIBUTING.md         the author path
```

### The tools

| Command | What it does |
|---|---|
| `vektor-plugin validate <folder>` | the manifest and program check Vektor itself makes, plus advice |
| `vektor-plugin test <folder> <script.json>` | a simulated Vektor drives your plugin through a JSON script |
| `vektor-registry check <folder> [--plugin id]… [--all-versions]` | the pull-request check |
| `vektor-registry build <folder>` | merges the entries and revocations into `index.json` (maintainer) |
| `vektor-registry sign <folder> --key <file>` | writes `index.json.sig` (maintainer) |
| `vektor-registry verify <folder> --public-key <key>` | checks the signature the way Vektor does (maintainer) |

### Maintainer notes

After merging a pull request: `vektor-registry build .`, `vektor-registry check .`, `vektor-registry sign . --key ~/keys/vektor-registry.key`,
`vektor-registry verify . --public-key <the key built into Vektor>`, then commit `index.json` and `index.json.sig` together.
**Revoking** a version is a line in `revoked.json` (with a reason in plain words), then build and sign again.

The pull-request workflow in `ci/` is not active yet: it needs the tools release published and its SHA-256 written into
`ci/pull-request-check.yml` (`TOOL_SHA256` holds a placeholder that the scripts refuse). Details in `CONTRIBUTING.md`.
