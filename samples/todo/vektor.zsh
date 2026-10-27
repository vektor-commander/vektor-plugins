# vektor.zsh - the Vektor plugin helper for zsh. One file, no dependencies beyond what every Mac ships (zsh, plutil).
#
# Copy this file into your plugin's folder (a plugin must not load files from outside its folder) and source it from the
# program, as the first thing it does:
#
#     #!/bin/zsh
#     source ${0:A:h}/vektor.zsh
#     on_startup()   { greeting=$(vk_get params.settings.greeting) }
#     on_invoke()    { vk_reply $VK_ID "{\"message\":$(vk_str "Hello!")}" }
#     vk_run
#
# What it does for you, and what it does not (docs/sdk-zsh.md has the long version):
#
#   * FRAMING by bytes. It sets LC_ALL=C, so zsh strings are bytes and ${#string} is the byte count Content-Length needs
#     (multi-byte UTF-8 included). `vk_read` reads one message, `vk_send` writes one. Nothing else is ever written to stdout.
#   * JSON ESCAPING: `vk_str` quotes any text (quotes, backslashes, newlines, tabs, every control character and NUL, any UTF-8);
#     `vk_obj` and `vk_arr` build objects and arrays from already-escaped parts.
#   * READING FIELDS with `vk_get path` (plutil, which every Mac has): nested paths like params.target.items.0.path, strings
#     decoded, numbers and booleans as words, an array as its length.
#   * REQUESTS: `vk_request` sends a request and waits for ITS answer by id; whatever else arrives meanwhile is queued, a `ping`
#     is answered at once, and `shutdown` ends the plugin properly.
#   * THE LOOP: `vk_run` answers startup, shutdown and ping, and calls your functions `on_<method>` (`/` becomes `_`):
#     on_startup, on_ready, on_shutdown, on_settingsChanged, on_invoke, on_view_opened, on_view_event, on_workspace_changed, ...
#   * BLOCKS: small functions that print the JSON of a block: vk_text, vk_symbol, vk_button, vk_vstack, vk_row, vk_card,
#     vk_empty, vk_banner, vk_toolbar, vk_progress, vk_role, ...
#
# It does NOT parse JSON into structures (zsh has none), and every vk_get is a process. Fine for a command, a status line, a
# list of a few dozen rows. For drag-heavy layouts, storage with sync or many concurrent requests use the Swift or Node SDK.
#
# Conventions: functions that produce JSON print it on stdout (capture it with $(...)); VK_* variables are the helper's.
# Extra block fields are passed as `key=value` (the value is text) or `key:=json` (the value is raw JSON: numbers, true/false,
# lists, objects): vk_button "Sync" sync symbol=arrow.clockwise style=icon busy:=true
#
# Version 0.1.0, written for plugin API 2 (it works with API 1 plugins too: it writes the "api" your manifest declares).

export LC_ALL=C                  # strings are bytes: ${#s} is the byte count Content-Length needs
setopt extended_glob             # the header match in vk_read, (#i), is an extended glob
zmodload zsh/system zsh/zselect  # sysread (bytes from a descriptor) and zselect (wait for input)

readonly VK_VERSION=0.1.0
typeset -g VK_API=${VEKTOR_PLUGIN_API:-1}   # the "api" written on every message
typeset -gi VK_NEXT_ID=1000                 # the first id of the plugin's own requests (the reference: "start yours at 1000 or so")
typeset -gi VK_IN_FD=0 VK_OUT_FD=1          # where messages are read from and written to (the tests use others)
typeset -g VK_BODY="" VK_METHOD="" VK_ID=""   # the message being handled
typeset -g VK_RESPONSE="" VK_RESULT="" VK_ERROR="" VK_ERROR_CODE=""   # the answer to the last vk_request
typeset -ga VK_QUEUE                        # messages that arrived while a request was waiting for its answer
typeset -gi VK_ANSWERED=0                   # set when the current request has been answered
typeset -gi VK_MAX_HEADER=1024              # Vektor ends a plugin whose header exceeds 1 KB: so does vk_read
typeset -gi VK_ENDED=0                      # set when input ended (Vektor is gone): nothing is written after it

# --- JSON text ---------------------------------------------------------------------------------------------------------

