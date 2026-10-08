#!/bin/zsh
# Cloudflare Tunnel — a sample Vektor plugin. Written in zsh, never Python.
#
# It publishes a file, a folder or a local port under a public https://….trycloudflare.com address, using the user's own
# `cloudflared`. Everything here is an instance of the general plugin contract, nothing in Vektor knows about tunnels:
#
#   * It speaks Vektor's protocol on stdin/stdout (`Content-Length` framed JSON) and describes its view, its sidebar badge
#     and its dialogs as data; Vektor draws them natively.
#   * Every process it starts (the file server `serve.zsh`, `cloudflared`) is started through Vektor's Processes service,
#     so Vektor tracks them per plugin and ends them when Vektor quits and when the plugin is disabled, removed or
#     updated. Nothing here outlives Vektor. While Vektor runs, a running tunnel keeps running with its view closed.
#   * Quick tunnels are ephemeral — they vanish when their connector stops — so there is nothing remote to delete on
#     `shutdown`; the plugin stops what it started and removes its own session files.
#   * The list of tunnels is `data/tunnels.list`; after a restart every tunnel is Stopped and can be started again.
#
# JSON is read with `plutil -extract` (a field per call) and written by hand through `j`, which escapes.
# Strings are bytes (LC_ALL=C) so `Content-Length` is a byte count.
export LC_ALL=C
setopt extended_glob
zmodload zsh/system zsh/datetime zsh/zselect zsh/net/tcp

here=${0:A:h}
data=${VEKTOR_PLUGIN_DATA:-/tmp/vektor-cloudflare-tunnel}
session=${VEKTOR_PLUGIN_SESSION:-}
mkdir -p "$data"
readonly US=$'\x1f'     # separates the parts of a request's tag, and the fields of the tunnel list

# --- State ---------------------------------------------------------------------------------------------------------
typeset -A S                                  # settings by key
typeset -a ORDER                              # tunnel ids, newest first
typeset -A TUN_NAME TUN_KIND TUN_TARGET TUN_EXTRA TUN_STATUS TUN_URL TUN_REASON TUN_PORT TUN_SRV TUN_CF TUN_SINCE
typeset -A PENDING                            # request id → what to do with its answer
typeset -A PROC                               # processID → "<tunnel id>:srv" or "<tunnel id>:cf"
typeset -A HELD                               # lines of a process that arrived before the answer that names it
typeset -i NEXT=1000
typeset body="" method="" msgid="" J="" REQ_ID=""
typeset CF="" CF_VERSION="" CF_NOTE=""
typeset -i STARTING_LIMIT=45

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
request() {  # method params-json [tag] → REQ_ID
  NEXT+=1; REQ_ID=$NEXT
  [[ -n $3 ]] && PENDING[$REQ_ID]=$3
  send "{\"api\":1,\"id\":$REQ_ID,\"method\":\"$1\",\"params\":$2}"
}
reply() { send "{\"api\":1,\"id\":$1,\"result\":$2}" }
refuse() { j "$2"; send "{\"api\":1,\"id\":$1,\"error\":{\"message\":$J}}" }
plog() { j "$1"; notify log "{\"level\":\"info\",\"message\":$J}" }
toast() { j "$1"; notify toast "{\"message\":$J}" }
alert() { local t m; j "$1"; t=$J; j "$2"; m=$J; notify alert "{\"title\":$t,\"message\":$m}" }
jx() { print -rn -- "$body" | plutil -extract "$1" raw -o - - 2>/dev/null }

# --- Settings and cloudflared ----------------------------------------------------------------------------------------
load_settings() {
  local key
  for key in cloudflared prefix openAfter copyURL extraArguments serverPort; do S[$key]=$(jx params.settings.$key); done
}

