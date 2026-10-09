#!/bin/zsh
# Todo — a sample Vektor plugin. Written in zsh, never Python.
#
# A todo list in a pane. Nothing in Vektor knows about todos: this script speaks the plugin protocol on stdin/stdout
# (`Content-Length` framed JSON), describes its list and its summary as data (a `list` view and a `detail` view), and
# answers what the user does — add, edit, check, reorder, delete — with a new description. Vektor draws it natively.
#
#   * The todos are a plain text file in the plugin's data folder (`$VEKTOR_PLUGIN_DATA/todos.list`), or in the folder
#     the "Storage location" setting names; "A list for each workspace" keeps one file per workspace. Each change is
#     written at once (to a temporary file, then moved over the real one), so a quit or a crash loses nothing.
#   * It starts no process and keeps nothing outside its data folder, so there is nothing to clean up on shutdown beyond a
#     half-written temporary file.
#   * Every description carries a `revision`; Vektor hands back, with each event, the revision the user was looking at. A
#     reorder made against a list that has since changed is ignored (and the list is described again), because "move
#     this before that" no longer means what the user saw.
#
# JSON is read with `plutil -extract` (a field per call) and written by hand through `j`, which
# escapes. Strings are bytes (LC_ALL=C), so `Content-Length` is a byte count.
export LC_ALL=C
setopt extended_glob
zmodload zsh/system zsh/datetime zsh/zselect

data=${VEKTOR_PLUGIN_DATA:-/tmp/vektor-todo}
mkdir -p "$data"
readonly US=$'\x1f'     # separates the fields of a line of the list (a tab is IFS-whitespace and would eat empty fields)

# --- State ---------------------------------------------------------------------------------------------------------
typeset -A S                         # settings by key
typeset -a ORDER OPEN FIN            # todo ids: all of them in the user's order; the open ones and the completed ones, as shown
typeset -A T_TEXT T_FIN T_AT         # text, 1 when completed, created-at
typeset body="" method="" msgid="" J=""
typeset WS_ID="" WS_NAME="" FILE=""
typeset -i REVISION=0 NEXT_ID=0

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

# --- Settings and the file -------------------------------------------------------------------------------------------
load_settings() {
  local key folder
  for key in storage showCompleted sort perWorkspace; do S[$key]=$(jx params.settings.$key); done
  WS_ID=$(jx params.workspace.id); WS_NAME=$(jx params.workspace.name)
  folder=${S[storage]:-$data}
  [[ -d $folder ]] || mkdir -p "$folder" 2>/dev/null || folder=$data
  if [[ ${S[perWorkspace]} == true && -n $WS_ID ]]; then
    FILE="$folder/todos-${WS_ID//[^A-Za-z0-9-]/_}.list"
  else
    FILE="$folder/todos.list"
  fi
}

load_todos() {
  ORDER=(); T_TEXT=(); T_FIN=(); T_AT=()
  [[ -f $FILE ]] || return 0
  local id fin at text
  while IFS=$US read -r id fin at text; do
    [[ -n $id && -n $text ]] || continue
    T_TEXT[$id]=$text; T_FIN[$id]=${fin:-0}; T_AT[$id]=${at:-0}
    ORDER+=$id
  done < "$FILE"
}

save_todos() {  # a temporary file, then moved over the real one: a crash never leaves half a list
  local id
  { for id in $ORDER; do print -r -- "${id}${US}${T_FIN[$id]}${US}${T_AT[$id]}${US}${T_TEXT[$id]}"; done } > "$FILE.new" && mv -f "$FILE.new" "$FILE"
}

