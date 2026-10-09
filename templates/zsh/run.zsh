#!/bin/zsh
# Hello Plugin — the plugin template (Vektor plugin API 1). Copy the folder, rename it in plugin.json, edit this file.
#
# A plugin is a program that Vektor starts when it is needed and talks to over stdin/stdout. Each message is
#
#     Content-Length: <bytes>\r\n
#     \r\n
#     <JSON body>
#
# Vektor sends requests (they carry an "id" and want an answer: startup, shutdown, invoke, ping) and notifications (no id: settingsChanged,
# view/opened, view/event, …). You answer a request with {"id": …, "result": …} or {"id": …, "error": {"message": …}}.
# You may send Vektor notifications (log, toast, …) and requests (dialog/show, openURL, …) of your own.
# docs/reference.md lists every message with an example.
#
# Rules this file follows, each learned the hard way (see docs/reference.md "Writing the program"):
#   * LC_ALL=C: strings are bytes, so Content-Length (a byte count) is ${#string}.
#   * JSON is read with `plutil -extract <path> raw -` (one field per call) and written by hand through `j`, which escapes.
#     Never write Python (Vektor does not ship it) — zsh, or a compiled program signed with `codesign -s -`.
#   * Do not print anything on stdout that is not a message. Diagnostics go to stderr or to the `log` message.
#   * `shutdown` must answer and exit. Stop everything you started; Vektor ends what is left after a short grace period.
#   * Keep state in $VEKTOR_PLUGIN_DATA, never inside this folder (it is replaced on update).
export LC_ALL=C
setopt extended_glob   # the header match below, (#i), is an extended glob: without it no message is ever read
zmodload zsh/system zsh/zselect

data=${VEKTOR_PLUGIN_DATA:-/tmp/vektor-hello}
mkdir -p "$data"

typeset body="" method="" msgid="" J=""
typeset greeting="Hello"

# --- Wire ----------------------------------------------------------------------------------------------------------
j() {  # JSON string literal of $1, in $J
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  s=${s//[$'\001'-$'\037']/ }
  J="\"$s\""
}
send() { printf 'Content-Length: %d\r\n\r\n%s' ${#1} "$1" }
notify() { send "{\"api\":1,\"method\":\"$1\",\"params\":$2}" }
reply() { send "{\"api\":1,\"id\":$1,\"result\":$2}" }
refuse() { j "$2"; send "{\"api\":1,\"id\":$1,\"error\":{\"message\":$J}}" }
jx() { print -rn -- "$body" | plutil -extract "$1" raw -o - - 2>/dev/null }

# --- What the plugin does ------------------------------------------------------------------------------------------
on_invoke() {
  local command count message
  command=$(jx params.command)
  case $command in
    hello)
      # The items the command was chosen for: params.target.items is a list of {path, name, isFolder}.
      count=$(jx params.target.items)
      count=${count:-0}
      message="$greeting! You chose $count item(s)."
      j "$message"
      # A reply with a "message" is shown to the user as a short notice. (Needs no permission: it only talks to you.)
      reply $msgid "{\"message\":$J}" ;;
    *)
      refuse $msgid "This plugin has no command “$command”." ;;
  esac
}

# --- Main loop -------------------------------------------------------------------------------------------------------
while true; do
  zselect 0 2>/dev/null
  length=""
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z $line ]] && break
    [[ $line == (#i)content-length:* ]] && length=${${line#*:}// /}
  done
  # End of file: Vektor is gone. Stop what you started (nothing here) and leave.
  [[ -z $length ]] && exit 0
  body=""
  while (( ${#body} < length )); do
    chunk=""
    sysread -i 0 -s $(( length - ${#body} )) chunk || break
    body+=$chunk
  done

  method=$(jx method)
  msgid=$(jx id)
  case $method in
    startup)
      # params: vektorVersion, pluginID, settings (every setting, defaults filled in), workspace, dataFolder,
      # sessionTemporaryFolder, previousSessionEndedUncleanly.
      greeting=$(jx params.settings.greeting)
      reply $msgid '{}'
      notify log '{"level":"info","message":"Hello Plugin started."}' ;;
    settingsChanged)
      greeting=$(jx params.settings.greeting) ;;
    invoke) on_invoke ;;
    shutdown)
      reply $msgid '{}'
      exit 0 ;;
    ping) reply $msgid '{}' ;;
    '$/cancel') ;;
    '') ;;                       # an answer to a request of ours: this plugin sends none
    *) [[ -n $msgid ]] && refuse $msgid "unknown method" ;;
  esac
done