vk_q() {  # vk_q TEXT: the JSON string literal of TEXT, in REPLY (no subshell: use it in loops; vk_str prints the same)
  local s=$1 c hex
  local -i n
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  s=${s//$'\010'/\\b}; s=${s//$'\014'/\\f}
  if [[ $s == *[$'\000'-$'\037'$'\177']* ]]; then   # the rest of the control characters, NUL too: \u00XX
    for n in {0..31} 127; do
      c=${(#)n}
      [[ $s == *$c* ]] || continue
      printf -v hex '\\u%04x' $n
      s=${s//$c/$hex}
    done
  fi
  REPLY="\"$s\""
}

vk_str() { vk_q "$1"; print -rn -- "$REPLY" }   # vk_str TEXT: the JSON string literal of TEXT

vk_obj() {  # vk_obj KEY VALUE [KEY VALUE]...: an object; keys are text, values are JSON (already escaped: vk_str, numbers, true, ...)
  # A key with no value is refused (returns 1, prints nothing): it used to be dropped without a word.
  if (( $# % 2 )); then print -u2 -r -- "vektor.zsh: vk_obj needs a value for every key; “${@[-1]}” has none."; return 1; fi
  local out="" sep=""
  while (( $# >= 2 )); do
    vk_q "$1"; out+="$sep$REPLY:$2"; sep=","
    shift 2
  done
  print -rn -- "{$out}"
}

vk_arr() {  # vk_arr VALUE...: an array of JSON values
  local out="" sep="" v
  for v in "$@"; do out+="$sep$v"; sep=","; done
  print -rn -- "[$out]"
}

_vk_number() {  # _vk_number TEXT: TEXT as a JSON number in REPLY (.5 is 0.5, 1. is 1, 007 is 7); returns 1 for anything else
  local __vk_sign="" __vk_s=$1 __vk_int __vk_frac; local -a match mbegin mend
  [[ $__vk_s == -* ]] && { __vk_sign=-; __vk_s=${__vk_s#-} }
  [[ $__vk_s == (#b)([0-9]#)(.([0-9]#)|) && -n $match[1]$match[3] ]] || return 1
  __vk_int=${match[1]##0#}; __vk_frac=$match[3]
  REPLY=$__vk_sign${__vk_int:-0}${__vk_frac:+.$__vk_frac}
}

# --- Framing -----------------------------------------------------------------------------------------------------------

vk_send() {  # vk_send JSON: writes one message. The byte count is ${#1} because LC_ALL=C.
  # After end of input nothing is written: the pipe is closed, and a write would end the plugin with SIGPIPE before
  # on_shutdown has run. Returns 1 then.
  (( VK_ENDED )) && return 1
  printf 'Content-Length: %d\r\n\r\n%s' ${#1} "$1" >&$VK_OUT_FD
}

vk_read() {
  # Reads one message into VK_BODY, VK_METHOD ('' for an answer) and VK_ID. Returns 1 at end of input (Vektor is gone), and
  # for a header Vektor would not send; either way VK_ENDED is set: the conversation is over.
  _vk_read_message && return 0
  VK_ENDED=1
  return 1
}

_vk_read_message() {
  # The header is read a byte at a time (`read` would wait for a newline however long the line, and read past the limit),
  # counting what Vektor counts: the bytes before the blank line, at most VK_MAX_HEADER. The value of Content-Length may
  # have spaces or tabs around it, as Vektor accepts.
  local line="" length="" chunk c
  local -i seen=0
  zselect -r $VK_IN_FD 2>/dev/null
  while true; do
    sysread -i $VK_IN_FD -s 1 c || return 1                 # end of input (or a read error): Vektor is gone
    seen+=1
    # the 4 bytes of the final \r\n\r\n are not part of the header
    if (( seen > VK_MAX_HEADER + 4 )); then print -u2 "vektor.zsh: a header longer than $VK_MAX_HEADER bytes"; return 1; fi
    if [[ $c != $'\n' ]]; then line+=$c; continue; fi
    line=${line%$'\r'}
    if [[ -z $line ]]; then
      if (( seen - 4 > VK_MAX_HEADER )); then print -u2 "vektor.zsh: a header longer than $VK_MAX_HEADER bytes"; return 1; fi
      break
    fi
    if [[ $line == (#i)[[:blank:]]#content-length[[:blank:]]#:* ]]; then
      length=${line#*:}; length=${length##[[:blank:]]#}; length=${length%%[[:blank:]]#}
    fi
    line=""
  done
  [[ -n $length && $length == <-> ]] || return 1
  VK_BODY=""
  while (( ${#VK_BODY} < length )); do
    chunk=""
    sysread -i $VK_IN_FD -s $(( length - ${#VK_BODY} )) chunk || break
    VK_BODY+=$chunk
  done
  vk_get method VK_METHOD || VK_METHOD=""
  vk_get id VK_ID || VK_ID=""
  # Every message has a method or an id. Neither: plutil could not read it (it refuses \u0000, for one). It cannot be
  # answered without its id, but it is not dropped without a word either.
  if [[ -z $VK_METHOD && -z $VK_ID && -n $VK_BODY ]]; then
    print -u2 -r -- "vektor.zsh: a message of ${#VK_BODY} bytes could not be read (no method, no id): it is ignored."
  fi
  return 0
}

# --- Reading fields ----------------------------------------------------------------------------------------------------

vk_get() {
  # vk_get PATH [VARIABLE]: a field of the current message (VK_BODY). PATH joins keys and array positions with dots:
  # params.settings.greeting, params.target.items.0.path. A string is decoded (UTF-8, \n, \" ...); a number or boolean is its
  # word (true, 12); an ARRAY is its length; an object is not readable (read its fields). Prints it, or sets VARIABLE
  # (no subshell). Returns 1 when the field is absent or null (and prints / sets nothing, or an empty VARIABLE).
  # Trailing newlines of a value are lost; a key containing a dot cannot be addressed (use vk_json and read it yourself).
  # VARIABLE may be any name the caller can assign: an array (it becomes a scalar), an element (`S[key]`), a local of the
  # caller. (`typeset -g NAME=...` was not: it failed on an array, and the helper's own locals hid a caller's of the same
  # name. ${(P)2::=...} assigns in the caller's scope; the helper's locals all start with __vk_ so they never hide one.)
  local __vk_v
  if ! __vk_v=$(print -rn -- "$VK_BODY" | plutil -extract "$1" raw -o - - 2>/dev/null); then
    [[ -n $2 ]] && : ${(P)2::=}
    return 1
  fi
  if [[ -n $2 ]]; then : ${(P)2::=$__vk_v}; else print -rn -- "$__vk_v"; fi
}

vk_has() { print -rn -- "$VK_BODY" | plutil -extract "$1" raw -o - - >/dev/null 2>&1 }   # whether PATH is there and not null

vk_type() {  # vk_type PATH: string, integer, real, bool, array, dictionary ... (nothing when absent)
  print -rn -- "$VK_BODY" | plutil -type "$1" -o - - 2>/dev/null
}

vk_json() {  # vk_json PATH: the field as JSON text (an object or an array too)
  print -rn -- "$VK_BODY" | plutil -extract "$1" json -o - - 2>/dev/null
}

vk_from() {  # vk_from JSON PATH [VARIABLE]: vk_get on another message (VK_RESPONSE, say) without disturbing the current one
  local __vk_saved=$VK_BODY __vk_rc
  VK_BODY=$1
  vk_get "$2" $3; __vk_rc=$?
  VK_BODY=$__vk_saved
  return $__vk_rc
}

# --- Sending messages --------------------------------------------------------------------------------------------------

# An id is a number or a string: one that is not a number is written as a JSON string (it went out bare: not JSON).
_vk_id() { if [[ $1 == (-|)<-> ]]; then REPLY=$1; else vk_q "$1"; fi }
vk_reply() { _vk_id "$1"; vk_send "{\"api\":$VK_API,\"id\":$REPLY,\"result\":${2:-{\}}}"; [[ $1 == $VK_ID ]] && VK_ANSWERED=1 }   # vk_reply ID [RESULT-JSON]
vk_refuse() {  # vk_refuse ID MESSAGE
  local __vk_id; _vk_id "$1"; __vk_id=$REPLY; vk_q "$2"
  vk_send "{\"api\":$VK_API,\"id\":$__vk_id,\"error\":{\"message\":$REPLY}}"; [[ $1 == $VK_ID ]] && VK_ANSWERED=1
}
vk_notify() { vk_send "{\"api\":$VK_API,\"method\":\"$1\",\"params\":${2:-{\}}}" }   # vk_notify METHOD [PARAMS-JSON]
vk_toast() { vk_q "$1"; vk_notify toast "{\"message\":$REPLY}" }
vk_log() { vk_q "$2"; vk_notify log "{\"level\":\"${1:-info}\",\"message\":$REPLY}" }   # vk_log LEVEL MESSAGE
vk_view_update() { vk_q "$1"; vk_notify view/update "{\"view\":$REPLY,\"description\":$2}" }   # vk_view_update VIEW DESCRIPTION-JSON

# --- Requests: send, wait for the answer, queue the rest -----------------------------------------------------------------

vk_request() {
  # vk_request METHOD [PARAMS-JSON]: sends a request and waits for ITS answer (matched by id). Returns 0 with VK_RESULT
  # holding the result as JSON, or 1 with VK_ERROR (and VK_ERROR_CODE) holding the error's words. VK_RESPONSE is the whole
  # answer (read it with vk_from "$VK_RESPONSE" result.values.port VAR). While waiting:
  #   * a ping is answered at once; a shutdown ends the plugin (on_shutdown runs);
  #   * every other message is queued, and vk_run hands it to its on_<method> after you return;
  #   * the message you were handling stays readable: VK_BODY, VK_METHOD and VK_ID are put back.
  # Returns 2 if input ended first (Vektor is gone: return and let vk_run leave; nothing you send after it is written).
  (( VK_ENDED )) && return 2
  # (Its locals start with __vk_: on_shutdown runs inside it and must see the caller's variables, not these.)
  local __vk_id=$(( VK_NEXT_ID++ )) __vk_body=$VK_BODY __vk_method=$VK_METHOD __vk_msgid=$VK_ID __vk_answered=$VK_ANSWERED __vk_rc=2
  vk_send "{\"api\":$VK_API,\"id\":$__vk_id,\"method\":\"$1\",\"params\":${2:-{\}}}"
  while vk_read; do
    if [[ -z $VK_METHOD && $VK_ID == $__vk_id ]]; then
      VK_RESPONSE=$VK_BODY
      if vk_has error; then
        vk_get error.message VK_ERROR; vk_get error.code VK_ERROR_CODE; VK_RESULT=""; __vk_rc=1
      else
        VK_ERROR=""; VK_ERROR_CODE=""; VK_RESULT=$(vk_json result); __vk_rc=0
      fi
      break
    elif [[ $VK_METHOD == ping ]]; then
      vk_reply $VK_ID '{}'
    elif [[ $VK_METHOD == shutdown ]]; then
      _vk_shutdown
    elif [[ -n $VK_METHOD ]]; then
      VK_QUEUE+=$VK_BODY
    fi
  done
  VK_BODY=$__vk_body; VK_METHOD=$__vk_method; VK_ID=$__vk_msgid; VK_ANSWERED=$__vk_answered
  return $__vk_rc
}

vk_confirm() {  # vk_confirm TITLE MESSAGE [CONFIRM-BUTTON]: asks the user; returns 0 when they confirmed
  local __vk_t __vk_m __vk_c
  vk_q "$1"; __vk_t=$REPLY; vk_q "$2"; __vk_m=$REPLY; vk_q "${3:-OK}"; __vk_c=$REPLY
  vk_request confirm "{\"title\":$__vk_t,\"message\":$__vk_m,\"confirmTitle\":$__vk_c}" || return 1
  local __vk_confirmed
  vk_from "$VK_RESPONSE" result.confirmed __vk_confirmed
  [[ $__vk_confirmed == true ]]
}

# --- The loop ----------------------------------------------------------------------------------------------------------

_vk_shutdown() {   # answer, tidy up, leave
  (( $+functions[on_shutdown] )) && on_shutdown
  vk_reply $VK_ID '{}'
  exit 0
}

vk_next() {  # the next message: a queued one first, else one read from the input. Returns 1 at end of input.
  if (( $#VK_QUEUE > 0 )); then
    VK_BODY=$VK_QUEUE[1]; VK_QUEUE[1]=()
    vk_get method VK_METHOD || VK_METHOD=""
    vk_get id VK_ID || VK_ID=""
    return 0
  fi
  vk_read
}

vk_run() {
  # The main loop. Answers startup, shutdown and ping itself and calls your functions for the rest:
  #   on_startup    before startup is answered: read params.settings.*, params.workspace.id ... with vk_get
  #   on_ready      right after startup was answered: send the first views, badges ...
  #   on_shutdown   before shutdown is answered, and at end of input: stop what you started, remove temporary files
  #   on_<method>   any other message, with / as _ : on_invoke, on_view_event, on_view_opened, on_settingsChanged ...
  # A request your function did not answer gets `{}`; a request with no function is refused "unknown method".
  # Notifications with no function are ignored.
  local __vk_handler   # not `handler`: your on_<method> functions run inside this one and may use that name
  while true; do
    # End of input, here or while a handler waited in vk_request: on_shutdown, then leave. (Nothing is written after it.)
    if (( VK_ENDED )) || ! vk_next; then
      (( $+functions[on_shutdown] )) && on_shutdown
      exit 0
    fi
    VK_ANSWERED=0
    case $VK_METHOD in
      '') continue ;;                  # an answer nobody waits for
      ping) vk_reply $VK_ID '{}' ;;
      '$/cancel') ;;                   # this helper runs one thing at a time: nothing to cancel
      shutdown) _vk_shutdown ;;
      startup)
        (( $+functions[on_startup] )) && on_startup
        vk_reply $VK_ID '{}'
        (( $+functions[on_ready] )) && on_ready ;;
      *)
        __vk_handler=on_${VK_METHOD//\//_}
        if (( $+functions[$__vk_handler] )); then
          $__vk_handler
          [[ -n $VK_ID ]] && (( ! VK_ANSWERED )) && vk_reply $VK_ID '{}'
        elif [[ -n $VK_ID ]]; then
          vk_refuse $VK_ID "unknown method"
        fi ;;
    esac
  done
}

# --- Blocks: functions that print the JSON of a block --------------------------------------------------------------------
# A block function takes what the block needs first, then CHILDREN (block JSON, which starts with {"type":, printed
# by other block functions) where the block has any, then extra fields as key=value (text) or key:=json (raw). Colour is only ever a role:
# role=label3. A `color`, `background`, `tint` ... field is refused, as Vektor would ignore it. Widths are numbers of points from 20
# to 4000 (width:=240 minWidth:=240 maxWidth:=600) and grow:=true|false; anything else is refused, as Vektor would ignore it.

_vk_roles=(accent positive warning danger neutral label1 label2 label3 label4 label5 label6 label7 label8)

_vk_fields() {  # appends ,"key":value for each extra argument to _VK_OUT; returns 1 (and says why) for one that is not valid
  local a key val raw
  for a in "$@"; do
    if [[ $a == (#b)([A-Za-z_][A-Za-z0-9_]#):=(*) ]]; then
      key=$match[1]; val=$match[2]; raw=1
    elif [[ $a == (#b)([A-Za-z_][A-Za-z0-9_]#)=(*) ]]; then
      key=$match[1]; val=$match[2]; raw=0
    else
      print -u2 "vektor.zsh: “$a” is not key=value or key:=json."; return 1
    fi
    case $key in
      color|colour|background|backgroundColor|foreground|foregroundColor|tint|fill|textColor)
        print -u2 "vektor.zsh: “$key” would carry a colour value, which Vektor ignores: name a role (role=label3)."; return 1 ;;
      role)
        if (( ! ${_vk_roles[(Ie)$val]} )); then
          print -u2 "vektor.zsh: “$val” is not a colour role (${(j:, :)_vk_roles})."; return 1
        fi ;;
      width|minWidth|maxWidth)
        if (( ! raw )) || ! _vk_number "$val" || [[ $REPLY == -* ]] || (( REPLY < 20 || REPLY > 4000 )); then
          print -u2 -r -- "vektor.zsh: “$a” is not a width Vektor uses: a number of points from 20 to 4000, written $key:=240."; return 1
        fi
        val=$REPLY ;;
      grow)
        if (( ! raw )) || [[ $val != (true|false) ]]; then
          print -u2 -r -- "vektor.zsh: “$a” is not a grow Vektor reads: grow:=true or grow:=false."; return 1
        fi ;;
    esac
    if (( raw )); then _VK_OUT+=",\"$key\":$val"; else vk_q "$val"; _VK_OUT+=",\"$key\":$REPLY"; fi
  done
}

# Whether ARG is an extra field: name=... or name:=... where name is an identifier ("Copying a=b" is text, "a=b" is not).
_vk_is_field() { [[ $1 == [A-Za-z_][A-Za-z0-9_]#(:|)=* ]] }

# Splits ARGS into children (start with {"type": , as every block function's output does) in _VK_KIDS and the rest in _VK_REST.
# Not just { : a card titled "{draft}" was taken for a child and the block was not JSON.
_vk_split() {
  _VK_KIDS=(); _VK_REST=()
  local a
  for a in "$@"; do
    if [[ $a == '{"type":'* ]]; then _VK_KIDS+=$a; else _VK_REST+=$a; fi
  done
}

# Prints {"type":TYPE<_VK_OUT>[,"children":[...]]}
_vk_emit() {  # _vk_emit TYPE [withchildren]
  local out="{\"type\":\"$1\"$_VK_OUT"
  if [[ $2 == withchildren ]]; then out+=",\"children\":[${(j:,:)_VK_KIDS}]"; fi
  print -rn -- "$out}"
}

vk_role() {  # vk_role NAME: the JSON string of a colour role; refuses a name that is not one
  if (( ! ${_vk_roles[(Ie)$1]} )); then print -u2 "vektor.zsh: “$1” is not a colour role (${(j:, :)_vk_roles})."; return 1; fi
  print -rn -- "\"$1\""
}

vk_text() {  # vk_text TEXT [style=title|heading|body|caption|mono] [role=...] [link=...] [lineLimit:=2] ...
  _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"text\":$REPLY"; shift
  _vk_fields "$@" || return 1; _vk_emit text
}
vk_symbol() { _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"symbol\":$REPLY"; shift; _vk_fields "$@" || return 1; _vk_emit symbol }   # vk_symbol NAME [role=...] [label=...]
vk_badge() { _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"text\":$REPLY"; shift; _vk_fields "$@" || return 1; _vk_emit badge }   # vk_badge TEXT [role=...]
vk_count() {  # vk_count NUMBER [role=...]: no arguments at all is 0; a first argument that is no number is refused
  if ! _vk_number "${1:-0}"; then print -u2 -r -- "vektor.zsh: vk_count needs a number first, not “$1”."; return 1; fi
  _VK_OUT=",\"count\":$REPLY"; (( $# )) && shift; _vk_fields "$@" || return 1; _vk_emit count
}
vk_spacer() { _VK_OUT=""; _vk_fields "$@" || return 1; _vk_emit spacer }
vk_divider() { _VK_OUT=""; _vk_fields "$@" || return 1; _vk_emit divider }

vk_button() {  # vk_button TITLE ACTION [id=...] [symbol=...] [style=primary|plain|destructive|icon] [tooltip=...] [busy:=true] [enabled:=false]
  _VK_OUT=""
  if [[ -n $1 ]]; then vk_q "$1"; _VK_OUT=",\"title\":$REPLY"; fi
  vk_q "$2"; _VK_OUT+=",\"action\":$REPLY"; shift 2
  _vk_fields "$@" || return 1; _vk_emit button
}

vk_vstack() { _vk_split "$@"; _VK_OUT=""; _vk_fields "${_VK_REST[@]}" || return 1; _vk_emit vstack withchildren }   # vk_vstack CHILD... [id=...] [spacing:=8]
vk_hstack() { _vk_split "$@"; _VK_OUT=""; _vk_fields "${_VK_REST[@]}" || return 1; _vk_emit hstack withchildren }
vk_toolbar() { _vk_split "$@"; _VK_OUT=""; _vk_fields "${_VK_REST[@]}" || return 1; _vk_emit hstack withchildren }   # a row of buttons: an hstack
vk_scroll() { _vk_split "$@"; _VK_OUT=""; _vk_fields "${_VK_REST[@]}" || return 1; _vk_emit scroll withchildren }   # vk_scroll CHILD... [axis=horizontal] [spacing:=12]

vk_card() {  # vk_card TITLE CHILD... [id=...] [symbol=...] [role=...] [badge:='{"text":"new"}'] [action=...] [edit=...] [delete=...]
  _vk_split "$@"; _VK_OUT=""
  vk_q "${_VK_REST[1]}"; _VK_OUT=",\"title\":$REPLY"
  _vk_fields "${(@)_VK_REST[2,-1]}" || return 1; _vk_emit card withchildren
}
vk_panel() {  # vk_panel TITLE CHILD... [id=...] [role=...]
  _vk_split "$@"; _VK_OUT=""
  vk_q "${_VK_REST[1]}"; _VK_OUT=",\"title\":$REPLY"
  _vk_fields "${(@)_VK_REST[2,-1]}" || return 1; _vk_emit panel withchildren
}
vk_list() {  # vk_list ID ITEM... [selection=single] [select=action] [group=cards] [move=action] [placeholder=...]
  _vk_split "$@"; _VK_OUT=""
  vk_q "${_VK_REST[1]}"; _VK_OUT=",\"id\":$REPLY"
  _vk_fields "${(@)_VK_REST[2,-1]}" || return 1; _vk_emit list withchildren
}
vk_row() {  # vk_row ID TITLE [subtitle=...] [symbol=...] [badge:='{"text":"b"}'] [check=action] [checked:=true] [action=...] [dimmed:=true] [menu:="$(vk_arr ...)"]
  _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"id\":$REPLY"
  if [[ -n $2 ]]; then vk_q "$2"; _VK_OUT+=",\"title\":$REPLY"; fi
  shift 2; _vk_fields "$@" || return 1; _vk_emit row
}
vk_menu_item() {  # vk_menu_item TITLE ACTION [symbol=...] [destructive:=true] [enabled:=false]: an entry of a menu (menu:= on a block)
  _VK_OUT=""; vk_q "$1"; local t=$REPLY; vk_q "$2"; _VK_OUT="{\"title\":$t,\"action\":$REPLY"; shift 2
  _vk_fields "$@" || return 1; print -rn -- "$_VK_OUT}"
}
vk_menu_separator() { print -rn -- '{"separator":true}' }

vk_empty() {  # vk_empty TEXT [title=...] [symbol=...] [role=...] [link=...]
  _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"text\":$REPLY"; shift; _vk_fields "$@" || return 1; _vk_emit empty
}
vk_banner() { _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"text\":$REPLY"; shift; _vk_fields "$@" || return 1; _vk_emit banner }   # vk_banner TEXT [role=warning] [symbol=...]
vk_status() { _VK_OUT=""; vk_q "$1"; _VK_OUT=",\"text\":$REPLY"; shift; _vk_fields "$@" || return 1; _vk_emit status }
vk_progress() {  # vk_progress [FRACTION 0..1] [title=...]: a bar; with no fraction, a busy one
  _VK_OUT=""
  if [[ -n $1 ]] && ! _vk_is_field "$1"; then   # a fraction (.5 is written 0.5, which JSON needs); text that is no number is refused
    if ! _vk_number "$1"; then print -u2 -r -- "vektor.zsh: vk_progress takes a fraction 0…1, not “$1”."; return 1; fi
    _VK_OUT=",\"progress\":$REPLY"; shift
  fi
  _vk_fields "$@" || return 1; _vk_emit progress
}
vk_spinner() {  # vk_spinner [TEXT] [id=...]: TEXT that itself looks like a field (a=b) must be passed as text=a=b
  _VK_OUT=""
  if [[ -n $1 ]] && ! _vk_is_field "$1"; then vk_q "$1"; _VK_OUT=",\"text\":$REPLY"; shift; fi
  _vk_fields "$@" || return 1; _vk_emit spinner
}

# A block view's description: vk_blocks_view REVISION BLOCK [header-title]. (The kinds of API 1 are plain objects: vk_obj.)
vk_description() {  # vk_description REVISION BLOCK [HEADER-TITLE]
  local header=""
  if [[ -n $3 ]]; then vk_q "$3"; header=",\"header\":{\"title\":$REPLY}"; fi
  print -rn -- "{\"revision\":$1$header,\"blocks\":$2}"
}
