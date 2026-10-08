# Todo (sample plugin)

A todo list in a pane, written in zsh. It is a **complete, commented example**: read `run.zsh` from the top, the comments say
why each part is there.

What it shows:

| Feature | Where |
|---|---|
| The wire: `Content-Length` framing, requests, notifications, answers | `send`, `reply`, `refuse`, the main loop |
| Reading JSON in zsh (`plutil -extract`) and writing it by hand | `jx`, `j` |
| Settings of every scope: a toggle per workspace, a choice, a folder path | `plugin.json` ▸ `settings`, `load_settings` |
| A `list` view with a text input, checkboxes, in-place edit, delete, reorder, a collapsible group | `todos_json`, `row_json` |
| A `detail` view: heading, rows, Markdown, an action button | `summary_json` |
| Revisions: ignoring an event made against a view that has changed | `REVISION`, `move` in `on_event` |
| State in the data folder, written atomically | `save_todos` |
| Settings ▸ Plugins tabs and a sidebar entry for the same views | `plugin.json` ▸ `contributes` |

Run its scripted checks without Vektor, from this folder:

    vektor-plugin validate .
    vektor-plugin test . test/checks.json
