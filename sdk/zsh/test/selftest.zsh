#!/bin/zsh
# The tests of vektor.zsh. Run directly (`zsh sdk/zsh/test/selftest.zsh`) or through the test plugin in this folder, which
# `vektor-plugin test` drives (`vektor-plugin test sdk/zsh/test sdk/zsh/test/checks.json`).
#
# Nothing here touches the real stdin or stdout of a plugin: messages are written to and read from files and pipes through
# VK_OUT_FD and VK_IN_FD, which exist for exactly this.
here=${0:A:h}
source $here/../vektor.zsh

typeset -gi PASSED=0 FAILED=0
typeset -g work=$(mktemp -d "${TMPDIR:-/tmp}/vektor-zsh-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

check() {  # check NAME EXPECTED ACTUAL
  if [[ $2 == $3 ]]; then PASSED+=1; else FAILED+=1; print -u2 -r -- "FAIL $1"$'\n'"  expected: $2"$'\n'"  actual:   $3"; fi
}
ok() { if (( $2 )); then FAILED+=1; print -u2 -r -- "FAIL $1"; else PASSED+=1; fi }   # ok NAME STATUS (0 = pass)

# How many times the fixed string PATTERN occurs in TEXT (messages are not newline-separated).
lines_with() { print -r -- "$1" | grep -oF -- "$2" | wc -l | tr -d ' ' }
# An independent oracle for byte counts: wc, not zsh.
bytes() { print -rn -- "$1" | wc -c | tr -d ' ' }
# Canonical form of a JSON text (keys sorted, numbers normal): a property list in XML.
norm() { print -rn -- "$1" | plutil -convert xml1 -o - - 2>&1 }
# A framed message for a test input.
frame() { printf 'Content-Length: %d\r\n\r\n%s' $(bytes "$1") "$1" }

# --- JSON escaping ----------------------------------------------------------------------------------------------------
check "escape: a quote"        '"a\"b"'  "$(vk_str 'a"b')"
check "escape: a backslash"    '"a\\b"'  "$(vk_str 'a\b')"
check "escape: newline"        '"a\nb"'  "$(vk_str $'a\nb')"
check "escape: carriage return" '"a\rb"' "$(vk_str $'a\rb')"
check "escape: tab"            '"a\tb"'  "$(vk_str $'a\tb')"
check "escape: backspace"      '"a\bb"'  "$(vk_str $'a\010b')"
check "escape: form feed"      '"a\fb"'  "$(vk_str $'a\014b')"
check "escape: slash is left alone" '"a/b"' "$(vk_str 'a/b')"
check "escape: a literal backslash-n is not a newline" '"a\\nb"' "$(vk_str 'a\nb')"
check "escape: non-ASCII passes through as UTF-8" '"žluťoučký kůň 日本 😀"' "$(vk_str 'žluťoučký kůň 日本 😀')"
check "escape: empty" '""' "$(vk_str '')"
for n in {1..31} 127; do
  c=${(#)n}
  printf -v want '"x\\u%04x"' $n
  case $n in 8) want='"x\b"' ;; 9) want='"x\t"' ;; 10) want='"x\n"' ;; 12) want='"x\f"' ;; 13) want='"x\r"' ;; esac
  check "escape: control character $n" "$want" "$(vk_str "x$c")"
