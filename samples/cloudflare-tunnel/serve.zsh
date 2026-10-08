#!/bin/zsh
# A tiny read-only web server for Cloudflare Tunnel's published files and folders.
#
#   serve.zsh <port> <file-or-folder>
#
# Started by the plugin through Vektor's Processes service, so Vektor tracks it per plugin and ends it with the plugin
# (quit, disable, removal, update). It writes no file of its own.
#
# * `zsh/net/tcp` listens on all interfaces (it has no bind address), so every accepted connection is checked against
#   its peer and anything that is not loopback is dropped without reading a byte or answering. cloudflared connects
#   from this Mac. The peer is read **numerically**, from `lsof -nP` on the accepted descriptor — never from
#   `ztcp -L`, which prints the peer's *reverse-DNS name* (127.0.0.1 shows as `localhost`): on a network whose DNS
#   server is hostile, a LAN peer whose address has a PTR record of `localhost` passed the old name check and was
#   served, and every LAN connection cost a reverse lookup the server waited on.
# * The accept loop *polls* with `zselect`: a blocking `ztcp -a` never runs a TERM trap, and a server that
#   cannot answer TERM would make every disable wait out the grace period.
# * A file is served for any path; a folder serves the files below it and an index at `/`. `..` is refused.
export LC_ALL=C
zmodload zsh/net/tcp zsh/zselect zsh/system || exit 3
zmodload -F zsh/stat b:zstat

port=$1
root=$2
[[ $port == <1024-65535> && -e $root ]] || exit 2
ztcp -l $port || exit 4
listener=$REPLY
trap 'exit 0' TERM INT HUP

content_type() {
  case ${1:l} in
    *.html|*.htm) print -rn -- "text/html; charset=utf-8" ;;
    *.txt|*.md|*.log|*.csv) print -rn -- "text/plain; charset=utf-8" ;;
    *.json) print -rn -- "application/json" ;;
    *.png) print -rn -- "image/png" ;;
    *.jpg|*.jpeg) print -rn -- "image/jpeg" ;;
    *.gif) print -rn -- "image/gif" ;;
    *.svg) print -rn -- "image/svg+xml" ;;
    *.pdf) print -rn -- "application/pdf" ;;
    *) print -rn -- "application/octet-stream" ;;
  esac
}

respond() {  # fd code text body-file-or-empty content-type length head-only
  local fd=$1 code=$2 text=$3 file=$4 type=$5 length=$6 head=$7
  print -rn -u $fd -- "HTTP/1.0 $code $text"$'\r\n'"Content-Type: $type"$'\r\n'"Content-Length: $length"$'\r\n'"Connection: close"$'\r\n\r\n'
  [[ -n $file && -z $head ]] && cat -- "$file" >&$fd
}

index_page() {  # folder prefix → html on stdout
  local folder=$1 entry name
  print -r -- "<!doctype html><meta charset=utf-8><title>Index</title><ul>"
  for entry in $folder/*(N); do
    name=${entry:t}
    [[ -d $entry ]] && name+=/
    name=${name//&/&amp;}; name=${name//</&lt;}
    print -r -- "<li><a href=\"./${name}\">${name}</a></li>"
  done
  print -r -- "</ul>"
}

while true; do
  zselect -t 50 $listener || continue
  [[ $reply[1] == -r ]] || continue
  ztcp -a $listener || continue
  fd=$REPLY

  # Only this Mac may ask. `lsof -Fn` names the connection `n<local>-><remote>`, numerically (`-nP`); the listener is
  # IPv4 only (`ztcp -l`), so loopback is 127.0.0.0/8. Anything else — or no answer from lsof — is closed unread.
  peer=""
  for line in ${(f)"$(/usr/sbin/lsof -nP -a -p $$ -d $fd -Fn 2>/dev/null)"}; do
    [[ $line == n*'->'* ]] && peer=${line#*->}
  done
  if [[ $peer != 127.<0-255>.<0-255>.<0-255>:<1-65535> ]]; then ztcp -c $fd; continue; fi

  request=""
  read -r -t 5 -u $fd request || { ztcp -c $fd; continue }
  while read -r -t 5 -u $fd header; do
    header=${header%$'\r'}
    [[ -z $header ]] && break
  done
  verb=${request%% *}
  rpath=${${request#* }%% *}
  rpath=${rpath%%\?*}
  rpath=$(printf '%b' "${rpath//\%/\\x}")
  head=""
  [[ $verb == HEAD ]] && head=1

  if [[ $verb != (GET|HEAD) ]]; then
    respond $fd 405 "Method Not Allowed" "" "text/plain" 0 $head
  elif [[ $rpath == *..* ]]; then
    respond $fd 403 "Forbidden" "" "text/plain" 0 $head
  elif [[ -f $root ]]; then
    zstat -A size +size -- $root
    respond $fd 200 OK $root "$(content_type $root)" $size[1] $head
  else
    target=$root/${rpath#/}
    if [[ $rpath == "" || $rpath == "/" ]]; then
      body=$(index_page $root)
      respond $fd 200 OK "" "text/html; charset=utf-8" ${#body} $head
      [[ -z $head ]] && print -rn -u $fd -- "$body"
    elif [[ -d $target ]]; then
      body=$(index_page $target)
      respond $fd 200 OK "" "text/html; charset=utf-8" ${#body} $head
      [[ -z $head ]] && print -rn -u $fd -- "$body"
    elif [[ -f $target ]]; then
      zstat -A size +size -- $target
      respond $fd 200 OK $target "$(content_type $target)" $size[1] $head
    else
      respond $fd 404 "Not Found" "" "text/plain" 0 $head
    fi
  fi
  ztcp -c $fd
done