clean() {  # one line, trimmed, at most 2000 bytes and valid UTF-8 → REPLY
  local t=${1//[$'\t\n\r\x1f']/ }
  t=${t## #}; t=${t%% #}
  [[ ${#t} -gt 2000 ]] && t=${t[1,2000]}
  REPLY=$(print -rn -- "$t" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
}

# --- What is shown ---------------------------------------------------------------------------------------------------
compute_display() {  # OPEN and FIN, in the order the Sort order setting asks for
  OPEN=(); FIN=()
  local id
  local -a base keyed
  case ${S[sort]:-manual} in
    newest) base=(${(Oa)ORDER}) ;;
    alphabetical)
      for id in $ORDER; do keyed+=("${T_TEXT[$id]}${US}${id}"); done
      keyed=(${(oi)keyed})
      for id in $keyed; do base+=${id##*$US}; done ;;
    *) base=($ORDER) ;;
  esac
  for id in $base; do
    if [[ ${T_FIN[$id]} == 1 ]]; then FIN+=$id; else OPEN+=$id; fi
  done
}

row_json() {
  local id=$1 title checked=false dim=false
  j "${T_TEXT[$id]}"; title=$J
  [[ ${T_FIN[$id]} == 1 ]] && { checked=true; dim=true }
  print -rn -- "{\"id\":\"$id\",\"title\":$title,\"checkbox\":{\"checked\":$checked,\"action\":\"toggle\"},\"edit\":\"edit\",\"delete\":\"delete\",\"dimmed\":$dim,\"menu\":[{\"title\":\"Edit\",\"symbol\":\"pencil\",\"action\":\"edit\"},{\"separator\":true},{\"title\":\"Delete\",\"symbol\":\"trash\",\"action\":\"delete\",\"destructive\":true}]}"
}

todos_json() {
  local id rows="" sep="" groups reorder=""
  for id in $OPEN; do rows+="$sep$(row_json $id)"; sep=","; done
  groups="{\"id\":\"open\",\"rows\":[$rows]}"
  if [[ ${S[showCompleted]} != false && $#FIN -gt 0 ]]; then
    rows=""; sep=""
    for id in $FIN; do rows+="$sep$(row_json $id)"; sep=","; done
    groups+=",{\"id\":\"done\",\"title\":\"Completed\",\"collapsible\":true,\"rows\":[$rows]}"
  fi
  # Rows move only in the user's own order: with another sort the position is not theirs to set.
  [[ ${S[sort]:-manual} == manual ]] && reorder=",\"reorder\":\"move\""
  print -rn -- "{\"revision\":$REVISION,\"header\":{\"title\":\"Todo\"},\"list\":{\"input\":{\"placeholder\":\"Add a todo…\",\"action\":\"add\"}$reorder,\"groups\":[$groups]},\"empty\":{\"title\":\"Nothing to do\",\"message\":\"Type a todo above and press Return.\",\"symbol\":\"checklist\"}}"
}

summary_json() {
  local open=$#OPEN fin=$#FIN total=$#ORDER list stored md subtitle clearEnabled=false
  if [[ ${S[perWorkspace]} == true && -n $WS_ID ]]; then list="Workspace “$WS_NAME”"; else list="All workspaces"; fi
  stored=${FILE/#$HOME/\~}
  subtitle="$open open, $fin completed"
  (( fin > 0 )) && clearEnabled=true
  md=$'## Keys\n\n- **Return** adds a todo from the field at the top, or edits the selected one\n- **Space** checks it off\n- **⌥↑** and **⌥↓** move it; so does dragging\n- **Delete** removes it\n- **Esc** closes the list'
  local j_subtitle j_list j_stored j_md
  j "$subtitle"; j_subtitle=$J
  j "$list"; j_list=$J
  j "$stored"; j_stored=$J
  j "$md"; j_md=$J
  print -rn -- "{\"revision\":$REVISION,\"detail\":{\"heading\":{\"title\":\"Todo\",\"subtitle\":$j_subtitle,\"symbol\":\"checklist\"},\"rows\":[{\"label\":\"Open\",\"value\":\"$open\"},{\"label\":\"Completed\",\"value\":\"$fin\"},{\"label\":\"Total\",\"value\":\"$total\"},{\"label\":\"List\",\"value\":$j_list},{\"label\":\"Stored in\",\"value\":$j_stored}],\"markdown\":$j_md,\"actions\":[{\"title\":\"Clear Completed\",\"symbol\":\"trash\",\"action\":\"clear\",\"enabled\":$clearEnabled}]}}"
}

refresh() {  # every view is described again, with the next revision
  REVISION+=1
  compute_display
  notify view/update "{\"view\":\"todos\",\"description\":$(todos_json)}"
  notify view/update "{\"view\":\"summary\",\"description\":$(summary_json)}"
}

# --- Changing the list -----------------------------------------------------------------------------------------------
add_todo() {
  clean "$1"
  [[ -n $REPLY ]] || return 1
  NEXT_ID+=1
  local id="t${EPOCHSECONDS}${RANDOM}${NEXT_ID}"
  T_TEXT[$id]=$REPLY; T_FIN[$id]=0; T_AT[$id]=$EPOCHSECONDS
  ORDER+=$id
}

remove_todo() {
  local id=$1
  ORDER=(${ORDER:#$id})
  unset "T_TEXT[$id]" "T_FIN[$id]" "T_AT[$id]"
}

move_todo() {  # id before-id (empty: the end of its group): "this one goes before that one"
  local id=$1 before=$2 at i last=0
  [[ -n ${T_TEXT[$id]} && $id != $before ]] || return 1
  ORDER=(${ORDER:#$id})
  at=${ORDER[(i)$before]}
  if [[ -n $before && $at -le $#ORDER ]]; then
    ORDER[at,at-1]=($id)
  else
    for (( i = 1; i <= $#ORDER; i++ )); do [[ ${T_FIN[${ORDER[i]}]} == ${T_FIN[$id]} ]] && last=$i; done
    if (( last > 0 )); then ORDER[last+1,last]=($id); else ORDER+=$id; fi
  fi
}

on_event() {
  local action card value before rev id
  action=$(jx params.action); card=$(jx params.card); value=$(jx params.value)
  before=$(jx params.before); rev=$(jx params.revision)
  case $action in
    add)
      add_todo "$value" && { save_todos; refresh } ;;
    toggle)
      [[ -n ${T_TEXT[$card]} ]] || return 0
      if [[ $value == true ]]; then T_FIN[$card]=1; else T_FIN[$card]=0; fi
      save_todos; refresh ;;
    edit)
      clean "$value"
      [[ -n ${T_TEXT[$card]} && -n $REPLY ]] || return 0
      T_TEXT[$card]=$REPLY
      save_todos; refresh ;;
    delete)
      [[ -n ${T_TEXT[$card]} ]] || return 0
      remove_todo $card; save_todos; refresh ;;
    move)
      # A reorder made against an older list is ignored: describe the list again so the user sees what is true.
      if [[ -n $rev ]] && (( rev < REVISION )); then refresh; return 0; fi
      move_todo $card "$before" && { save_todos; refresh } ;;
    clear)
      for id in $ORDER; do [[ ${T_FIN[$id]} == 1 ]] && remove_todo $id; done
      save_todos; refresh ;;
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
  if [[ -z $length ]]; then
    # End of file: Vektor is gone. Nothing to stop; remove a half-written temporary file.
    rm -f "$FILE.new" 2>/dev/null
    exit 0
  fi
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
      load_settings
      load_todos
      reply $msgid '{}'
      refresh ;;
    shutdown)
      rm -f "$FILE.new" 2>/dev/null
      reply $msgid '{}'
      exit 0 ;;
    settingsChanged)
      previous=$FILE
      load_settings
      [[ $FILE != $previous ]] && load_todos
      refresh ;;
    view/opened) refresh ;;
    view/closed) ;;
    view/event) on_event ;;
    ping) reply $msgid '{}' ;;
    '$/cancel') ;;
    '') ;;
    *) [[ -n $msgid ]] && refuse $msgid "unknown method" ;;
  esac
done
