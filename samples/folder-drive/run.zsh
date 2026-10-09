#!/bin/zsh
# Folder Drive — a sample Vektor location plugin. Written in zsh, never Python.
#
# A location plugin lets Vektor browse somewhere it has no code for. Nothing in Vektor knows about this drive: it speaks the
# plugin protocol on stdin/stdout (`Content-Length` framed JSON) and answers the `location/*` requests. Vektor draws the pane,
# runs the transfers (with the collision prompt and progress), Preview, Disk Space and Convert, and reads what this location
# can do from `plugin.json` ▸ `contributes.locations[].capabilities` — this script holds no logic for any of those.
#
#   * A connection is a folder under /tmp (its `root` value). A place's `remotePath` is a path inside it: absolute, `/`-separated,
#     no trailing slash except for the root itself. `.`, `..`, empty components and links that lead out of the folder are
#     refused, and a change acts on a link, never on its target (`resolve`).
#   * Files never cross the pipe as bytes. For a read Vektor names a file and this script writes into it; for a write Vektor
#     names a file and this script stores its bytes (`serve_read`, `serve_write`).
#   * There is no trash: `delete` is permanent, which is why `plugin.json` declares `"trash": false` and Vektor confirms every
#     delete before it asks. Vektor checks by listing afterwards that the item is gone, so say so only when it is.
#   * `readonly` is a second location of this plugin (scheme `folder-drive-ro`); `connection.type` tells them apart.
#   * Every request is appended to `audit.log` in the data folder: method and path, never a secret.
#
# JSON is read with `plutil -extract` (a field per call) and written by hand through `j`, which escapes. Strings are bytes
# (LC_ALL=C), so `Content-Length` is a byte count.
export LC_ALL=C
setopt extended_glob null_glob
zmodload zsh/system zsh/stat

data=${VEKTOR_PLUGIN_DATA:-/tmp/vektor-folder-drive}
mkdir -p "$data"
readonly ALLOWED=/private/tmp     # connections are limited to /tmp (the physical path: /tmp is a link on macOS)
typeset -A ROOTS KIND             # per connection id: its folder (physical path) and its location id
typeset body="" J=""