done
check "escape: NUL (a zsh string can hold it)" '"a\u0000b\u0000"' "$(vk_str $'a\0b\0')"
check "escape: NUL among other control characters" '"\u0000\u0001\n"' "$(vk_str $'\0\001\n')"
# Every special character must survive a real JSON parser: plutil reads it back exactly.
all="" ; for n in {1..31} 34 92 127; do all+=${(#)n}; done; all+="é日😀"
roundtrip=$(print -rn -- "{\"v\":$(vk_str "$all"),\"k\":1}" | plutil -extract v raw -o - - 2>&1)
check "escape: all control characters, quote, backslash and UTF-8 survive plutil" "$all"$'\n' "$roundtrip"$'\n'
check "escape: vk_obj and vk_arr" '{"a":"x","n":3,"list":[1,"two"]}' "$(vk_obj a "$(vk_str x)" n 3 list "$(vk_arr 1 "$(vk_str two)")")"
check "escape: a key is escaped too" '{"a\"b":1}' "$(vk_obj 'a"b' 1)"

# --- Framing -----------------------------------------------------------------------------------------------------------
text='žluťoučký kůň — 日本語 😀'
body="{\"api\":2,\"method\":\"toast\",\"params\":{\"message\":$(vk_str "$text")}}"
exec {out}>"$work/sent"
VK_OUT_FD=$out vk_send "$body"
exec {out}>&-
want_len=$(bytes "$body")
check "framing: Content-Length is the byte count, not the character count" "Content-Length: $want_len"$'\r' "$(head -1 "$work/sent")"
(( ${#body} == want_len )) && ok "framing: LC_ALL=C makes the string length the byte count" 0 || ok "framing: string length is bytes" 1
check "framing: a blank line, then exactly the body" "$(frame "$body")" "$(<"$work/sent")"
check "framing: nothing but the message was written" $(( $(bytes "Content-Length: $want_len") + 4 + want_len )) $(wc -c < "$work/sent" | tr -d ' ')

frame "$body" > "$work/in"
exec {in}<"$work/in"
VK_IN_FD=$in vk_read; rc=$?
exec {in}<&-
check "framing: a message with multi-byte text is read back whole" "$body" "$VK_BODY"
check "framing: its method is read" toast "$VK_METHOD"
ok "framing: vk_read returned 0" $rc

# A header and a body that arrive in pieces, split inside a header name and inside a multi-byte character.
piece1=$'Content-Le'; piece2=$'ngth: '; msg='{"id":3,"method":"x","params":{"t":"ž"}}'
len=$(bytes "$msg")
exec {in}< <(printf '%s' "$piece1"; sleep 0.15; printf '%s\r\n\r\n' "$piece2$len"; sleep 0.15; printf '%s' "${msg[1,35]}"; sleep 0.15; printf '%s' "${msg[36,-1]}")
VK_IN_FD=$in vk_read; rc=$?
exec {in}<&-
check "framing: a header and a body split across reads" "$msg" "$VK_BODY"
check "framing: ... with its id" 3 "$VK_ID"
ok "framing: ... returned 0" $rc
# a header name in any case
frame '{"id":4,"method":"y"}' | sed 's/Content-Length/content-length/' > "$work/in"
exec {in}<"$work/in"; VK_IN_FD=$in vk_read; exec {in}<&-
check "framing: the header name is case-insensitive" y "$VK_METHOD"
# a body plutil cannot read is reported on stderr, in one line (it used to vanish without a word)
{ frame '{"id":5,"method":"invoke","params":{"t":"a\u0000b"}}'; frame '{"id":6,"method":"ok"}'; frame '{"id":7,"result":{}}' } > "$work/in"
exec {in}<"$work/in"
VK_IN_FD=$in vk_read 2>"$work/err"; rc=$?
check "framing: an unreadable body is still read (returns 0)" 0 $rc
check "framing: ... and said on stderr, in one line" 1 "$(grep -c 'vektor.zsh: .*could not be read' "$work/err")"
check "framing: ... nothing else" 1 "$(wc -l < "$work/err" | tr -d ' ')"
VK_IN_FD=$in vk_read 2>"$work/err"; VK_IN_FD=$in vk_read 2>>"$work/err"
exec {in}<&-
check "framing: ... a request or an answer after it is read quietly" "7 0" "$VK_ID $(wc -c < "$work/err" | tr -d ' ')"
# end of input
: > "$work/empty"; exec {in}<"$work/empty"; VK_IN_FD=$in vk_read; rc=$?; exec {in}<&-
check "framing: end of input returns 1" 1 $rc
# an overlong header ends reading
{ printf 'X-Long: %s\r\n' "${(l:1100::a:)}"; printf 'Content-Length: 2\r\n\r\n{}' } > "$work/in"
exec {in}<"$work/in"; VK_IN_FD=$in vk_read 2>/dev/null; rc=$?; exec {in}<&-
check "framing: a header over 1 KB is refused" 1 $rc
# the limit is Vektor's: the bytes before the blank line, at most 1024 (not a count per line)
{ printf 'X-Pad: %s\r\nContent-Length: 2\r\n\r\n{}' "${(l:998::a:)}" } > "$work/in"
exec {in}<"$work/in"; VK_IN_FD=$in vk_read 2>/dev/null; rc=$?; exec {in}<&-
check "framing: a header of exactly 1024 bytes is read" "0 {}" "$rc $VK_BODY"
{ printf 'X-Pad: %s\r\nContent-Length: 2\r\n\r\n{}' "${(l:999::a:)}" } > "$work/in"
exec {in}<"$work/in"; VK_IN_FD=$in vk_read 2>/dev/null; rc=$?; exec {in}<&-
check "framing: ... of 1025 bytes is refused" 1 $rc
# a header line that never ends is refused once it passes the limit, not when input ends
zmodload zsh/datetime
exec {in}< <(printf '%s' "${(l:1100::a:)}"; sleep 3)
t0=$EPOCHREALTIME; VK_IN_FD=$in vk_read 2>/dev/null; rc=$?; t1=$EPOCHREALTIME; exec {in}<&-
check "framing: a header line with no end is refused at once" "1 1" "$rc $(( t1 - t0 < 1.5 ))"
# spaces or tabs after the colon
{ printf 'Content-Length:\t 2 \t\r\n\r\n{}' } > "$work/in"
exec {in}<"$work/in"; VK_IN_FD=$in vk_read 2>/dev/null; rc=$?; exec {in}<&-
check "framing: Content-Length: followed by tabs and spaces" "0 {}" "$rc $VK_BODY"

# --- Reading fields ----------------------------------------------------------------------------------------------------
# The shapes the reference shows: startup, a view event, a dialog answer, a storage reply.
VK_BODY='{"api":2,"id":1,"method":"startup","params":{"vektorVersion":"1.0.0","pluginID":"com.example.hello","previousSessionEndedUncleanly":false,"sessionTemporaryFolder":"/tmp/s","dataFolder":"/tmp/d","settings":{"greeting":"Hello \"you\"","count":3,"ratio":0.5,"on":true,"off":false,"nothing":null,"list":["a","b","c"],"empty":""},"workspace":{"id":"w-1","name":"Žluťoučký"}}}'
check "read: a top-level string" startup "$(vk_get method)"
check "read: a top-level number" 1 "$(vk_get id)"
check "read: nested object, string" "com.example.hello" "$(vk_get params.pluginID)"
check "read: nested, quotes decoded" 'Hello "you"' "$(vk_get params.settings.greeting)"
check "read: nested, UTF-8 decoded" "Žluťoučký" "$(vk_get params.workspace.name)"
check "read: a number" 3 "$(vk_get params.settings.count)"
check "read: a fraction (plutil prints reals with six digits)" 0.500000 "$(vk_get params.settings.ratio)"
check "read: true" true "$(vk_get params.settings.on)"
check "read: false" false "$(vk_get params.settings.off)"
check "read: an array is its length" 3 "$(vk_get params.settings.list)"
check "read: an array element" b "$(vk_get params.settings.list.1)"
check "read: an empty string is present and empty" "" "$(vk_get params.settings.empty)"
vk_get params.settings.empty; check "read: ... and found" 0 $?
vk_get params.settings.nothing >/dev/null; check "read: null is absent" 1 $?
vk_get params.settings.missing >/dev/null; check "read: a missing key is absent" 1 $?
vk_get params.workspace.name.deeper >/dev/null; check "read: a path through a string is absent" 1 $?
vk_has params.settings.on; check "read: vk_has, there" 0 $?
vk_has params.settings.nothing; check "read: vk_has, null" 1 $?
check "read: vk_type string" string "$(vk_type params.pluginID)"
check "read: vk_type bool" bool "$(vk_type params.settings.on)"
check "read: vk_type array" array "$(vk_type params.settings.list)"
check "read: vk_type dictionary" dictionary "$(vk_type params.workspace)"
check "read: vk_json of an object" "$(norm '{"id":"w-1","name":"Žluťoučký"}')" "$(norm "$(vk_json params.workspace)")"
vk_get params.workspace.id wsid; check "read: into a variable, no subshell" w-1 "$wsid"
vk_get params.nope wsid; check "read: ... an absent field empties the variable" "" "$wsid"
VK_BODY='{"id":9,"method":"view/event","params":{"view":"board","action":"move","item":"c1","from":"todo","target":"done","index":2,"revision":5,"files":[{"path":"/Users/me/a b.txt","name":"a b.txt","isFolder":false},{"path":"/x/ž.md","name":"ž.md","isFolder":true}],"selected":["a","b"]}}'
check "read: a view event, block-view fields" "c1 todo done 2 5" "$(vk_get params.item) $(vk_get params.from) $(vk_get params.target) $(vk_get params.index) $(vk_get params.revision)"
check "read: array of objects, second element's field" "/x/ž.md" "$(vk_get params.files.1.path)"
check "read: ... a boolean in it" true "$(vk_get params.files.1.isFolder)"
check "read: a file name with a space" "a b.txt" "$(vk_get params.files.0.name)"
saved=$VK_BODY
check "read: vk_from reads another message and leaves the current one" "true" "$(vk_from '{"result":{"confirmed":true}}' result.confirmed)"
check "read: ... the current message is untouched" "$saved" "$VK_BODY"
VK_BODY='{"api":2,"id":1001,"result":{"result":"submit","values":{"port":"8080","extra":"a\nb"}}}'
check "read: a dialog answer" "8080" "$(vk_get result.values.port)"
check "read: ... a value with a newline" $'a\nb' "$(vk_get result.values.extra)"
VK_BODY='{"api":2,"id":1002,"result":{"content":"{\"cards\":[]}","encoding":"text","eof":true,"offset":0,"size":12,"version":"v1.m.1792575995.12"}}'
check "read: a storage reply, JSON inside a string stays text" '{"cards":[]}' "$(vk_get result.content)"
check "read: ... its version" "v1.m.1792575995.12" "$(vk_get result.version)"
VK_BODY='{"api":2,"id":1003,"error":{"code":"changed","data":{"currentVersion":"v2"},"message":"“board.json” changed since you read it."}}'
check "read: a storage refusal's code" changed "$(vk_get error.code)"
check "read: ... its words" "“board.json” changed since you read it." "$(vk_get error.message)"
check "read: ... and the data" v2 "$(vk_get error.data.currentVersion)"
# Into any variable the caller has: an array, an element of an associative array, a local, a name the helper uses itself.
VK_BODY='{"a":"x y","n":7}'
check "read: into a variable that is an array" "x y" "$( arr=(1 2); vk_get a arr 2>&1; print -rn -- "$arr" )"
check "read: into an element of an associative array" "x y|7" "$( typeset -A S; vk_get a 'S[k]'; vk_get n 'S[m]'; print -rn -- "$S[k]|$S[m]" )"
check "read: into the caller's local" "x y" "$( f() { local mine; vk_get a mine; print -rn -- "$mine" }; f )"
check "read: into variables named out, saved and rc" "x y|7|x y" "$( f() { local out saved rc; vk_get a out; vk_from '{"n":7}' n saved; vk_from '{"a":"x y"}' a rc; print -rn -- "$out|$saved|$rc" }; f )"
check "read: vk_from into saved leaves VK_BODY" '{"a":"x y","n":7}' "$( vk_from '{"n":7}' n saved; print -rn -- "$VK_BODY" )"
check "read: an absent field empties an array element" "|1" "$( typeset -A S=(k old); vk_get nope 'S[k]'; print -rn -- "$S[k]|$?" )"
check "read: a handler's variable named handler is its own" "unset|mine|" "$(
  { frame '{"api":2,"method":"view/event","params":{}}'; frame '{"api":2,"method":"view/event","params":{}}' } > "$work/h"
  exec {in}<"$work/h"; VK_IN_FD=$in VK_ENDED=0
  on_view_event() { print -rn -- "${handler-unset}|"; handler=mine }
  vk_run )"
check "read: into an element of the caller's local associative array" "x y" "$( f() { local -A L; vk_get a 'L[k]'; print -rn -- "$L[k]" }; f 2>&1 )"
unfunction on_view_event 2>/dev/null
big=$(printf 'é%.0s' {1..40000})
VK_BODY="{\"params\":{\"big\":\"$big\",\"k\":\"v\"}}"
check "read: a large message (80 KB)" v "$(vk_get params.k)"

# --- Requests: the answer is matched by id; other messages are queued --------------------------------------------------
reset_queue() { VK_QUEUE=(); VK_NEXT_ID=1000; VK_ENDED=0 }
event='{"api":2,"method":"view/event","params":{"view":"board","action":"add","block":"b1"}}'
ping='{"api":2,"id":77,"method":"ping","params":{}}'
stranger='{"api":2,"id":1999,"result":{"not":"ours"}}'
answer='{"api":2,"id":1000,"result":{"confirmed":true}}'
{ frame "$event"; frame "$ping"; frame "$stranger"; frame "$answer" } > "$work/in"
: > "$work/out"
reset_queue; VK_BODY=current; VK_METHOD=view/event; VK_ID=5
exec {in}<"$work/in" {out}>"$work/out"
VK_IN_FD=$in VK_OUT_FD=$out vk_request confirm '{"title":"t","message":"m","confirmTitle":"OK"}'; rc=$?
exec {in}<&- {out}>&-
check "request: answered although a notification and a ping came first" 0 $rc
check "request: ... the result" '{"confirmed":true}' "$VK_RESULT"
check "request: ... the notification was queued" "$event" "${VK_QUEUE[1]}"
check "request: ... only it was queued (the ping was answered, the stranger dropped)" 1 $#VK_QUEUE
check "request: ... the message being handled is put back" "current view/event 5" "$VK_BODY $VK_METHOD $VK_ID"
sent=$(<"$work/out")
check "request: ... the request went out with id 1000" 1 $(lines_with "$sent" '"id":1000,"method":"confirm"')
check "request: ... the ping was answered at once" 1 $(lines_with "$sent" '"id":77,"result":{}')
check "request: the next id follows" 1001 $VK_NEXT_ID
# vk_next hands the queued message back first
VK_METHOD=""; VK_BODY=""
vk_next; check "request: vk_next returns the queued message first" "view/event b1" "$VK_METHOD $(vk_get params.block)"
check "request: ... and empties the queue" 0 $#VK_QUEUE
# an error answer
{ frame '{"api":2,"id":1000,"error":{"code":"changed","message":"It changed."}}' } > "$work/in"
reset_queue; exec {in}<"$work/in" {out}>"$work/out"
VK_IN_FD=$in VK_OUT_FD=$out vk_request storage/write '{}'; rc=$?
exec {in}<&- {out}>&-
check "request: an error answer returns 1" 1 $rc
check "request: ... with its words" "It changed." "$VK_ERROR"
check "request: ... and its code" changed "$VK_ERROR_CODE"
# input ends before the answer
: > "$work/in"; reset_queue; exec {in}<"$work/in" {out}>"$work/out"
VK_IN_FD=$in VK_OUT_FD=$out vk_request confirm '{}'; rc=$?
exec {in}<&- {out}>&-
check "request: input ending first returns 2" 2 $rc
# vk_confirm
{ frame '{"api":2,"id":1000,"result":{"confirmed":true}}'; frame '{"api":2,"id":1001,"result":{"confirmed":false}}' } > "$work/in"
reset_queue; exec {in}<"$work/in" {out}>"$work/out"
VK_IN_FD=$in VK_OUT_FD=$out vk_confirm "T" "M" "Go"; a=$?
VK_IN_FD=$in VK_OUT_FD=$out vk_confirm "T" "M"; b=$?
exec {in}<&- {out}>&-
check "request: vk_confirm yes, then no" "0 1" "$a $b"
# shutdown while waiting
frame '{"api":2,"id":88,"method":"shutdown","params":{"reason":"quit"}}' > "$work/in"
: > "$work/out"
(
  exec {in}<"$work/in" {out}>"$work/out"
  VK_IN_FD=$in VK_OUT_FD=$out
  on_shutdown() { print done > "$work/tidied" }
  reset_queue; vk_request confirm '{}'
  print "should not get here" > "$work/after"
)
check "request: a shutdown while waiting runs on_shutdown" done "$(<"$work/tidied")"
[[ ! -e $work/after ]]; ok "request: ... and ends the plugin" $?
check "request: ... after answering it" 1 $(lines_with "$(<"$work/out")" '"id":88,"result":{}')

# --- The loop ----------------------------------------------------------------------------------------------------------
{ frame '{"api":2,"id":1,"method":"startup","params":{"settings":{"greeting":"Hola"},"workspace":null}}'
  frame '{"api":2,"id":2,"method":"ping","params":{}}'
  frame '{"api":2,"id":3,"method":"invoke","params":{"command":"hello","target":{}}}'
  frame '{"api":2,"id":4,"method":"decorations/get","params":{}}'
  frame '{"api":2,"method":"view/event","params":{"view":"v","action":"go","value":"žluť"}}'
  frame '{"api":2,"method":"$/cancel","params":{"id":3}}'
  frame '{"api":2,"id":5,"method":"shutdown","params":{"reason":"quit"}}'; } > "$work/in"
: > "$work/out"; : > "$work/trace"
(
  exec {in}<"$work/in" {out}>"$work/out"
  VK_IN_FD=$in VK_OUT_FD=$out
  on_startup() { vk_get params.settings.greeting g; print "startup $g" >> "$work/trace" }
  on_ready() { vk_toast "ready"; print ready >> "$work/trace" }
  on_invoke() { vk_reply $VK_ID "{\"message\":$(vk_str "$g!")}"; print "invoke $(vk_get params.command)" >> "$work/trace" }
  on_view_event() { print "event $(vk_get params.action) $(vk_get params.value)" >> "$work/trace" }
  on_shutdown() { print shutdown >> "$work/trace" }
  vk_run
)
trace=$(<"$work/trace"); got=$(<"$work/out")   # (`out` and `in` hold file descriptors above: integers)
check "loop: the handlers ran in order, with their data" $'startup Hola\nready\ninvoke hello\nevent go žluť\nshutdown' "$trace"
count_in_out() { lines_with "$got" "$1" }
check "loop: startup is answered" 1 $(count_in_out '"id":1,"result":{}')
check "loop: ping is answered" 1 $(count_in_out '"id":2,"result":{}')
check "loop: invoke is answered by its handler" 1 $(count_in_out '"id":3,"result":{"message":"Hola!"}')
check "loop: a request with no handler is refused" 1 $(count_in_out '"id":4,"error":{"message":"unknown method"}')
check "loop: shutdown is answered after on_shutdown" 1 $(count_in_out '"id":5,"result":{}')
check "loop: on_ready's toast went out after the answer to startup" "ready" "$(print -r -- "$got" | grep -o '"message":"ready"' | head -1 | cut -c12-16)"
# A request whose id is a string is answered with that string.
{ frame '{"api":2,"id":"r-1","method":"invoke","params":{"command":"x"}}'; frame '{"api":2,"id":"r 2","method":"nothing/here","params":{}}'; } > "$work/in"; : > "$work/out"
(
  exec {in}<"$work/in" {out}>"$work/out"; VK_IN_FD=$in VK_OUT_FD=$out
  on_invoke() { vk_reply $VK_ID '{"ok":true}' }
  vk_run
)
got=$(<"$work/out")
check "loop: a string id is answered as a string" 1 $(lines_with "$got" '"id":"r-1","result":{"ok":true}')
check "loop: ... and refused as one" 1 $(lines_with "$got" '"id":"r 2","error":{"message":"unknown method"}')
check "loop: ... and answered once" 1 $(lines_with "$got" '"id":"r-1"')
# Input ends while a handler waits for an answer: nothing more is written (the pipe is closed), on_shutdown runs once.
{ frame '{"api":2,"id":3,"method":"invoke","params":{"command":"x"}}'; } > "$work/in"; : > "$work/out"; : > "$work/trace"
(
  exec {in}<"$work/in" {out}>"$work/out"; VK_IN_FD=$in VK_OUT_FD=$out
  on_invoke() { vk_confirm T M; print "confirm $?" >> "$work/trace"; vk_toast after }
  on_shutdown() { vk_log info bye; print shutdown >> "$work/trace" }
  vk_run
  print "should not get here" >> "$work/trace"
); rc=$?
got=$(<"$work/out")
check "loop: input ending during a request: only the request went out" 1 $(lines_with "$got" 'Content-Length')
check "loop: ... it was the confirm" 1 $(lines_with "$got" '"method":"confirm"')
check "loop: ... the handler saw 1 and on_shutdown ran once, then the plugin ended" $'confirm 1\nshutdown' "$(<"$work/trace")"
check "loop: ... with status 0" 0 $rc
# A handler that forgets to answer a request does not leave Vektor waiting.
{ frame '{"api":2,"id":1,"method":"invoke","params":{"command":"x"}}'; } > "$work/in"; : > "$work/out"
(
  exec {in}<"$work/in" {out}>"$work/out"; VK_IN_FD=$in VK_OUT_FD=$out
  on_invoke() { : }
  vk_run
)
check "loop: a request the handler did not answer gets {}" 1 $(lines_with "$(<"$work/out")" '"id":1,"result":{}')

# --- Blocks, against the JSON of the reference (sdk/fixtures/blocks.json holds it for both SDKs) -------------------------------
fixture="$here/../../fixtures/blocks.json"
block() {  # block NAME ACTUAL-JSON: the fixture NAME and the function's output are the same JSON
  local want
  want=$(plutil -extract "$1" xml1 -o - "$fixture" 2>&1) || { check "block $1: fixture found" ok "$want"; return }
  check "block: $1" "$(norm "$(plutil -extract "$1" json -o - "$fixture")")" "$(norm "$2")"
}
block text "$(vk_text Hi style=mono selectable:=true link=https://example.com role=neutral lineLimit:=2)"
block symbol "$(vk_symbol star role=warning label=Starred)"
block badge "$(vk_badge docs role=label3 label='Tag docs')"
block count "$(vk_count 12 role=accent)"
block spacer "$(vk_spacer)"
block divider "$(vk_divider)"
block button "$(vk_button Sync sync id=sync symbol=arrow.triangle.2.circlepath style=icon tooltip='Sync now' busy:=true enabled:=false)"
block vstack "$(vk_vstack spacing:=4)"
block hstack "$(vk_hstack "$(vk_spacer)" spacing:=8)"
block card "$(vk_card T symbol=doc role=accent badge:='{"text":"new","role":"positive"}')"
block panel "$(vk_panel P role=label2)"
block row "$(vk_row r T subtitle=S symbol=doc badge:='{"text":"b"}' buttons:="$(vk_arr '{"title":"Go","symbol":"play","action":"go","enabled":true}')" check=chk checked:=true dimmed:=true menu:="$(vk_arr "$(vk_menu_item Del del destructive:=true)" "$(vk_menu_separator)")")"
block empty "$(vk_empty Nothing title=Empty symbol=tray role=neutral link=https://example.com)"
block banner "$(vk_banner Note role=warning)"
block status "$(vk_status Synced symbol=checkmark role=positive)"
block progress "$(vk_progress 0.5 title=Uploading)"
block spinner "$(vk_spinner Loading)"
# The reference's board example, composed from the functions: nested children and the ids.
board=$(vk_hstack \
  "$(vk_panel 'To do' id=col-todo role=label6 \
      "$(vk_list todo "$(vk_card 'Write the spec' id=c1 edit=rename delete=remove "$(vk_badge docs id=c1-tag role=label3)")" group=cards move=move)")" \
  "$(vk_panel Done id=col-done role=label4 "$(vk_list done group=cards move=move)")" id=board)
block "reference: board" "$board"
# The reference's widths example: columns that fill the pane and scroll once they no longer fit.
block "reference: widths" "$(vk_scroll "$(vk_panel 'To do' id=col-todo grow:=true minWidth:=240)" "$(vk_panel Done id=col-done grow:=true minWidth:=240)" axis=horizontal spacing:=12)"
check "block: widths at the edges, written as numbers" '{"type":"panel","title":"P","width":20,"maxWidth":4000,"grow":false,"children":[]}' "$(vk_panel P width:=20 maxWidth:=4000 grow:=false)"
check "block: a width outside 20…4000 is refused" "1|1|1" "$(vk_panel P width:=5 2>/dev/null; print -rn -- "$?|"; vk_panel P maxWidth:=9000 2>/dev/null; print -rn -- "$?|"; vk_panel P minWidth:=-30 2>/dev/null; print -rn -- "$?")"
check "block: a width written as text (width=240) or no number is refused" "1|1" "$(vk_panel P width=240 2>/dev/null; print -rn -- "$?|"; vk_panel P width:=wide 2>/dev/null; print -rn -- "$?")"
check "block: grow is true or false" "1|1" "$(vk_panel P grow:=yes 2>/dev/null; print -rn -- "$?|"; vk_panel P grow=true 2>/dev/null; print -rn -- "$?")"
# toolbar is an hstack of its children; a role is only ever a role name
check "block: vk_toolbar is a row of its buttons" "$(norm '{"type":"hstack","id":"bar","children":[{"type":"button","action":"a","title":"A"}]}')" "$(norm "$(vk_toolbar "$(vk_button A a)" id=bar)")"
check "block: vk_role" '"label3"' "$(vk_role label3)"
vk_role purple >/dev/null 2>&1; check "block: vk_role refuses a name that is no role" 1 $?
vk_text x role=purple >/dev/null 2>&1; check "block: a role field is checked" 1 $?
vk_text x background=red >/dev/null 2>&1; check "block: a colour value is refused" 1 $?
vk_text x bogus >/dev/null 2>&1; check "block: an argument that is not key=value is refused" 1 $?
check "block: text with every special character is valid JSON" 1 "$(print -rn -- "$(vk_text $'a"b\\c\nd\x01')" | plutil -extract text raw -o - - >/dev/null 2>&1 && echo 1)"
check "block: a card title starting with { is a title" "$(norm '{"type":"card","title":"{draft}","children":[{"type":"spacer"}]}')" "$(norm "$(vk_card '{draft}' "$(vk_spacer)")")"
check "block: a panel title starting with { is a title" "$(norm '{"type":"panel","title":"{ x","children":[]}')" "$(norm "$(vk_panel '{ x')")"
check "block: a list id starting with { is an id" "$(norm '{"type":"list","id":"{l}","children":[]}')" "$(norm "$(vk_list '{l}')")"
check "block: a text child of a vstack starting with { stays a child" "$(norm '{"type":"vstack","children":[{"type":"text","text":"{"}]}')" "$(norm "$(vk_vstack "$(vk_text '{')")")"
check "block: a progress of .5 is the JSON number 0.5" '{"type":"progress","progress":0.5}' "$(vk_progress .5)"
check "block: ... 1. is 1, 00.25 is 0.25" '{"type":"progress","progress":1}{"type":"progress","progress":0.25}' "$(vk_progress 1.; vk_progress 00.25)"
check "block: a progress that is no number is refused" "1|" "$(vk_progress half 2>/dev/null; print -rn -- "$?|")"
check "block: a progress with only fields is busy" '{"type":"progress","title":"T"}' "$(vk_progress title=T)"
check "block: a count whose number is left out is refused" "1|" "$(vk_count role=accent 2>/dev/null; print -rn -- "$?|")"
check "block: a count that is no number is refused" "1|" "$(vk_count many 2>/dev/null; print -rn -- "$?|")"
check "block: a count with no arguments is 0" '{"type":"count","count":0}' "$(vk_count)"
check "block: a count of 007 is 7" '{"type":"count","count":7}' "$(vk_count 007)"
check "escape: vk_obj with a key and no value is refused" "1|" "$(vk_obj a 1 b 2>/dev/null; print -rn -- "$?|")"
vk_obj a 1 b 2>&1 >/dev/null | grep -q 'vk_obj'; ok "escape: ... and says so on stderr" $?
check "block: a spinner's text with = in it is text" '{"type":"spinner","text":"Copying a=b"}{"type":"spinner","text":"1+1=2"}' "$(vk_spinner 'Copying a=b'; vk_spinner '1+1=2')"
check "block: ... text= says so when the text looks like a field" '{"type":"spinner","text":"a=b"}' "$(vk_spinner text='a=b')"
check "block: ... a field is still a field" '{"type":"spinner","id":"s"}' "$(vk_spinner id=s)"
check "block: a description" '{"revision":3,"header":{"title":"T"},"blocks":{"type":"spacer"}}' "$(vk_description 3 "$(vk_spacer)" T)"

# --- The copies a plugin carries are this file -------------------------------------------------------------------------------
for copy in "$here/../../../templates/zsh/vektor.zsh" "$here/../../../samples/todo/vektor.zsh"; do
  [[ -e $copy ]] || continue
  cmp -s "$here/../vektor.zsh" "$copy"; ok "copy: ${copy:t:h:t}/vektor.zsh is identical to sdk/zsh/vektor.zsh (run sdk/zsh/sync.sh)" $?
done

print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
