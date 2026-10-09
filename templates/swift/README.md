# Hello Plugin (Swift)

A template for a Vektor plugin written in Swift and **compiled**. Users of the plugin need nothing installed; you need the macOS
Command Line Tools (`xcode-select --install`) to build it. **Say Hello** appears in the file context menu and says how many items
you chose, using the *Greeting* setting.

## Use it

1. Copy this folder and give it a new `id` in `plugin.json` (reverse domain, lowercase: `com.yourname.thing`).
2. Edit `Sources/main.swift`, then build: `./build.sh`. It compiles for arm64 (`-target arm64-apple-macos13`), writes `bin/hello`
   and signs it with `codesign -s -`.
3. Check it: `vektor-plugin validate .`
4. Test it without Vektor: `vektor-plugin test . test/checks.json`
5. Try it in Vektor: Settings ▸ Plugins ▸ turn on **Developer mode**, **Load Plugin from Folder…**. Building again reloads it.
6. Publish it: see `CONTRIBUTING.md` in the plugins repository. Zip the folder **with the built `bin/hello` in it**; only
   `plugin.json`, `bin/`, `icon.svg` and `README.md` are needed (leave `Sources` out if you do not want to ship it).

## Signing: ad hoc is enough

macOS kills an unsigned or modified compiled program silently. The linker signs an arm64 build ad hoc by itself, and `build.sh`
signs again with `codesign -s -` to be sure. That is all: **no Developer ID, no notarization.** Vektor refuses to install a
package whose compiled program does not carry a valid signature, and `vektor-plugin validate` tells you first. Sign after the last
change: touching the file afterwards invalidates the signature.

## One architecture or both

`./build.sh` makes an **arm64** program (Apple silicon), which is what the registry's check runs on. For Macs of both kinds:

    ./build.sh universal

which builds arm64 and x86_64 and joins them with `lipo` into one `bin/hello`, then signs it. Say in your README which you ship.

## A downloaded folder

A compiled program that came from the internet through a browser carries a quarantine mark, and macOS raises an alert for every
start. Vektor refuses it; remove the mark once: `xattr -dr com.apple.quarantine <folder>`. A zip downloaded with `curl` has none.