find_cloudflared() {
  CF=""; CF_VERSION=""; CF_NOTE=""
  local candidate=${S[cloudflared]} dir out
  if [[ -n $candidate ]]; then
    if [[ -x $candidate && ! -d $candidate ]]; then CF=$candidate; else CF_NOTE="nothing runnable at $candidate"; fi
  else
    for dir in ${(s.:.)PATH} /opt/homebrew/bin /usr/local/bin; do
      [[ -x $dir/cloudflared && ! -d $dir/cloudflared ]] && { CF=$dir/cloudflared; break }
    done
    [[ -n $CF ]] || CF_NOTE="cloudflared was not found on this Mac"
  fi
  if [[ -n $CF ]]; then
    out=$("$CF" --version 2>&1 </dev/null)
    [[ $out =~ 'version ([0-9][^ ]*)' ]] && CF_VERSION=$match[1]
  fi
}

publish_cloudflared_status() {  # the line under the setting
  local t d
  if [[ -n $CF ]]; then
    j "cloudflared found"; t=$J
    j "${CF_VERSION:+version }${CF_VERSION}"; d=$J
    notify settings/status "{\"key\":\"cloudflared\",\"text\":$t,\"tone\":\"positive\",\"detail\":$d}"
  else
    j "cloudflared not found"; t=$J
    j "$CF_NOTE"; d=$J
    notify settings/status "{\"key\":\"cloudflared\",\"text\":$t,\"tone\":\"warning\",\"detail\":$d}"
  fi
}

missing_message() {
  print -rn -- "cloudflared was not found ($CF_NOTE). Set its location in Settings ▸ Plugins, or install it."
}

# --- The list of tunnels -------------------------------------------------------------------------------------------
save_tunnels() {
  local id out
  { for id in ${(Oa)ORDER}; do
      print -r -- "${id}${US}${TUN_NAME[$id]}${US}${TUN_KIND[$id]}${US}${TUN_TARGET[$id]}${US}${TUN_EXTRA[$id]}"
    done } > "$data/tunnels.list.new" && mv -f "$data/tunnels.list.new" "$data/tunnels.list"
}

load_tunnels() {
  ORDER=()
  local id name kind target extra
  [[ -f $data/tunnels.list ]] || return 0
  while IFS=$US read -r id name kind target extra; do
    [[ -n $id && -n $name ]] || continue
    TUN_NAME[$id]=$name; TUN_KIND[$id]=$kind; TUN_TARGET[$id]=$target; TUN_EXTRA[$id]=$extra
    TUN_STATUS[$id]=Stopped; TUN_URL[$id]=""; TUN_REASON[$id]=""
    ORDER=($id $ORDER)   # the file is oldest first, so the newest ends up first
  done < "$data/tunnels.list"
}

mark_running() { [[ -n $session && -d $session ]] && print -r -- "${TUN_CF[$1]} ${TUN_SRV[$1]}" > "$session/tunnel-$1" }
unmark() { [[ -n $session ]] && rm -f "$session/tunnel-$1" }

# --- The view, the badge ---------------------------------------------------------------------------------------------
card_json() {
  local id=$1 kind=${TUN_KIND[$1]} st=${TUN_STATUS[$1]} url=${TUN_URL[$1]}
  local icon tone="neutral" action="" first second buttons="" menu live title jid t u
  case $kind in folder) icon=folder ;; file) icon=doc ;; *) icon=network ;; esac
  case $st in Running) tone=positive; action=open ;; Failed) tone=error; action=start ;; Stopped) action=start ;; esac
  j "${TUN_NAME[$id]}"; title=$J
  j "$id"; jid=$J
  case $st in
    Running) j "$url"; u=$J; first="{\"text\":$u,\"link\":$u}" ;;
    Starting) j "Waiting for cloudflared to report the public address…"; first="{\"text\":$J}" ;;
    Failed) j "${TUN_REASON[$id]:-It could not be started.}"; first="{\"text\":$J}" ;;
    *) j "Not running"; first="{\"text\":$J}" ;;
  esac
  if [[ $kind == port ]]; then j "localhost:${TUN_TARGET[$id]}"; else j "${TUN_TARGET[$id]}"; fi
  second="{\"text\":$J}"
  [[ $st == Stopped || $st == Failed ]] && buttons='{"symbol":"play.fill","title":"Start","action":"start"}'
  live=false; [[ $st == Running ]] && live=true
  local runnable=false; [[ $st == Starting || $st == Running ]] && runnable=true
  menu="{\"title\":\"Copy URL\",\"symbol\":\"doc.on.doc\",\"action\":\"copyURL\",\"enabled\":$live},"
  menu+="{\"title\":\"Open in Browser\",\"symbol\":\"safari\",\"action\":\"open\",\"enabled\":$live},"
  [[ $kind != port ]] && menu+="{\"title\":\"Reveal in Pane\",\"symbol\":\"folder\",\"action\":\"reveal\"},"
  menu+="{\"separator\":true},{\"title\":\"Stop\",\"symbol\":\"stop.fill\",\"action\":\"stop\",\"enabled\":$runnable},"
  menu+="{\"title\":\"Restart\",\"symbol\":\"arrow.clockwise\",\"action\":\"restart\"},"
  menu+="{\"separator\":true},{\"title\":\"Remove\",\"symbol\":\"trash\",\"action\":\"remove\",\"destructive\":true}"
  t="{\"id\":$jid,\"symbol\":\"$icon\",\"title\":$title,\"pill\":{\"label\":\"$st\",\"tone\":\"$tone\"},"
  t+="\"lines\":[$first,$second],"
  [[ -n $action ]] && t+="\"action\":\"$action\","
  t+="\"buttons\":[$buttons],\"menu\":[$menu]}"
  print -rn -- "$t"
}

