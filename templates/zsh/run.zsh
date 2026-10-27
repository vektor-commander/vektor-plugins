#!/bin/zsh
# Hello Plugin — the plugin template (Vektor plugin API 1), on the zsh helper vektor.zsh. Copy the folder, rename it in
# plugin.json, edit this file.
#
# A plugin is a program that Vektor starts when it is needed and talks to over stdin/stdout. Each message is
#
#     Content-Length: <bytes>\r\n
#     \r\n
#     <JSON body>
#
# Vektor sends requests (they carry an "id" and want an answer: startup, shutdown, invoke, ping) and notifications (no id:
# settingsChanged, view/opened, view/event, …). You answer a request with {"id": …, "result": …} or {"id": …, "error": {"message": …}}.
# You may send Vektor notifications (log, toast, …) and requests (dialog/show, openURL, …) of your own.
# docs/reference.md lists every message with an example.
#
# vektor.zsh (next to this file, a copy of sdk/zsh/vektor.zsh) does the parts every zsh plugin gets wrong once:
#   * the framing, by BYTES (it sets LC_ALL=C: strings are bytes, so ${#string} is what Content-Length needs);
#   * JSON text: `vk_str` escapes any text; `vk_obj` / `vk_arr` assemble objects and arrays; `vk_text`, `vk_button`, … print blocks;
#   * reading fields: `vk_get params.settings.greeting` (plutil, which every Mac has; one process per field);
#   * the loop: `vk_run` answers startup, shutdown and ping, and calls the functions below, named after the message
#     (`on_invoke`, `on_view_event`, `on_settingsChanged` …; a `/` becomes `_`).
# docs/sdk-zsh.md says what else it offers, and when to stop using zsh (drag-heavy layouts, storage with sync, many requests at once).
#
# Rules this file still follows by itself:
#   * Do not print anything on stdout that is not a message (vektor.zsh only ever writes messages). Diagnostics go to stderr
#     or to the `log` message.
#   * `shutdown` is answered and the plugin exits; put whatever you must stop in `on_shutdown`. Vektor ends what is left after
#     a short grace period.
#   * Keep state in $VEKTOR_PLUGIN_DATA, never inside this folder (it is replaced on update).
source ${0:A:h}/vektor.zsh

data=${VEKTOR_PLUGIN_DATA:-/tmp/vektor-hello}
mkdir -p "$data"

typeset greeting="Hello"

# --- What the plugin does ------------------------------------------------------------------------------------------
# Runs when `startup` arrives, before it is answered. params: vektorVersion, pluginID, settings (every setting, defaults
# filled in), workspace, dataFolder, sessionTemporaryFolder, previousSessionEndedUncleanly.
on_startup() { vk_get params.settings.greeting greeting }

# Runs right after startup was answered: the place for a first `view/update`, a sidebar badge ...
on_ready() { vk_log info "Hello Plugin started." }

on_settingsChanged() { vk_get params.settings.greeting greeting }

# Displayed text: a control character other than tab, newline and return becomes a space, as this program has always shown
# it (vk_q alone would escape it, \u0001 ...). The result is in REPLY, ready for vk_q.
plain() { REPLY=${1//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/ } }

on_invoke() {
  local command count message
  vk_get params.command command
  case $command in
    hello)
      # The items the command was chosen for: params.target.items is a list of {path, name, isFolder}; read as a field, a list
      # is its length.
      vk_get params.target.items count
      count=${count:-0}
      message="$greeting! You chose $count item(s)."
      # A reply with a "message" is shown to the user as a short notice. (Needs no permission: it only talks to you.)
      plain "$message"
      vk_reply $VK_ID "$(vk_obj message "$(vk_str "$REPLY")")" ;;
    *)
      plain "This plugin has no command “$command”."
      vk_refuse $VK_ID "$REPLY" ;;
  esac
}

# Not used here: on_shutdown() { … stop what you started … }  (also runs when Vektor closes the pipe)

vk_run
