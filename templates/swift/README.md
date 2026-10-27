# Hello Plugin (Swift)

A template for a Vektor plugin written in Swift on the **Vektor SDK for Swift**, and **compiled**. Users of the plugin need
nothing installed; you need the macOS Command Line Tools (`xcode-select --install`) to build it. It shows the two things most
plugins do:

* **Say Hello** in the file context menu says how many items you chose, using the *Greeting* setting;
* **Hello** in the sidebar's Plugins section opens a small block view: type a name and press Return to add it, ⌫ removes it.
  The SDK sends the view as a whole the first time and as small patches after that.

## Use it

1. Copy this folder and give it a new `id` in `plugin.json` (reverse domain, lowercase: `com.yourname.thing`).
2. Edit `Sources/HelloPlugin/HelloPlugin.swift`: everything the plugin does is registered in `setup(_:)`.
   `docs/reference.md` in the plugins repository is the protocol; the SDK's sources (`sdk/swift`) document what it offers.
3. Build: `./build.sh`. It compiles the `hello` product for arm64, copies it to `bin/hello` and signs it with `codesign -s -`.
4. Check it: `vektor-plugin validate .`
5. Test it without Vektor: `vektor-plugin test . test/checks.json` (the built program), or `swift run hello-check` (the same
   script against the plugin in memory, with the SDK's test kit; no build or signature needed).
6. Try it in Vektor: Settings ▸ Plugins ▸ turn on **Developer mode**, **Load Plugin from Folder…**. Building again reloads it.
7. Publish it: see `CONTRIBUTING.md` in the plugins repository. Zip the folder **with the built `bin/hello` in it**; only
   `plugin.json`, `bin/`, `icon.svg` and `README.md` are needed — leave out `.build` (thousands of build files) and, if you
   like, `Sources`, `Package.swift` and `test`.

## The SDK

`Package.swift` takes the SDK from the plugins repository: the repository itself while this folder is inside a clone of it,
and by URL (`https://github.com/vektor-commander/vektor-plugins`, from the SDK version it names) once you copy the folder
elsewhere. Pin the version you tested with.

## Signing: ad hoc is enough

macOS kills an unsigned or modified compiled program silently. The linker signs an arm64 build ad hoc by itself, and `build.sh`
signs again with `codesign -s -` to be sure. That is all: **no Developer ID, no notarization.** Vektor refuses to install a
package whose compiled program does not carry a valid signature, and `vektor-plugin validate` tells you first. Sign after the last
change: touching the file afterwards invalidates the signature.

## Apple silicon only

`./build.sh` makes an **arm64** program. Vektor runs only on Apple silicon, so there is no Intel build to make.

## A downloaded folder

A compiled program that came from the internet through a browser carries a quarantine mark, and macOS raises an alert for every
start. Vektor refuses it; remove the mark once: `xattr -dr com.apple.quarantine <folder>`. A zip downloaded with `curl` has none.