view_json() {
  local id cards="" banner="" sep=""
  for id in $ORDER; do cards+="$sep$(card_json $id)"; sep=","; done
  if [[ -z $CF ]]; then
    j "$(missing_message)"
    banner="\"banner\":{\"text\":$J,\"tone\":\"warning\",\"linkTitle\":\"Install cloudflared\",\"link\":\"https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/\"},"
  fi
  print -rn -- "{\"header\":{\"title\":\"Tunnels\",\"primary\":{\"title\":\"New Tunnel\",\"symbol\":\"plus\",\"action\":\"new\"},\"search\":{\"placeholder\":\"Search tunnels…\"}},${banner}\"cards\":[$cards],\"empty\":{\"title\":\"No tunnels yet\",\"message\":\"Publish a folder, a file or a local port under a public Cloudflare address.\",\"symbol\":\"point.3.connected.trianglepath.dotted\",\"button\":{\"title\":\"New Tunnel\",\"symbol\":\"plus\",\"action\":\"new\"}}}"
}

push_view() { notify view/update "{\"view\":\"tunnels\",\"description\":$(view_json)}" }

push_badge() {
  integer running=0 failed=0
  local id
  for id in $ORDER; do
    [[ ${TUN_STATUS[$id]} == Running ]] && running+=1
    [[ ${TUN_STATUS[$id]} == Failed ]] && failed+=1
  done
  if (( running > 0 )); then
    local word="tunnels"; (( running == 1 )) && word="tunnel"
    notify sidebar/badge "{\"entry\":\"tunnels\",\"count\":$running,\"tone\":\"positive\",\"label\":\"$running $word running\"}"
  elif (( failed > 0 )); then
    notify sidebar/badge '{"entry":"tunnels","text":"Failed","tone":"error","label":"A tunnel failed"}'
  else
    notify sidebar/badge '{"entry":"tunnels"}'
  fi
}

refresh() { push_view; push_badge }

# --- Starting and stopping ---------------------------------------------------------------------------------------------
free_port() {  # first port from the setting upward that nothing listens on (nor is waiting out a close) → REPLY
  integer p=${${S[serverPort]:-8787}%%.*} tries=0
  local id
  while (( tries++ < 300 && p <= 65535 )); do
    local used=""
    for id in $ORDER; do [[ ${TUN_PORT[$id]} == $p && ${TUN_STATUS[$id]} == (Starting|Running) ]] && used=1; done
    if [[ -z $used ]] && ztcp -l $p 2>/dev/null; then
      ztcp -c $REPLY
      REPLY=$p
      return 0
    fi
    p+=1
  done
  return 1
}

stop_children() {
  local id=$1 pid
  for pid in ${TUN_CF[$id]} ${TUN_SRV[$id]}; do
    [[ -n $pid ]] || continue
    j "$pid"; request process/stop "{\"processID\":$J}" ignore
    unset "PROC[$pid]"
  done
  TUN_CF[$id]=""; TUN_SRV[$id]=""
  unmark $id
}

