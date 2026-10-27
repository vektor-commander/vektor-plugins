# Todo (Node) (sample plugin)

The Todo sample, written in Node.js instead of zsh: same views, same settings, same scripted checks, same list file format. It is
a **complete, commented example** of a Node plugin written on the [Node SDK](../../docs/sdk-node.md) (`vektor-sdk/` is a copy of
it, because a plugin may only load files from its own folder): read `run.js` from the top.

**Needs Node.js**, which you install yourself (nodejs.org, or `brew install node`). Vektor gives plugins a fixed `PATH`, so a Node
managed by nvm, fnm or Volta is not found. No npm packages are used.

What it shows:

| Feature | Where |
|---|---|
| What the SDK does for you: framing by **bytes**, nothing but messages on stdout, `ping`, `shutdown` answered and then the exit | `vektor-sdk/` |
| Lifecycle hooks: load on `startup`, describe the views once it is answered, apply `settingsChanged`, tidy up on shutdown | `setup` at the end |
| Settings of every scope: a toggle per workspace, a choice, a folder path | `plugin.json` ▸ `settings`, `loadSettings` |
| A `list` view with a text input, checkboxes, in-place edit, delete, reorder, a collapsible group | `todosJSON`, `rowJSON` |
| A `detail` view: heading, rows, Markdown, an action button | `summaryJSON` |
| Revisions: ignoring an event made against a view that has changed | `todosView.on('move', …, { stale: 'deliver' })` |
| State only in the data folder (`$VEKTOR_PLUGIN_DATA`), written atomically | `saveTodos` |
| A setting banner telling the user to install the runtime | `plugin.json` ▸ `settings` |

Run its scripted checks without Vektor, from this folder:

    vektor-plugin validate .
    vektor-plugin test . test/checks.json
