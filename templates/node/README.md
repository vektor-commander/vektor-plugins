# Hello Plugin (Node)

A template for a Vektor plugin written in Node.js on the **Vektor SDK for Node** (in `vektor-sdk/`: plain JavaScript, no
npm packages, nothing to install but Node itself). It shows the two things most plugins do:

* **Say Hello** in the file context menu says how many items you chose, using the *Greeting* setting;
* **Hello** in the sidebar's Plugins section opens a small block view: type a name and press Return to add it, ⌫ removes it.
  The SDK sends the view as a whole the first time and as small patches after that.

## Before you start

* Install Node.js yourself (nodejs.org, or `brew install node`). macOS does not ship it, and neither does Vektor.
* Vektor gives plugins a fixed `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`). A Node installed with
  nvm, fnm or Volta lives elsewhere and `#!/usr/bin/env node` will not find it, in Vektor or in `vektor-plugin test`. Install a
  copy in one of those folders (Homebrew does).
* Tell your users: the setting banner in `plugin.json` says "needs Node.js" with a link. Keep it.

## Use it

1. Copy this folder and give it a new `id` in `plugin.json` (reverse domain, lowercase: `com.yourname.thing`).
2. Edit `run.js`. Everything the plugin does is registered in `setup(plugin)`; `docs/reference.md` in the plugins repository is
   the protocol, and `vektor-sdk/*.d.ts` lists what the SDK offers (block builders, views, storage, sync, web bridge).
3. Check it: `vektor-plugin validate .`
4. Test it without Vektor: `vektor-plugin test . test/checks.json`, or `node --test` here — the SDK's test kit plays the same
   `checks.json` with the plugin in memory (that also works where Node comes from nvm), and `test/run.test.js` shows a test of
   your own.
5. Try it in Vektor: Settings ▸ Plugins ▸ turn on **Developer mode**, **Load Plugin from Folder…**. Edits to `plugin.json` or
   `run.js` reload the plugin at once.
6. Publish it: see `CONTRIBUTING.md` in the plugins repository. Ship the `vektor-sdk` folder with the plugin (a plugin can load
   files only from its own folder); `test/` is optional.

## The SDK copy

`vektor-sdk/` is the compiled SDK from `sdk/node` of the plugins repository (`sdk/node/build.sh` refreshes it there). To update
a plugin to a newer SDK, replace the folder with the newer one. Its version is in `vektor-sdk/version.js`.
