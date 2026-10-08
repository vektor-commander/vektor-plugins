# Cloudflare Tunnel (sample plugin)

Publishes a file, a folder or a local port under a public Cloudflare address using your own `cloudflared`. Written in zsh; a
**complete, commented example** — read `run.zsh` from the top.

What it shows:

| Feature | Where |
|---|---|
| Starting and stopping other programs through the **Processes service**, so Vektor ends them with the plugin | `start_tunnel`, `stop_children`, `on_output` |
| Dialogs: `dialog/show` with forms and an "Advanced" section, answered later | `show_publish_dialog`, `on_dialog_answer` |
| A `cardList` view with buttons, a menu and links; a sidebar badge | `push_view`, `on_view_event` |
| Menu commands on files and on the sidebar (`applies`, `menus`) | `plugin.json` ▸ `contributes` |
| Secrets (an API token kept in the keychain) and a path setting with a banner | `plugin.json` ▸ `settings` |
| Setting statuses (`settings/status`): "cloudflared found / not found" | `publish_cloudflared_status` |
| Clean shutdown: nothing it started outlives it | `cleanup` |

`serve.zsh` is the small local file server it starts for a published folder.

The scripted checks (`test/checks.json`) use a stand-in for `cloudflared` and never contact Cloudflare. The test host does not
simulate the Processes service, so they stop at the dialog; the full flow is tried in Vektor itself. From this folder:

    vektor-plugin validate .
    vektor-plugin test . test/checks.json
