# The zsh helper

zsh is on every Mac, so a zsh plugin needs nothing installed and nothing built. It is also a shell: no nested data, no JSON
parser, strings that count characters, one thing at a time. A typed SDK is not possible there. **`sdk/zsh/vektor.zsh`** is one
file you copy into your plugin that removes the parts that are error-prone to write by hand — and nothing more. Its tests run
through `vektor-plugin test` ([Testing](#testing)).

It needs nothing but what macOS ships: `zsh` and `plutil`.

## Start

Copy the template (`cp -R templates/zsh ~/my-plugin`; it already carries `vektor.zsh`), or copy `sdk/zsh/vektor.zsh` into your
plugin's folder (a plugin must not load files from outside its folder) and begin the program with:

```zsh
#!/bin/zsh
source ${0:A:h}/vektor.zsh

on_startup() { vk_get params.settings.greeting greeting }
on_invoke() {
  vk_get params.command command
  case $command in
    hello) vk_reply $VK_ID "$(vk_obj message "$(vk_str "$greeting, world!")")" ;;
    *)     vk_refuse $VK_ID "This plugin has no command “$command”." ;;
  esac
}
vk_run
```

`vk_run` is the loop. It answers `startup`, `shutdown` and `ping` for you and calls your functions, named after the message with
`/` turned into `_`:

| Your function | Called |
|---|---|
| `on_startup` | when `startup` arrives, before it is answered: read `params.settings.*` and `params.workspace.id` |
| `on_ready` | right after it was answered: send the first views, badges … |
| `on_shutdown` | before `shutdown` is answered, **and** at end of input (Vektor is gone — also when it happens while a handler waits in `vk_request`): stop what you started, remove temporary files. After end of input nothing is written (`vk_send` returns 1) |
| `on_invoke`, `on_view_event`, `on_view_opened`, `on_settingsChanged`, `on_workspace_changed`, … | any other message |
| `on_view_refused` | API 2: Vektor could not show a description or a patch you sent (`params.problem` says why, `params.revision` is what it still shows). Send the whole description again with a revision above anything you sent; events keep carrying `params.revision` until you do |

A request your function does not answer is answered `{}`; a request with no function is refused with “unknown method”.
Notifications with no function are ignored. The message being handled is in `$VK_BODY`, its method in `$VK_METHOD`, its id in
`$VK_ID`.

## What sourcing it changes in your script

The helper runs in your script's shell, so these are your script's too:

* **`LC_ALL=C` is exported.** Every string is bytes (`${#s}` counts bytes, `[[ $s == ? ]]` matches one byte of a multi-byte
  character, `${(U)s}` leaves non-ASCII alone), and every program you start inherits the C locale (`sort` orders by byte,
  `ls` and `date` print in English). Set `LC_ALL` on a single command if it needs another: `LC_ALL=en_US.UTF-8 sort …`.
* **`extended_glob` is on**: `#`, `~` and `^` are pattern characters in an unquoted glob (`rm *~*.txt` means "all but .txt").
* **Modules `zsh/system` and `zsh/zselect` are loaded**, and every read overwrites **`$reply`** (`zselect` puts the ready
  descriptors there); `vk_q` and the block functions overwrite **`$REPLY`**, and the block functions **`$match`**,
  `$mbegin` and `$mend`. Copy a value out of them before you call a helper function.
* Variables named `VK_*` and `_VK_*`, `_vk_roles`, and functions named `vk_*` and `_vk_*` are the helper's; `vk_run` calls
  any function named `on_<method>`. Its functions' locals all start with `__vk_`, so they never hide one of yours.

## What it does

**Framing, by bytes.** The helper sets `LC_ALL=C`, so zsh strings are bytes and `${#string}` is the byte count `Content-Length`
needs — for multi-byte UTF-8 too. `vk_read` reads a message (a header split across reads, any case of `Content-Length`, spaces or
tabs around its value, a header over 1 KB refused as Vektor counts it — even a line that never ends; a body `plutil` cannot read is ignored with one line on stderr), `vk_send JSON` writes one. **Nothing else is ever written to stdout**: send diagnostics to stderr
(`print -u2 …`) or with `vk_log`.

**JSON text.** `vk_str TEXT` prints the JSON string for any text: quotes, backslashes, newlines, tabs, every control character
and NUL (`\u00XX`), any UTF-8. `vk_q TEXT` does the same into `$REPLY` without a subshell (use it in loops). `vk_obj key value …` and
`vk_arr value …` assemble objects and arrays from values that are **already JSON** (`vk_obj` refuses a key without a value,
with the reason on stderr):

```zsh
vk_obj title "$(vk_str "Buy milk")" done false tags "$(vk_arr "$(vk_str a)" "$(vk_str b)")"
# {"title":"Buy milk","done":false,"tags":["a","b"]}
```

**Reading fields.** `vk_get PATH [VARIABLE]` reads a field of the current message with `plutil`. Paths join keys and array
positions with dots, so nested fields work: `params.target.items.0.path`, `result.values.port`, `error.data.currentVersion`.
A string is decoded, a number or boolean is its word (`12`, `true`), **an array is its length**. It prints the value, or — with a
variable name — assigns it without a subshell (any variable you can assign: your function's `local`, an element such as
`S[key]`, an array, which becomes a scalar). It returns 1 for a field that is absent or `null`. Also `vk_has PATH`,
`vk_type PATH` (`string`, `bool`, `array` …), `vk_json PATH` (an object or array as JSON text) and `vk_from JSON PATH [VARIABLE]`
(the same on another message, such as a request's answer).

**Requests.** `vk_request METHOD PARAMS` sends a request, waits for **its** answer by id and returns 0 (the result as JSON in
`$VK_RESULT`; read it with `vk_from "$VK_RESPONSE" result.values.port port`) or 1 (the words in `$VK_ERROR`, the code in
`$VK_ERROR_CODE`). While it waits, a `ping` is answered at once, a `shutdown` ends the plugin properly (`on_shutdown` runs), and
**every other message is queued** and handed to its `on_…` function after you return — nothing is lost, and the message you were
handling is put back. `vk_confirm TITLE MESSAGE [BUTTON]` is a `confirm` request that returns 0 for "yes".

**Sending.** `vk_reply ID [RESULT]`, `vk_refuse ID MESSAGE`, `vk_notify METHOD [PARAMS]`, `vk_toast`, `vk_log LEVEL MESSAGE`,
`vk_view_update VIEW DESCRIPTION`. An id that is not a number is written as a JSON string (`vk_get` reads a string id `"12"`
as `12`, so such an id comes back as a number).

**Blocks.** Small functions that print the JSON of a block. Required things come first, then children (block JSON: an argument starting with
`{"type":`, as every block function prints; a title such as `{draft}` stays a title), then extra fields as `key=value` (text) or `key:=json` (a number, `true`, a list, an object). An argument is a field only when
what comes before `=` is a name (letters, digits, `_`): `vk_spinner "Copying a=b"` shows that text, but text that itself looks
like a field must be passed as one, `vk_spinner text=a=b`:

```zsh
vk_vstack \
  "$(vk_text "Tunnels" style=title)" \
  "$(vk_banner "cloudflared is not installed" role=warning symbol=exclamationmark.triangle)" \
  "$(vk_list tunnels "$(vk_row t1 "example.com" subtitle="running" symbol=cloud badge:='{"text":"up","role":"positive"}')" placeholder="None")" \
  "$(vk_toolbar "$(vk_button "New" new symbol=plus)" "$(vk_button "" refresh symbol=arrow.clockwise style=icon tooltip=Refresh)")" \
  id=root spacing:=8
```

| Function | Block |
|---|---|
| `vk_text TEXT`, `vk_symbol NAME`, `vk_badge TEXT`, `vk_count N` | text (`style=`), an SF Symbol, a word on a capsule, a number |
| `vk_button TITLE ACTION` | a button (`style=primary|plain|destructive|icon`, `symbol=`, `busy:=true` …); an empty title is an icon button |
| `vk_vstack`, `vk_hstack`, `vk_scroll`, `vk_toolbar CHILD…`, `vk_spacer`, `vk_divider` | layout (`vk_scroll` takes `axis=horizontal`; `vk_toolbar` is a row of buttons) |
| `vk_card TITLE CHILD…`, `vk_panel TITLE CHILD…` | surfaces (`role=`, `badge:=`, and for a card in a list `edit=`, `delete=`, `action=`) |
| `vk_list ID ITEM…`, `vk_row ID TITLE` | a collection and a row (`subtitle=`, `check=`, `checked:=true`, `menu:=…`) |
| `vk_menu_item TITLE ACTION`, `vk_menu_separator` | entries for a `menu:=` field: `menu:="$(vk_arr "$(vk_menu_item Delete del destructive:=true)")"` |
| `vk_empty TEXT`, `vk_banner TEXT`, `vk_status TEXT` | an empty state, a note, a one-line status (`role=`, `symbol=`, `title=`) |
| `vk_progress [0…1]`, `vk_spinner [TEXT]` | a bar (none: busy; `.5` is written `0.5`, text that is no number is refused), a spinner |
| `vk_role NAME` | the JSON string of a colour role; refuses a name that is not one |
| `vk_description REVISION BLOCK [TITLE]` | a block view's description |

Colour is only ever a **role** (`accent`, `positive`, `warning`, `danger`, `neutral`, `label1` … `label8`): a block function refuses
`role=purple` and a `color=`, `background=` or `tint=` field, with the reason on stderr, because Vektor would ignore them. Every
block function returns 1 on a bad argument and prints nothing.

**Widths** (plugin API 2) go on any block as numbers of points from 20 to 4000 — `width:=300`, `minWidth:=240` (honoured inside a
horizontal scroll), `maxWidth:=600` — and `grow:=true` (the block takes a share of the width its row leaves). A value outside
that range, or written as text (`width=240`), is refused like a colour, because Vektor would ignore it. Columns that fill the pane
and scroll once they no longer fit:

```zsh
vk_scroll "$(vk_panel 'To do' id=col-todo grow:=true minWidth:=240)" "$(vk_panel Done id=col-done grow:=true minWidth:=240)" \
  axis=horizontal spacing:=12
```

The API 1 view kinds (`list`, `form`, `detail`, `cardList`) are plain objects: build them with `vk_obj` and `vk_arr` as
`samples/todo/run.zsh` does.

## Which tool reads the JSON

The reference asks for "tools every Mac ships" and a measured choice. Measured on macOS 26.6, Apple silicon, 20–50 runs each,
reading `params.value` of a small message with non-ASCII text, quotes and a newline in it:

| Tool | Per call | Shipped by every Mac? | Verdict |
|---|---|---|---|
| **`plutil -extract PATH raw -o - -`** | **about 3 ms** | yes, since 10.2 | **used**: decodes escapes and UTF-8 correctly, nested paths, array length, `-type`, sub-objects as JSON |
| `jq` | about 2 ms | no: `/usr/bin/jq` appeared with macOS 15 | not usable while Vektor runs on macOS 14 |
| `perl -MJSON::PP` | about 9 ms | yes | correct, but 3× slower and needs a decode/encode dance for UTF-8 (“Wide character” otherwise) |
| `osascript -l JavaScript` | about 28 ms | yes | correct, but ten times slower, and it starts a scripting runtime |
| `python3` | — | **no** (the first run opens an installer prompt) | not an option |

A 3 MB message costs about 55 ms per field (`plutil` parses it each time); the 16 MB limit costs under half a second. Reading six
fields of an ordinary event takes about 20 ms.

What `plutil` cannot do, and what the helper does about it: a **key containing a dot** cannot be addressed (read the object with
`vk_json` and take it apart yourself); **`null`** is reported as absent; **numbers with a fraction** come back with six digits
(`0.500000`); the **trailing newlines** of a value are lost; and **every `vk_get` is a process** — fine for a command or an
event, slow in a loop over a thousand records. A value that is an object has to be read field by field. A zsh string can hold `NUL`, and `vk_str`
writes it as `\u0000`; but `plutil` refuses a whole message that contains `\u0000`, so every field of such a message reads as
absent.

## When to stop using zsh

The helper makes a small plugin pleasant. It does not turn zsh into something it is not. Use the **Swift or Node SDK**
([Swift](sdk-swift.md), [Node](sdk-node.md)) when you have:

* **drag-heavy or large layouts** — a board, a table of hundreds of rows. Building a block is a subshell and every card a few
  process starts; the SDKs keep the tree in memory and send patches, zsh resends everything. (The layouts are in the SDKs only.)
* **storage with sync** — documents with versions, `ifVersion` conflicts, a three-way merge by record. That is structured data
  and a lot of JSON handling.
* **many concurrent requests** — `vk_request` waits for one answer at a time (the rest is queued, not handled meanwhile); a
  plugin that has several things in flight, or must stay responsive during a long call, needs real concurrency.
* **lists of more than a few hundred things**, or messages you must parse into structures, or anything you would test with a
  unit-test framework.

zsh stays the right choice for a command that runs a program, a status line, a small list, a dialog and a notice — the samples
`cloudflare-tunnel` and `folder-drive` are exactly that.

## Testing

`sdk/zsh/test/` is a plugin whose only job is to test the helper. `vektor-plugin test sdk/zsh/test sdk/zsh/test/checks.json` runs
it over the real wire — multi-byte text echoed back through a view event, a nested field read, a request answered by the test
host — and its `selftest` command runs `test/selftest.zsh`, the unit tests: framing with multi-byte text and a header split across
reads, the escaping of every special character (each one read back by `plutil`), nested reads of the shapes the reference shows,
a request answered while another message arrives first (queued) and while a `ping` and a `shutdown` do, the loop, and every
block function against the JSON of `sdk/fixtures/blocks.json`. You can run the unit tests alone: `zsh sdk/zsh/test/selftest.zsh`.

Test your own plugin the usual way: `vektor-plugin validate .` and `vektor-plugin test . test/checks.json`. The helper's
functions take their input and output from `VK_IN_FD` and `VK_OUT_FD` (0 and 1 by default), which is how the tests feed them files.

## Changing the helper

Edit `sdk/zsh/vektor.zsh`, then run `sdk/zsh/sync.sh`: it copies the file into `templates/zsh/` and `samples/todo/`, which carry it
because a plugin cannot load files from outside its folder. The unit tests fail while a copy differs.
