# Writing and submitting a Vektor plugin

Everything you need is in this repository and its Releases: the reference, templates, samples and the two command-line tools. You
never need access to Vektor's source code. This page is the whole path:

1. [Get the tools](#1-get-the-tools)
2. [Write the plugin](#2-write-the-plugin) (zsh, Node.js or Swift)
3. [Test it](#3-test-it) with `vektor-plugin`, then in Vektor's Developer mode
4. [Package it](#4-package-it) as a zip at an https address, with its SHA-256
5. [Write the registry entry](#5-write-the-registry-entry) (`plugins/<id>.json`)
6. [Check it yourself](#6-check-it-yourself) with `vektor-registry check`
7. [Open a pull request](#7-open-a-pull-request), and what the review does
8. [Updates and revocation](#8-updates-and-revocation)

The reference for every message, manifest field, setting and permission is [`docs/reference.md`](docs/reference.md).

## 1. Get the tools

The **tools release** of this repository (a release tagged `tools-<version>`; use the newest) carries one file,
`vektor-plugin-tools-macos.zip`, with two programs built from the same source as Vektor's own plugin code:

* `vektor-plugin` — `validate` (the exact manifest check Vektor makes) and `test` (a simulated Vektor that talks to your plugin
  over its real protocol, from a JSON script);
* `vektor-registry` — `check` (what the pull-request check runs on your entry).

Nothing to build and no Xcode:

    curl -fLO https://github.com/vektor-commander/vektor-plugins/releases/download/tools-<version>/vektor-plugin-tools-macos.zip
    unzip vektor-plugin-tools-macos.zip -d ~/vektor-tools

The programs are **ad-hoc signed and not notarized** (no Apple developer account is involved anywhere in this project). `curl`
adds no quarantine mark, so they just run. If you download the zip in a browser, macOS marks the files as downloaded and refuses
to open them; remove the mark once:

    xattr -d com.apple.quarantine ~/vektor-tools/vektor-plugin ~/vektor-tools/vektor-registry

The examples below write `vektor-plugin` and `vektor-registry`; put `~/vektor-tools` on your `PATH` or type the full path.

## 2. Write the plugin

A plugin is a folder with a `plugin.json` (what it is, what it contributes, what it may do) and a program that Vektor starts when
it is needed and talks to over stdin and stdout. Start from a template:

| Language | Template | The user must install | Notes |
|---|---|---|---|
| zsh | [`templates/zsh`](templates/zsh) | nothing (zsh is on every Mac) | JSON is awkward in a shell; fine for small plugins |
| Node.js | [`templates/node`](templates/node) | **Node.js** | no npm packages; see the runtime note below |
| Swift (compiled) | [`templates/swift`](templates/swift) | nothing | you need the Command Line Tools to build; ad-hoc signed by `build.sh` |

Copy one to a folder of your own and change `id` (reverse domain, lowercase: `com.yourname.thing`), `name` and `publisher`:

    cp -R templates/node ~/my-plugin

There is **no Python template**, on purpose: Python is not part of macOS (on a Mac without the Command Line Tools, `python3`
opens an installer prompt), so a Python plugin would fail on many users' Macs. If you want Python-like convenience, use Node, or
ship a compiled program.

**Larger examples** in [`samples/`](samples): `todo` and `todo-node` (a list view, settings, a detail view, state in the data
folder), `cloudflare-tunnel` (starts programs, dialogs, secrets, a sidebar badge), `folder-drive` (a location that Vektor
browses like a drive). Each README says what it demonstrates.

### Runtimes: Node.js and friends

Vektor gives a plugin a **fixed `PATH`**: `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`. So:

* The user has to install Node themselves (nodejs.org, or `brew install node`). **Say so in the plugin**: the templates put a
  `banner` (a note with a link) on the plugin's first setting, and your README should say it too.
* Node installed by **nvm, fnm or Volta lives elsewhere**, so `#!/usr/bin/env node` does not find it, in Vektor or in
  `vektor-plugin test`. Tell users to install a copy Homebrew or the nodejs.org installer would (it lands in a folder on the list).
  `vektor-plugin validate` warns, and `vektor-plugin test` stops with an explanation, when the interpreter on the first line is not
  found.

### The rules every plugin follows

* `Content-Length` is a **byte** count. In Node use `Buffer`; in zsh set `LC_ALL=C`.
* stdout is for messages only. Log to stderr or send a `log` message.
* Answer `shutdown` and exit. Stop everything you started. Write only to `$VEKTOR_PLUGIN_DATA`, never into the plugin's folder.
* Ask for the permissions you use and no more: the pull-request check requires the entry's permissions to equal the manifest's.

## 3. Test it

    vektor-plugin validate ~/my-plugin
    vektor-plugin test ~/my-plugin ~/my-plugin/test/checks.json

`validate` reports what Vektor would refuse (errors) and what a good plugin should have (warnings: icon, README, license). `test`
plays the script in `test/checks.json` (see "The test host" in the reference) against your program: it sends `startup`, `invoke`,
`view/event` and so on, and checks what comes back. Every template and sample here has a `test/checks.json` that passes. The test
host does not simulate the Processes service, so test the logic around it and try the rest in Vektor.

Then try it in the real thing: Vektor ▸ Settings ▸ Plugins ▸ turn **Developer mode** on ▸ **Load Plugin from Folder…**. Edits to
`plugin.json` or the program reload the plugin at once; a broken manifest leaves it stopped with the reason in its **Log**. Vektor
asks you to approve its permissions before it first runs.

### Signing and the quarantine mark

* **Scripts need nothing**: no signature, and the quarantine mark does not matter for a script or a data file. A plugin folder
  you downloaded in a browser loads.
* **A compiled program** must carry a valid signature, or macOS kills it silently. The **ad-hoc** signature most compilers add
  (or `codesign -s - path/to/program`) is enough. **No Developer ID, no notarization.** Sign after your last change.
* A compiled program that came through a browser carries the quarantine mark, and macOS raises an alert for every start; Vektor
  refuses it. Remove the mark once: `xattr -dr com.apple.quarantine <folder>`. (`curl` adds none.) A plugin installed from the
  registry never has it: Vektor checks the package's SHA-256 against the signed index first.

## 4. Package it

Zip the **contents** of the folder (the zip has `plugin.json` at its top, or inside one single folder), host the zip at an
**https** address, and compute the SHA-256:

    cd ~/my-plugin && zip -r -X ../my-plugin-0.1.0.zip . -x '.*' && cd ..
    shasum -a 256 my-plugin-0.1.0.zip

A GitHub release asset of your own repository is a good home (`https://github.com/you/my-plugin/releases/download/v0.1.0/my-plugin-0.1.0.zip`).
Do not change a published zip: its hash is in the signed index. A new build is a new version and a new file.

## 5. Write the registry entry

Add `plugins/<id>.json` (the file name is the plugin id). [`index.schema.json`](index.schema.json) is the schema; the
[Cloudflare Tunnel entry](plugins/com.vektor-commander.cloudflare-tunnel.json) is a real one, and
[`examples/plugins/com.example.hello.json`](examples/plugins/com.example.hello.json) is a small commented-by-name one.

| Field | Meaning |
|---|---|
| `id`, `name`, `publisher`, `summary`, `description` | as in your `plugin.json`; the summary is one sentence |
| `categories` | up to 8 short words (40 characters each); they become the filter chips in Get Plugins, so reuse existing ones such as `Developer` or `Sharing` |
| `icon`, `readme` | https addresses of the icon (SVG or PNG, at most 512 KB) and the README (Markdown, at most 256 KB) |
| `homepage`, `repository`, `license` | optional but expected |
| `permissions` | **exactly the permissions in your `plugin.json`** — the check compares them |
| `screenshots`, `images` | `screenshots` are shown on the detail page; `images` lists the **only** remote images a README may show: one that is not listed is not loaded |
| `versions` | `version`, `api` (`1`), `minVektor`, `url` (the https zip), `sha256` (lowercase hex of that zip), `changelog` |

Every address is https. Permissions are shown to users in plain words before they install, so ask for what you need.

## 6. Check it yourself

From a clone of this repository with your entry in `plugins/`:

    vektor-registry check . --plugin com.yourname.thing

It validates the manifest, downloads the package, compares the SHA-256 and the permissions with your entry, and refuses id
collisions. This is the same check the pull request runs.

## 7. Open a pull request

Fork this repository, add `plugins/<id>.json` (and, if you like, your plugin's icon and README under a place you host yourself),
and open a pull request. The automatic check runs `vektor-registry check` on the entries you changed. A pull request that also
touches `ci/` or `.github/` needs the maintainer and is not merged by the check.

The maintainer reads the entry and, if needed, the package: does the plugin do what the description says, does it ask for more than
it needs, does it write only where it should. After merging, the maintainer builds `index.json` and **signs it with the registry
key**. Vektor accepts nothing that is not in the signed index; you do not sign anything. The plugin appears in Get Plugins once the
signed index is published.

## 8. Updates and revocation

* **A new version** is a new object in your entry's `versions` (higher `version`, its own `url` and `sha256`, a `changelog`), in a
  pull request. If the new version needs a permission the old one did not, the user is asked again before it runs. Vektor keeps
  the user's settings and data across updates (`$VEKTOR_PLUGIN_DATA`).
* **Revocation**: a version that must not be installed any more is listed in `revoked.json` with a reason in plain words. Vektor
  turns an installed revoked version off the next time its owner opens Get Plugins or checks for updates. Open a pull request or
  an issue for your own plugin; the maintainer may revoke a version for safety.
* **Removal**: deleting your entry removes the plugin from the registry; the maintainer must approve it.

## For the maintainer

* After merging: `vektor-registry build .`, `vektor-registry check .`, `vektor-registry sign . --key <key file>`,
  `vektor-registry verify . --public-key <the key built into Vektor>`; commit `index.json` and `index.json.sig` together. `sign`
  refuses a key inside a Git repository or readable by other users.
* The pull-request check is the workflow in `ci/pull-request-check.yml` with its scripts. It is **not armed yet**: it needs the
  tools release published and its SHA-256 written into the workflow (`TOOL_SHA256` still holds a placeholder, and the scripts refuse
  to run with it). Then copy the workflow to `.github/workflows/`. The workflow downloads the release asset, compares its SHA-256
  before opening it, and runs `vektor-registry check` on the entries the pull request changed. To try it on your Mac without GitHub:
  `ci/run-check-locally.sh <registry clone> origin/main <branch> --tool <zip> --sha <hash>`.
