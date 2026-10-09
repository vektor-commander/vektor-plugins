# Folder Drive (sample location plugin)

A **location** plugin written in zsh: each connection is a folder under `/tmp` that Vektor browses in a pane like S3 or SFTP.
It never touches a network, so it is safe to try and to run in automated checks. It is a **complete, commented example**: read
`run.zsh` from the top. To make your own (WebDAV, a cloud drive), keep the wire code and replace the `serve_*` functions.

What it shows:

| Feature | Where |
|---|---|
| Declaring a location: scheme, symbol, connection form, capabilities | `plugin.json` ▸ `contributes.locations` |
| A connection form with an ordinary field (`root`) and a secret (`accessCode`, kept in the keychain) | `plugin.json`, `location/connect` |
| Capabilities Vektor reads everywhere: **no trash** (so Vektor confirms every delete), no share, hidden dot files | `plugin.json` |
| A second, read-only location of the same plugin, told apart by `connection.type` | `readonly` in `plugin.json`, `KIND` |
| Paged listing with a cursor | `serve_list` |
| Reading and writing **files Vektor names** (never file bytes on the pipe); writes land atomically | `serve_read`, `serve_write` |
| New folder, rename, move within the connection, recursive delete; names that already exist are refused | `serve_createFolder` …`serve_delete` |
| Keeping every path inside the connection's folder: empty, `.` and `..` components and links that point out are refused, and a change (delete, rename, move) acts on a link itself, never on what it points to | `resolve` |
| Answering a failure in a sentence a person can read | `refuse` |

`location/connect` is the only request that carries the secret. This sample asks for one only when the folder holds a
`.access-code` file; the code must match its first line.

Every request is appended to `audit.log` in the plugin's data folder (`$VEKTOR_PLUGIN_DATA`), method and path only, never a
secret, so you can see what Vektor asked of the plugin. It declares no change feed: panes list again when Vektor itself changes
a folder, or on Refresh.

Try it in Vektor: Settings ▸ Plugins ▸ turn on **Developer mode** ▸ **Load Plugin from Folder…**, approve “Provide a location”, then Settings ▸ Connections ▸ Plugin
locations ▸ Add. Its scripted checks (`test/checks.json`) cover connecting, listing and refusing a path that leaves the connection; the rest is exercised through Vektor.
