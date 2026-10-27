#!/bin/zsh
# Sketch — a web view sample (plugin API 2). The page (web/index.html, web/app.js) draws; this program only keeps the
# drawing: the page asks for it with vektor.post({ type: "load" }) and gets { type: "strokes", strokes } back through
# web/post; it sends { type: "save", strokes } after every stroke and on Clear.
#
# Everything between the page and its plugin is a JSON value. Vektor checks the size (1 MB each way) and delivers a page's
# messages only to this plugin, and this plugin's web/post only to its own pages.
export LC_ALL=C
# Without extended_glob the `(#i)content-length:*` match below never matches, no message is ever read and the plugin exits at
# once — the most common mistake in a zsh plugin.
setopt extended_glob
zmodload zsh/system zsh/zselect
data=${VEKTOR_PLUGIN_DATA:-${0:A:h}/data}
mkdir -p "$data"
sketch="$data/sketch.json"

# One message out: Content-Length framing. LC_ALL=C makes ${#1} count bytes.
send() { printf 'Content-Length: %d\r\n\r\n%s' ${#1} "$1" }
# A value of the message just read, by path (plutil reads JSON from standard input).
jx() { print -rn -- "$body" | plutil -extract "$1" raw -o - - 2>/dev/null }
# A part of the message as JSON text (an array or an object), re-serialised by plutil — so it is valid JSON whatever the
# page sent.
jjson() { print -rn -- "$body" | plutil -extract "$1" json -o - - 2>/dev/null }

# The drawing, as JSON text: what was saved, or an empty drawing.
strokes() {
  if [[ -s $sketch ]]; then cat -- "$sketch"; else print -rn -- '[]'; fi
}

# Written to a temporary file and moved into place, so a crash never leaves half a drawing.
save() {
  print -rn -- "$1" > "$sketch.new" && mv -f -- "$sketch.new" "$sketch"
}

# The page's message, by type.
on_message() {
  local view=$(jx params.view)
  case $(jx params.message.type) in
    load)
      send "{\"api\":2,\"method\":\"web/post\",\"params\":{\"view\":\"$view\",\"message\":{\"type\":\"strokes\",\"strokes\":$(strokes)}}}"
      ;;
    save)
      local value=$(jjson params.message.strokes)
      # Only a list is a drawing; anything else is ignored rather than stored.
      [[ $value == \[* ]] && save "$value"
      ;;
  esac
}

while true; do
  zselect 0 2>/dev/null
  length=""
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z $line ]] && break
    [[ $line == (#i)content-length:* ]] && length=${${line#*:}// /}
  done
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
    startup|ping) send "{\"api\":2,\"id\":$msgid,\"result\":{}}" ;;
    shutdown) send "{\"api\":2,\"id\":$msgid,\"result\":{}}"; exit 0 ;;
    web/message) on_message ;;
    # view/opened, view/closed: nothing to do — the page asks for its drawing itself when it loads.
    *) [[ -n $msgid && -n $method ]] && send "{\"api\":2,\"id\":$msgid,\"error\":{\"message\":\"unknown method\"}}" ;;
  esac
done