fail_tunnel() {  # id reason — a tunnel that could not run: its card says why, and an alert
  local id=$1
  [[ -n ${TUN_NAME[$id]} ]] || return 0
  stop_children $id
  TUN_STATUS[$id]=Failed; TUN_URL[$id]=""; TUN_REASON[$id]=$2
  alert "Tunnel “${TUN_NAME[$id]}” failed" "$2"
  refresh
}

start_cloudflared() {
  local id=$1 args word
  args="\"tunnel\",\"--no-autoupdate\",\"--url\",\"http://localhost:${TUN_PORT[$id]}\""
  for word in ${=TUN_EXTRA[$id]}; do j "$word"; args+=",$J"; done
  j "$CF"
  request process/start "{\"executable\":$J,\"arguments\":[$args]}" "cf${US}$id"
}

start_tunnel() {
  local id=$1 kind=${TUN_KIND[$1]} target=${TUN_TARGET[$1]}
  TUN_STATUS[$id]=Starting; TUN_URL[$id]=""; TUN_REASON[$id]=""; TUN_SINCE[$id]=$EPOCHSECONDS
  TUN_SRV[$id]=""; TUN_CF[$id]=""
  find_cloudflared
  publish_cloudflared_status
  if [[ -z $CF ]]; then fail_tunnel $id "$(missing_message)"; return 0; fi
  if [[ $kind == port ]]; then
    TUN_PORT[$id]=$target
    start_cloudflared $id
  else
    if [[ ! -e $target ]]; then fail_tunnel $id "“${target:t}” no longer exists."; return 0; fi
    if ! free_port; then fail_tunnel $id "No free port was found for the local web server."; return 0; fi
    TUN_PORT[$id]=$REPLY
    local script server_target
    j "$here/serve.zsh"; script=$J
    j "$target"; server_target=$J
    request process/start "{\"executable\":\"/bin/zsh\",\"arguments\":[$script,\"${TUN_PORT[$id]}\",$server_target]}" "srv${US}$id"
  fi
  refresh
}

stop_tunnel() {
  local id=$1
  stop_children $id
  TUN_STATUS[$id]=Stopped; TUN_URL[$id]=""; TUN_REASON[$id]=""
  refresh
}

