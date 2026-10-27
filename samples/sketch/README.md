# Sketch (sample plugin)

A drawing canvas in a pane — the example of a **web view**: a page made of the plugin's own files, shown by Vektor in a
sandbox. Written in zsh (the plugin) and plain HTML, CSS and JavaScript (the page).

**Prefer native blocks.** A `blocks` view is drawn by Vektor, so its keys, accessibility and theme are Vektor's by
construction. Choose a web view only for what blocks cannot draw — a canvas, a diagram editor, an existing web UI.

What it shows:

| Feature | Where |
|---|---|
| A `web` view declared in the manifest, opened from a sidebar entry | `plugin.json` ▸ `contributes` |
| The page talking to its plugin: `vektor.post(…)` and `vektor.onmessage` | `web/app.js` |
| The plugin answering with `web/post`, and keeping the drawing in its data folder | `run.zsh` ▸ `on_message`, `save` |
| Looking like Vektor in every theme: the `--vektor-…` properties and the starter stylesheet | `web/vektor.css` |
| Following a theme change live: the `vektor-theme` event | `web/app.js` |
| Colours by role, never by value: a stroke stores `accent` or `label3`, and redraws in the theme's colour | `web/app.js` |
| A link opening in the browser (the `openURLs` permission) | `web/index.html` |

What the page cannot do — on purpose: load anything from the network, read a file outside the plugin folder, open a window,
download, use the camera or microphone, or talk to anything but its own plugin. Keep data in the plugin (its data folder),
never in the page: a page's storage is not kept.

Run its scripted checks without Vektor, from this folder:

    vektor-plugin validate .
    vektor-plugin test . test/checks.json