# --- Wire ------------------------------------------------------------------------------------------------------------
j() {  # JSON string literal of $1, in $J
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  s=${s//[$'\001'-$'\037']/ }
  J="\"$s\""
}
send() { printf 'Content-Length: %d\r\n\r\n%s' ${#1} "$1" }
reply() { send "{\"api\":1,\"id\":$1,\"result\":$2}" }
refuse() { j "$2"; send "{\"api\":1,\"id\":$1,\"error\":{\"message\":$J}}" }   # the sentence Vektor shows
jx() { print -rn -- "$body" | plutil -extract "$1" raw -o - - 2>/dev/null }

# --- Paths -----------------------------------------------------------------------------------------------------------
# The item on this Mac for (connection, remotePath), in $REPLY. Fails — and the caller refuses — unless the path stays inside
# the connection's folder:
#   * every component is a real name: an empty one, `.` or `..` is refused. `//` and `/.` would otherwise name the
#     connection's folder itself, and a delete of either removed the whole folder (review, 2026-10-05);
#   * the folders above the item are resolved through links and must stay inside;
#   * the item itself is NOT followed, so a change (delete, rename, move, write) acts on a link and never on what it points
#     to — deleting a link to a folder must not delete that folder's files. `follow` (list and read, which open what a link
#     points to) also requires the item's target to be inside;
#   * `.access-code` is this plugin's own file, never an item of the drive (it is not listed either).
resolve() {  # connection remotePath [follow]
  local root=${ROOTS[$1]} remote=${2%/} part parent
  [[ -n $root && $2 == /* ]] || return 1
  [[ -z $remote ]] && { REPLY=$root; return 0 }           # "/" — the connection's folder
  for part in "${(@s:/:)${remote#/}}"; do
    [[ -n $part && $part != . && $part != .. && $part != .access-code ]] || return 1
  done
  parent=$root${remote:h}
  parent=${parent:A}                                     # :A resolves links, like realpath(3)
  inside $parent $root || return 1
  REPLY=$parent/${remote:t}
  [[ $3 != follow ]] || inside ${REPLY:A} $root
}

inside() { [[ $1 == $2 || $1 == $2/* ]] }  # path folder → whether the path is the folder or in it

isRoot() { [[ $1 == ${ROOTS[$2]} ]] }       # path connection → whether the path is the connection's folder

writable() {  # id connection → refuses on a read-only connection
  [[ ${KIND[$2]} == readonly ]] || return 0
  refuse $1 "This connection is read only."
  return 1
}

# --- Requests --------------------------------------------------------------------------------------------------------
serve_connect() {  # id connection
  local id=$1 conn=$2 root=$(jx params.connection.values.root) secret=$(jx params.connection.secret) physical code
  [[ -n $root ]] || { refuse $id "Enter the folder this connection should show."; return }
  physical=${root:A}
  [[ -d $physical && ( $physical == $ALLOWED || $physical == $ALLOWED/* ) ]] \
    || { refuse $id "“$root” is not a folder under /tmp."; return }
  if [[ -f $physical/.access-code ]]; then
    read -r code < "$physical/.access-code"
    [[ $secret == $code ]] || { refuse $id "The access code was refused."; return }
  fi
  ROOTS[$conn]=$physical
  KIND[$conn]=$(jx params.connection.type)
  reply $id '{}'
}

serve_list() {  # id connection remotePath — one page: `pageSize` entries from the opaque `cursor`
  local id=$1 conn=$2 remote=$3 dir name entries="" kind cursor=$(jx params.cursor) size=$(jx params.pageSize)
  resolve $conn "$remote" follow || { refuse $id "That place is outside the connection."; return }
  # The cursor is the one this script handed out (a number); anything else is refused, never evaluated.
  [[ -z $cursor || $cursor == <-> ]] || { refuse $id "That page marker is not one this drive gave."; return }
  [[ $size == <1-> ]] || size=200
  dir=$REPLY
  [[ -d $dir ]] || { refuse $id "The folder ${remote:t} does not exist."; return }
  local -a names=( $dir/*(DN:t) )
  names=( ${names:#.access-code} )        # the code file is for this plugin, not for the user's pane
  local -i start=${cursor:-0} count=$size i stop
  stop=$(( start + count ))
  (( stop > ${#names} )) && stop=${#names}
  local -A st
  for (( i = start + 1; i <= stop; i++ )); do
    name=$names[i]
    zstat -H st -- "$dir/$name" 2>/dev/null || continue
    if [[ -d $dir/$name ]]; then kind=folder; else kind=file; fi
    j "$name"
    entries+="${entries:+,}{\"name\":$J,\"kind\":\"$kind\",\"size\":${st[size]},\"modified\":${st[mtime]}}"
  done
  if (( stop < ${#names} )); then
    reply $id "{\"items\":[$entries],\"cursor\":\"$stop\"}"      # more to come: Vektor asks again with this cursor
  else
    reply $id "{\"items\":[$entries]}"
  fi
}

serve_read() {  # id connection remotePath — write the item's bytes into the file Vektor named
  local id=$1 conn=$2 remote=$3 file=$(jx params.file)
  resolve $conn "$remote" follow || { refuse $id "That place is outside the connection."; return }
  [[ -f $REPLY ]] || { refuse $id "${remote:t} does not exist."; return }
  cp -- "$REPLY" "$file" || { refuse $id "${remote:t} could not be read."; return }
  reply $id "{\"size\":$(zstat +size -- "$file")}"
}

serve_write() {  # id connection remotePath — store the bytes of the file Vektor named; the item appears whole or not at all
  local id=$1 conn=$2 remote=$3 file=$(jx params.file) size=$(jx params.size) target temporary
  writable $id $conn || return
  resolve $conn "$remote" || { refuse $id "That place is outside the connection."; return }
  target=$REPLY                            # a link here is replaced by the file, never written through
  [[ -d ${target:h} ]] || { refuse $id "The folder for ${remote:t} does not exist."; return }
  [[ -d $target ]] && { refuse $id "${remote:t} is a folder."; return }
  temporary="${target:h}/.folder-drive-$$-$RANDOM"
  if ! cp -- "$file" "$temporary" || [[ -n $size && $(zstat +size -- "$temporary") != $size ]]; then
    rm -f -- "$temporary"
    refuse $id "${remote:t} could not be written."
    return
  fi
  mv -f -- "$temporary" "$target" || { rm -f -- "$temporary"; refuse $id "${remote:t} could not be written."; return }
  reply $id '{}'
}

serve_createFolder() {  # id connection remotePath
  local id=$1 conn=$2 remote=$3
  writable $id $conn || return
  resolve $conn "$remote" || { refuse $id "That place is outside the connection."; return }
  [[ -e $REPLY || -L $REPLY ]] && { refuse $id "An item named ${remote:t} already exists."; return }
  mkdir -- "$REPLY" 2>/dev/null || { refuse $id "${remote:t} could not be created."; return }
  reply $id '{}'
}

serve_rename() {  # id connection remotePath — `newName` is one name, never a path
  local id=$1 conn=$2 remote=$3 new=$(jx params.newName) target
  writable $id $conn || return
  resolve $conn "$remote" || { refuse $id "That place is outside the connection."; return }
  [[ -z $new || $new == */* || $new == . || $new == .. || $new == .access-code ]] && { refuse $id "That name is not allowed."; return }
  isRoot $REPLY $conn && { refuse $id "The connection's folder cannot be renamed."; return }
  target="${REPLY:h}/$new"
  [[ -e $target || -L $target ]] && { refuse $id "An item named $new already exists."; return }
  mv -- "$REPLY" "$target" 2>/dev/null || { refuse $id "${remote:t} could not be renamed."; return }
  reply $id '{}'
}

serve_move() {  # id connection remotePath — to `destinationPath`, inside this connection
  local id=$1 conn=$2 remote=$3 destination=$(jx params.destinationPath) from
  writable $id $conn || return
  resolve $conn "$remote" || { refuse $id "That place is outside the connection."; return }
  from=$REPLY
  resolve $conn "$destination" || { refuse $id "That place is outside the connection."; return }
  isRoot $from $conn && { refuse $id "The connection's folder cannot be moved."; return }
  [[ -e $REPLY || -L $REPLY ]] && { refuse $id "An item named ${destination:t} already exists."; return }
  mv -- "$from" "$REPLY" 2>/dev/null || { refuse $id "${remote:t} could not be moved."; return }
  reply $id '{}'
}

serve_delete() {  # id connection remotePath — permanent, recursive; Vektor lists afterwards to see it is gone
  local id=$1 conn=$2 remote=$3
  writable $id $conn || return
  resolve $conn "$remote" || { refuse $id "That place is outside the connection."; return }
  isRoot $REPLY $conn && { refuse $id "The connection's folder cannot be deleted."; return }
  rm -rf -- "$REPLY" 2>/dev/null          # REPLY is not followed: a link is removed, never the folder it points to
  [[ -e $REPLY || -L $REPLY ]] && { refuse $id "${remote:t} could not be deleted."; return }
  reply $id '{}'
}

handle() {  # id method
  local id=$1 method=$2 conn=$(jx params.connection.id) remote=$(jx params.remotePath)
  print -r -- "$method ${remote:-$conn}" >> "$data/audit.log"
  [[ $method != location/connect && -z ${ROOTS[$conn]} ]] && { refuse $id "This connection is not open."; return }
  case $method in
    location/connect)       serve_connect $id $conn ;;
    location/disconnect)    unset "ROOTS[$conn]" "KIND[$conn]"; reply $id '{}' ;;
    location/list)          serve_list $id $conn "$remote" ;;
    location/read)          serve_read $id $conn "$remote" ;;
    location/write)         serve_write $id $conn "$remote" ;;
    location/createFolder)  serve_createFolder $id $conn "$remote" ;;
    location/rename)        serve_rename $id $conn "$remote" ;;
    location/move)          serve_move $id $conn "$remote" ;;
    location/delete)        serve_delete $id $conn "$remote" ;;
    *) reply $id '{}' ;;
  esac
}

# --- The loop: read a framed message, answer it ------------------------------------------------------------------------
while true; do
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
  # Vektor writes its keys sorted (api, id, method, params), so the first `"id":` and `"method":` are the message's own,
  # never text inside a path in `params`.
  method=""
  [[ $body =~ '"method":"([^"]*)"' ]] && method=$match[1]
  id=""
  [[ $body =~ '"id":([0-9]+)' ]] && id=$match[1]
  case $method in
    startup|ping) reply $id '{}' ;;
    shutdown) reply $id '{}'; exit 0 ;;
    '$/cancel'|location/watch) ;;      # a local folder answers at once; there is nothing to cancel or to watch
    location/*) handle $id $method ;;
    *) [[ -n $id && -n $method ]] && reply $id '{}' ;;
  esac
done
