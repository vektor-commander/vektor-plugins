#!/bin/zsh
# A stand-in for `cloudflared`, for the sample's scripted checks. Nothing contacts Cloudflare.
#
#   fake-cloudflared.zsh --version
#       prints a version line like the real one
#   fake-cloudflared.zsh tunnel [--no-autoupdate] --url http://localhost:PORT [more arguments]
#       after 300 ms prints, on stderr as the real one does, the log lines around a quick tunnel's public address, then
#       runs until it is terminated. A tunnel for port 65000 fails instead: one error line and exit status 1.
#
# It records its own arguments and pid in `$TMPDIR/fake-cloudflared-<pid>.args` — the plugin's session folder, since
# Vektor gives a plugin's processes a TMPDIR inside it — so a probe can see what the plugin asked for, and so that a
# file of it that outlived the session folder would show up as leftover.
export LC_ALL=C

if [[ $1 == --version ]]; then
  print -r -- "cloudflared version 2099.1.1 (built 2099-01-01-0000 UTC; fake)"
  exit 0
fi

if [[ $1 != tunnel ]]; then
  print -u2 -r -- "usage: fake-cloudflared tunnel --url http://localhost:PORT"
  exit 2
fi

url=""
for argument in "$@"; do
  [[ $argument == http://localhost:* ]] && url=$argument
done
port=${url##*:}
print -r -- "$$ $*" > "${TMPDIR:-/tmp/}fake-cloudflared-$$.args"

trap 'exit 0' TERM INT HUP

sleep 0.3
stamp() { print -rn -- "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
if [[ $port == 65000 ]]; then
  print -u2 -r -- "$(stamp) ERR Failed to create a tunnel: the origin at $url refused the connection (fake)"
  exit 1
fi
print -u2 -r -- "$(stamp) INF Thank you for trying Cloudflare Tunnel. (fake)"
print -u2 -r -- "$(stamp) INF Requesting new quick Tunnel on trycloudflare.com..."
print -u2 -r -- "$(stamp) INF +--------------------------------------------------------------------------------------------+"
print -u2 -r -- "$(stamp) INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |"
print -u2 -r -- "$(stamp) INF |  https://fake-${port}-$$.trycloudflare.com                                                 |"
print -u2 -r -- "$(stamp) INF +--------------------------------------------------------------------------------------------+"
while true; do sleep 0.2; done