create_tunnel() {  # name kind target extra → REPLY is the id
  local id="t${EPOCHSECONDS}${RANDOM}"
  TUN_NAME[$id]=${1//[$'\t\n\r']/ }; TUN_KIND[$id]=$2; TUN_TARGET[$id]=${3//[$'\t\n\r']/ }; TUN_EXTRA[$id]=${4//[$'\t\n\r']/ }
  TUN_STATUS[$id]=Stopped; TUN_URL[$id]=""; TUN_REASON[$id]=""
  ORDER=($id $ORDER)
  save_tunnels
  REPLY=$id
}

remove_tunnel() {
  local id=$1
  stop_children $id
  ORDER=(${ORDER:#$id})
  unset "TUN_NAME[$id]" "TUN_KIND[$id]" "TUN_TARGET[$id]" "TUN_EXTRA[$id]" "TUN_STATUS[$id]" "TUN_URL[$id]" "TUN_REASON[$id]" "TUN_PORT[$id]" "TUN_SINCE[$id]"
  save_tunnels
  refresh
}

announce() {  # a tunnel just became Running
  local id=$1 u
  mark_running $id
  toast "Tunnel “${TUN_NAME[$id]}” is live: ${TUN_URL[$id]}"
  if [[ ${S[copyURL]} == true ]]; then
    j "${TUN_URL[$id]}"; notify clipboard/writeText "{\"text\":$J}"
  fi
  if [[ ${S[openAfter]} == true ]]; then
    j "${TUN_URL[$id]}"; request openURL "{\"url\":$J}" ignore
  fi
  refresh
}

# --- Dialogs ---------------------------------------------------------------------------------------------------------
advanced_section() {  # → JSON of the collapsible section
  print -rn -- '{"id":"advanced","title":"Advanced Options","fields":[{"key":"extra","kind":"text","label":"Additional arguments","placeholder":"e.g. --loglevel info","help":"Passed to cloudflared after its own arguments."}]}'
}

show_publish_dialog() {  # path of a file or folder
  local path=$1 name=${1:t} what=file hint sub title nm p h
  [[ -d $path ]] && what=folder
  hint="This $what will be served over a local web server."
  j "Create a public URL for “$name” using Cloudflare Tunnel."; sub=$J
  j "$name"; nm=$J
  j "$path"; p=$J
  j "$hint"; h=$J
  request dialog/show "{\"title\":\"Publish via Cloudflare Tunnel\",\"subtitle\":$sub,\"fields\":[{\"key\":\"name\",\"kind\":\"text\",\"label\":\"Name\",\"default\":$nm,\"required\":true,\"help\":\"How the tunnel is named in the Tunnels list.\"},{\"key\":\"path\",\"kind\":\"readOnlyPath\",\"label\":\"Local path\",\"path\":$p,\"help\":$h}],\"sections\":[$(advanced_section)],\"primary\":\"Start Tunnel\"}" "dialog${US}publish${US}$path"
}

show_port_dialog() {
  request dialog/show "{\"title\":\"Publish Port via Cloudflare Tunnel\",\"subtitle\":\"Create a public URL for a service on this Mac, using Cloudflare Tunnel.\",\"fields\":[{\"key\":\"port\",\"kind\":\"number\",\"label\":\"Port\",\"integer\":true,\"min\":1,\"max\":65535,\"required\":true,\"help\":\"The service must already be listening on localhost at this port.\"},{\"key\":\"name\",\"kind\":\"text\",\"label\":\"Name\",\"help\":\"Optional. Left empty, the tunnel is named after its port.\"}],\"sections\":[$(advanced_section)],\"primary\":\"Start Tunnel\"}" "dialog${US}port${US}"
}

show_new_dialog() {  # [message about the last try]
  local sub
  j "${1:-Choose a folder, a file or a port: fill in one of the three.}"; sub=$J
  request dialog/show "{\"title\":\"New Tunnel\",\"subtitle\":$sub,\"fields\":[{\"key\":\"kind\",\"kind\":\"choice\",\"style\":\"radio\",\"label\":\"Publish\",\"options\":[{\"value\":\"folder\",\"title\":\"A folder\"},{\"value\":\"file\",\"title\":\"A file\"},{\"value\":\"port\",\"title\":\"A port\"}],\"default\":\"folder\",\"required\":true},{\"key\":\"folder\",\"kind\":\"path\",\"pathKind\":\"folder\",\"label\":\"Folder\"},{\"key\":\"file\",\"kind\":\"path\",\"pathKind\":\"file\",\"label\":\"File\"},{\"key\":\"port\",\"kind\":\"number\",\"label\":\"Port\",\"integer\":true,\"min\":1,\"max\":65535},{\"key\":\"name\",\"kind\":\"text\",\"label\":\"Name\",\"help\":\"Optional. Left empty, the tunnel is named after what it publishes.\"}],\"sections\":[$(advanced_section)],\"primary\":\"Start Tunnel\"}" "dialog${US}new${US}"
}

on_dialog_answer() {  # $1 = kind of dialog, $2 = its argument (the path), $body = the answer
  local what=$1 arg=$2 name extra kind target
  [[ $(jx result.result) == submit ]] || return 0
  name=$(jx result.values.name)
  extra=$(jx result.values.extra)
  case $what in
    publish)
      kind=file; [[ -d $arg ]] && kind=folder
      target=$arg; [[ -n $name ]] || name=${arg:t} ;;
    port)
      kind=port; target=$(jx result.values.port)
      [[ -n $name ]] || name="${S[prefix]}port-$target" ;;
    new)
      kind=$(jx result.values.kind)
      case $kind in
        folder) target=$(jx result.values.folder) ;;
        file) target=$(jx result.values.file) ;;
        port) target=$(jx result.values.port) ;;
      esac
      if [[ -z $target ]]; then show_new_dialog "Fill in the $kind to publish."; return 0; fi
      [[ -n $name ]] || { [[ $kind == port ]] && name="${S[prefix]}port-$target" || name=${target:t} } ;;
    *) return 0 ;;
  esac
  create_tunnel "$name" "$kind" "$target" "$extra"
  start_tunnel $REPLY
}

