# Hello Plugin (Node)

A template for a Vektor plugin written in Node.js, with no npm packages. **Say Hello** appears in the file context menu and says
how many items you chose, using the *Greeting* setting.

## Before you start

* Install Node.js yourself (nodejs.org, or `brew install node`). macOS does not ship it, and neither does Vektor.
* Vektor gives plugins a fixed `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`). A Node installed with
  nvm, fnm or Volta lives elsewhere and `#!/usr/bin/env node` will not find it, in Vektor or in `vektor-plugin test`. Install a
  copy in one of those folders (Homebrew does).
* Tell your users: the setting banner in `plugin.json` says "needs Node.js" with a link. Keep it.

## Use it

1. Copy this folder and give it a new `id` in `plugin.json` (reverse domain, lowercase: `com.yourname.thing`).
2. Edit `run.js`. `docs/reference.md` in the plugins repository lists every message, setting kind and contribution point.
3. Check it: `vektor-plugin validate .`
4. Test it without Vektor: `vektor-plugin test . test/checks.json`
5. Try it in Vektor: Settings ▸ Plugins ▸ turn on **Developer mode**, **Load Plugin from Folder…**. Edits to `plugin.json` or
   `run.js` reload the plugin at once.
6. Publish it: see `CONTRIBUTING.md` in the plugins repository.

`run.js` has the three Node traps in its header: byte counts for `Content-Length` (`Buffer`), nothing but messages on stdout, and
exit after answering `shutdown`.
