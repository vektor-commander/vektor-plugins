# Hello Plugin

A template for a Vektor plugin written in zsh. **Say Hello** appears in the file context menu and says how many items you
chose, using the *Greeting* setting.

It uses `vektor.zsh`, the zsh helper (a copy of `sdk/zsh/vektor.zsh` of the plugins repository, because a plugin may only load
files from its own folder): framing by bytes, JSON escaping, reading fields, the message loop and small block functions. See
`docs/sdk-zsh.md` for what it offers and for when to move to Swift or Node.

## Use it

1. Copy this folder and give it a new `id` in `plugin.json` (reverse domain, lowercase: `com.yourname.thing`).
2. Edit `run.zsh`. The reference (`docs/reference.md` in the plugins repository) lists every message, setting kind and contribution point.
3. Check it: `vektor-plugin validate .`
4. Test it without Vektor: `vektor-plugin test . test/checks.json`
5. Try it in Vektor: Settings ▸ Plugins ▸ turn on **Developer mode**, **Load Plugin from Folder…**. Edits to `plugin.json` or
   `run.zsh` reload the plugin at once.
6. Publish it: see `CONTRIBUTING.md`.