# --- Answers and events ------------------------------------------------------------------------------------------------
replay_held() {  # output that arrived before we knew whose it was
  local pid=$1 line
  [[ -n ${HELD[$pid]} ]] || return 0
  local held=${HELD[$pid]}
  unset "HELD[$pid]"
  for line in ${(f)held}; do handle_line ${PROC[$pid]%%:*} ${PROC[$pid]#*:} "$line"; done
}

on_response() {
  local tag=${PENDING[$msgid]} what id err pid
  unset "PENDING[$msgid]"
  [[ -n $tag ]] || return 0
  what=${tag%%$US*}
  if [[ $what == dialog ]]; then
    local rest=${tag#dialog$US}
    err=$(jx error.message)
    if [[ -n $err ]]; then toast "Not shown: $err"; return 0; fi
    on_dialog_answer ${rest%%$US*} ${rest#*$US}
    return 0
  fi
  [[ $what == (srv|cf) ]] || return 0
  id=${tag#*$US}
  [[ -n ${TUN_NAME[$id]} ]] || return 0
  err=$(jx error.message)
  pid=$(jx result.processID)
  # The tunnel was stopped, or removed, while this was starting: end what just began.
  if [[ ${TUN_STATUS[$id]} != Starting ]]; then
    if [[ -n $pid ]]; then j "$pid"; request process/stop "{\"processID\":$J}" ignore; fi
    return 0
  fi
  case $what in
    srv)
      if [[ -n $err ]]; then fail_tunnel $id "The local web server could not start: $err"; return 0; fi
      TUN_SRV[$id]=$pid; PROC[$pid]="${id}:srv"; replay_held $pid
      start_cloudflared $id ;;
    cf)
      if [[ -n $err ]]; then fail_tunnel $id "cloudflared could not be started: $err"; return 0; fi
      TUN_CF[$id]=$pid; PROC[$pid]="${id}:cf"; replay_held $pid ;;
  esac
}

handle_line() {  # tunnel id, role (srv|cf), one line of its output
  local id=$1 role=$2 text=$3
  [[ -n ${TUN_NAME[$id]} && $role == cf ]] || return 0
  if [[ $text =~ 'https://[A-Za-z0-9-]+\.trycloudflare\.com' ]]; then
    if [[ ${TUN_STATUS[$id]} == Starting ]]; then
      TUN_URL[$id]=$MATCH; TUN_STATUS[$id]=Running
      announce $id
    fi
  elif [[ $text == *ERR* ]]; then
    TUN_REASON[$id]=${text##*ERR }
  fi
}

on_output() {
  local pid text owner
  pid=$(jx params.processID); text=$(jx params.text)
  owner=${PROC[$pid]}
  if [[ -z $owner ]]; then
    # Not yet named by the answer that carries its id: keep the last lines.
    HELD[$pid]="${HELD[$pid]}$text"$'\n'
    return 0
  fi
  handle_line ${owner%%:*} ${owner#*:} "$text"
}

on_exited() {
  local pid status_code owner id role
  pid=$(jx params.processID); status_code=$(jx params.status)
  owner=${PROC[$pid]}
  [[ -n $owner ]] || return 0      # one we stopped ourselves, or an unknown one
  unset "PROC[$pid]"
  id=${owner%%:*}; role=${owner#*:}
  [[ -n ${TUN_NAME[$id]} ]] || return 0
  [[ ${TUN_STATUS[$id]} == (Starting|Running) ]] || return 0
  if [[ $role == srv ]]; then
    TUN_SRV[$id]=""
    fail_tunnel $id "The local web server stopped (exit status ${status_code:-?})."
  else
    TUN_CF[$id]=""
    if [[ ${TUN_STATUS[$id]} == Starting ]]; then
      fail_tunnel $id "${TUN_REASON[$id]:-cloudflared quit before it gave a public address (exit status ${status_code:-?}).}"
    else
      fail_tunnel $id "cloudflared stopped (exit status ${status_code:-?})."
    fi
  fi
}

on_view_event() {
  local action card url
  action=$(jx params.action); card=$(jx params.card)
  if [[ $action == new ]]; then show_new_dialog; return 0; fi
  [[ -n ${TUN_NAME[$card]} ]] || return 0
  case $action in
    open)
      url=${TUN_URL[$card]}
      if [[ -n $url ]]; then j "$url"; request openURL "{\"url\":$J}" ignore; fi ;;
    copyURL)
      if [[ -n ${TUN_URL[$card]} ]]; then
        j "${TUN_URL[$card]}"; notify clipboard/writeText "{\"text\":$J}"
        toast "Copied the address of “${TUN_NAME[$card]}”"
      fi ;;
    reveal)
      if [[ ${TUN_KIND[$card]} != port ]]; then j "${TUN_TARGET[$card]}"; request reveal "{\"path\":$J}" ignore; fi ;;
    start) [[ ${TUN_STATUS[$card]} == (Stopped|Failed) ]] && start_tunnel $card ;;
    stop) stop_tunnel $card ;;
    restart) stop_tunnel $card; start_tunnel $card ;;
    remove) remove_tunnel $card ;;
  esac
}

on_invoke() {
  local command target
  command=$(jx params.command)
  find_cloudflared
  publish_cloudflared_status
  if [[ -z $CF ]]; then refuse $msgid "$(missing_message)"; push_view; return 0; fi
  case $command in
    publish)
      target=$(jx params.target.items.0.path)
      [[ -n $target ]] || { refuse $msgid "Choose a file or a folder."; return 0 }
      reply $msgid '{}'
      show_publish_dialog "$target" ;;
    publishPort)
      reply $msgid '{}'
      show_port_dialog ;;
    *) refuse $msgid "This plugin has no command “$command”." ;;
  esac
}

tick() {  # once a second while idle: a tunnel that never reports its address is failed
  local id
  for id in $ORDER; do
    if [[ ${TUN_STATUS[$id]} == Starting ]] && (( EPOCHSECONDS - ${TUN_SINCE[$id]:-$EPOCHSECONDS} > STARTING_LIMIT )); then
      fail_tunnel $id "cloudflared did not report a public address within $STARTING_LIMIT seconds."
    fi
  done
}

cleanup() {  # shutdown, or Vektor's end of the pipe: stop what we started and remove our session files
  local id
  for id in $ORDER; do
    [[ ${TUN_STATUS[$id]} == (Starting|Running) ]] && stop_children $id
  done
  [[ -n $session ]] && rm -f "$session"/tunnel-*(N)
}

# --- Main loop -------------------------------------------------------------------------------------------------------
while true; do
  if ! zselect -t 100 0 2>/dev/null; then tick; continue; fi
  length=""
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z $line ]] && break
    [[ $line == (#i)content-length:* ]] && length=${${line#*:}// /}
  done
  if [[ -z $length ]]; then
    # End of file: Vektor is gone. Clean up like a quit.
    cleanup
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
      load_tunnels
      find_cloudflared
      [[ $body == *'"previousSessionEndedUncleanly":true'* ]] && plog "Vektor did not quit cleanly last time. Quick tunnels vanish with their connector, and Vektor ended what was left; nothing remains to remove."
      [[ -n $session ]] && rm -f "$session"/tunnel-*(N)
      reply $msgid '{}'
      publish_cloudflared_status
      refresh ;;
    shutdown)
      cleanup
      reply $msgid '{}'
      exit 0 ;;
    settingsChanged)
      load_settings
      find_cloudflared
      publish_cloudflared_status
      push_view ;;
    invoke) on_invoke ;;
    view/opened)
      find_cloudflared
      publish_cloudflared_status
      refresh ;;
    view/closed) ;;
    view/event) on_view_event ;;
    process/output) on_output ;;
    process/exited) on_exited ;;
    ping) reply $msgid '{}' ;;
    '$/cancel') ;;
    '') on_response ;;
    *) [[ -n $msgid ]] && refuse $msgid "unknown method" ;;
  esac
done
