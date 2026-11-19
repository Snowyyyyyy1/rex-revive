#!/bin/bash
# End-to-end test of rex-revive on a throwaway Rex server.
#
#   test/e2e.sh            unit tests, then the end-to-end test (needs Rex, jq, sqlite3, and a C compiler)
#   test/e2e.sh --unit     unit tests only
#   REX=/path/to/rex test/e2e.sh
#
# The server it runs has its own socket and state folder, and the agents are
# fakes (test/fake_agent.c) whose files live in a throwaway home folder. It
# never connects to your Rex server and never touches your real chats. It
# stops only processes it started: the server by its pid, fakes by their path.
#
# [INPUT]: depends on revive.lua, lib/, integrations/, test/unit.lua, test/scene.lua, test/fake_agent.c
# [OUTPUT]: "N passed, M failed"; exit status 0 only when all passed
# [POS]: the slow layer of test/: real Rex, real restarts, real typing into terminals.
# [PROTOCOL]: Update this header on change, then check CLAUDE.md
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${REX:-}" ]; then
  REX="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  [ -x "$REX" ] || REX=$(command -v rex)
fi
T=$(cd "$(mktemp -d /tmp/rex-revive-e2e.XXXXXX)" && pwd -P)
H=$T/home
DIR="$T/my proj"
SOCK="unix://$T/rex.sock"
mkdir -p "$H" "$T/bin" "$DIR"
: >"$T/init.lua"
passed=0 failed=0 server_pid="" watch_pid=""

clean_env() { env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG "$@"; }
R() { clean_env "$REX" --autostart=false -S "$SOCK" "$@"; }
# Run from / so revive.lua must find lib/ from its own path, as it does when installed.
D() { (cd / && HOME="$H" R do "$here/revive.lua" "state_dir=$T/saves" notify=false ask=false "$@"); }

start_server() {
  # env, not the clean_env function: $! must be the server itself, so that
  # stopping it really stops the server, as a restart does.
  env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG \
    "$REX" server run --listen "$SOCK" --state-dir "$T/state" --config "$T/init.lua" "$@" \
    >>"$T/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do R ls >/dev/null 2>&1 && return 0; sleep 0.2; done
  echo "the test server didn't start:"; cat "$T/server.log"; exit 1
}
stop_server() {
  [ -n "$server_pid" ] || return 0
  kill -TERM "$server_pid" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$server_pid" 2>/dev/null || break; sleep 0.2; done
  kill -KILL "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  sleep 1
}
# watch_pid is service.sh; stop it first so it can't start rex do again, then its rex do.
stop_watcher() {
  [ -n "$watch_pid" ] || return 0
  kids=$(pgrep -P "$watch_pid" || true)
  kill "$watch_pid" 2>/dev/null || true
  [ -n "$kids" ] && kill $kids 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  watch_pid=""
}
cleanup() {
  stop_watcher
  stop_server
  for p in $(pgrep -f "^$T/bin/" || true); do kill "$p" 2>/dev/null || true; done
  if [ "$failed" -gt 0 ] || [ "${KEEP:-0}" = 1 ]; then echo "Kept the test folder: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }
expect() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
# The newest save, one line per pane: <session> <tab>.<pane> <kind> <agent> <session id or command>
show() {
  jq -r '.panes[] | "\(.session_label) \(.window_index).\(.pane_index) \(.kind) \(.agent // "-") \(.session // .command)"' \
    "$(ls -t "$T/saves/snapshots"/*.json | head -1)"
}
has() { printf '%s\n' "$listing" | grep -E -q -- "$1"; }
field() { printf '%s\n' "$listing" | awk -v at="$1 $2" '$1 " " $2 == at { print $5 }'; }
block() { jq -r --arg s "$1" --argjson w "$2" '.panes[] | select(.session_label == $s and .window_index == $w) | .block_id' "$3"; }
running() { pgrep -f -x "$1" | wc -l | tr -d ' '; }   # processes with exactly this command line
pis() { pgrep -f "^$T/bin/pi" | wc -l | tr -d ' '; }  # pi blanks its arguments
typed() { grep -c '  type ' "$1" || true; }
json() { jq -e "$@" >/dev/null; }                     # a jq check, quietly

for agent in claude codex pi gemini droid amp cursor-agent; do
  cc -O0 -o "$T/bin/$agent" -DAGENT="\"$agent\"" -DHOME_DIR="\"$H\"" \
    -DHOOK="\"$here/integrations/agent-hook.sh\"" "$here/test/fake_agent.c"
done
mkdir -p "$H/.pi/agent/extensions" "$H/.claude/sessions" "$H/.config/amp/plugins"
cp "$here/integrations/pi-rex-revive.ts" "$H/.pi/agent/extensions/rex-revive.ts"
cp "$here/integrations/amp-rex-revive.ts" "$H/.config/amp/plugins/rex-revive.ts"
echo '{}' >"$H/.claude/sessions/notes.json"   # a record folder can hold other files
CODEX=11111111-2222-4333-8444-555555555555
CLAUDE=22222222-3333-4444-8555-666666666666
PI=33333333-4444-4555-8666-777777777777

echo "0. Unit tests"
start_server
if (cd / && R do "$here/test/unit.lua" "root=$here") >"$T/unit.log" 2>&1; then ok "$(tail -1 "$T/unit.log")"
else cat "$T/unit.log"; bad "unit tests"; fi
if [ "${1:-}" = "--unit" ]; then echo; echo "$passed passed, $failed failed"; [ "$failed" = 0 ]; exit; fi

echo "1. Save what runs in each tab"
R do "$here/test/scene.lua" "bin=$T/bin" "dir=$DIR" "codex=$CODEX" "claude=$CLAUDE" "pi=$PI" >/dev/null
sleep 3
D mode=save
listing=$(show)
cp "$(ls -t "$T/saves/snapshots"/*.json | head -1)" "$T/before.json"
NEW_CLAUDE=$(field work 1.1)
PAIR_A=$(field work 6.1)
PAIR_B=$(field work 6.2)
SIDE_PI=$(field side 1.1)
expect "a new claude chat, by its pid record" has '^work 1\.1 agent claude 00000000-0000-4000-8000-'
expect "codex, by the rollout file it holds" has "^work 1\.2 agent codex $CODEX\$"
expect "pi, by the extension's record" has "^work 2\.1 agent pi $PI\$"
expect "claude without a record, by its command line" has "^work 3\.1 agent claude $CLAUDE\$"
expect "another program, by its command line" has '^work 4\.1 program - sleep 4242$'
expect "an idle shell isn't saved" sh -c "! printf '%s\n' \"\$1\" | grep -q '^work 5\.1'" _ "$listing"
expect "two claude chats in one folder are told apart" \
  test -n "$PAIR_A" -a -n "$PAIR_B" -a "$PAIR_A" != "$PAIR_B" -a "$PAIR_A" != "$NEW_CLAUDE"
expect "a new pi in another session" has '^side 1\.1 agent pi 00000000-0000-4000-8000-'
expect "gemini, by its SessionStart hook's record" has '^more 1\.1 agent gemini 00000000-0000-4000-8000-'
expect "droid, by its SessionStart hook's record" has '^more 2\.1 agent droid 00000000-0000-4000-8000-'
expect "amp, by its plugin's record" has '^more 3\.1 agent amp T-00000000-0000-4000-8000-'
expect "cursor-agent, by the chat store it holds" has '^more 4\.1 agent cursor-agent 00000000-0000-4000-8000-'
GEMINI=$(field more 1.1)
DROID=$(field more 2.1)
AMP=$(field more 3.1)
CURSOR=$(field more 4.1)

echo "2. Restart: Rex brings back the tabs, rex-revive what ran in them"
stop_server
expect "the agents stopped with the server" test "$(pgrep -f "^$T/bin/" | wc -l | tr -d ' ')" = 0
start_server
# A chat open outside Rex meanwhile must not be opened a second time.
(cd "$DIR" && exec "$T/bin/claude" --resume "$PAIR_A" >/dev/null) &
outside=$!
# A restored tab busy for a few seconds, as when a shell's startup runs
# commands: rex-revive must wait for it, then bring its chat back.
# A shell that is still starting can drop what is typed, so type until it runs.
for _ in $(seq 1 10); do
  R do -s side -e "rex.block.call('com.superlogical.terminal', 'write', \
    { block_id = '$(block side 1 "$T/before.json")', data = 'sleep 8\\n' }) return 'ok'" >/dev/null
  for _ in $(seq 1 8); do [ "$(running "sleep 8")" = 1 ] && break 2; sleep 0.25; done
done
D mode=startup >"$T/startup.log"
sleep 3
D mode=save
listing=$(show)
expect "the new claude chat is back" has "^work 1\.1 agent claude $NEW_CLAUDE\$"
expect "codex is back in its split" has "^work 1\.2 agent codex $CODEX\$"
expect "pi is back, with its options" grep -q -- "pi --thinking high --session $PI (run)" "$T/startup.log"
expect "pi is back on its session" has "^work 2\.1 agent pi $PI\$"
expect "claude from its command line is back, once" test "$(running "$T/bin/claude --resume $CLAUDE")" = 1
expect "the program is typed, not run" test "$(running "sleep 4242")" = 0
expect "the program waits at the prompt" \
  sh -c "'$REX' --autostart=false -S '$SOCK' capture --trim -s work -b '$(block work 4 "$T/before.json")' | tail -1 | grep -q 'sleep 4242'"
expect "a chat open outside Rex is left alone" grep -q "claude:$PAIR_A is already open" "$T/startup.log"
expect "only the outside copy of it runs" test "$(running "$T/bin/claude --resume $PAIR_A")" = 1
expect "its neighbour in the same folder is back" has "^work 6\.2 agent claude $PAIR_B\$"
expect "a busy tab was waited for" grep -q 'trying again' "$T/startup.log"
expect "the busy tab's pi is back" has "^side 1\.1 agent pi $SIDE_PI\$"
expect "gemini is back on its session" has "^more 1\.1 agent gemini $GEMINI\$"
expect "droid is back on its session" has "^more 2\.1 agent droid $DROID\$"
expect "amp is back on its thread" has "^more 3\.1 agent amp $AMP\$"
expect "amp's thread through threads continue" grep -q -- "/amp threads continue $AMP (run)" "$T/startup.log"
expect "cursor-agent is back on its chat" has "^more 4\.1 agent cursor-agent $CURSOR\$"
expect "cursor-agent's chat through --resume" grep -q -- "cursor-agent --resume $CURSOR (run)" "$T/startup.log"

echo "3. Again on the same server: nothing is typed twice"
D mode=startup >"$T/startup2.log"
sleep 2
expect "nothing typed" test "$(typed "$T/startup2.log")" = 0
expect "still one claude on its chat" test "$(running "$T/bin/claude --resume $CLAUDE")" = 1
expect "still one of each pi" test "$(pis)" = 2

echo "4. Choose which chats to bring back"
kill "$outside" 2>/dev/null || true
wait "$outside" 2>/dev/null || true
stop_server
start_server
# Conversation files, for the titles in the list (lib/titles.lua).
mkdir -p "$H/.claude/projects/-fake" "$H/.pi/agent/sessions/--fake--" "$H/.codex"
: >"$H/.codex/state_x.local.sqlite"   # not a state_N database, as on a real machine
cat >"$H/.claude/projects/-fake/$NEW_CLAUDE.jsonl" <<JSON
{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}
{"type":"user","message":{"role":"user","content":"first prompt"}}
{"type":"ai-title","aiTitle":"Old title","sessionId":"$NEW_CLAUDE"}
{"type":"custom-title","customTitle":"Renamed chat","sessionId":"$NEW_CLAUDE"}
{"type":"ai-title","aiTitle":"Newer title","sessionId":"$NEW_CLAUDE"}
JSON
cat >"$H/.claude/projects/-fake/$CLAUDE.jsonl" <<JSON
{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix   the\nlogin bug"}]}}
JSON
cat >"$H/.pi/agent/sessions/--fake--/2026-01-01T00-00-00-000Z_$PI.jsonl" <<JSON
{"type":"session","id":"$PI"}
{"type":"message","message":{"role":"system","content":[{"type":"text","text":"system"}]}}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"## **pi** first [prompt](https://x.example)"}]}}
JSON
mkdir -p "$H/.local/share/amp/threads" "$H/.gemini/tmp/proj/chats"
printf '{"v":1,"id":"%s","title":"Amp thread title","messages":[]}\n' "$AMP" >"$H/.local/share/amp/threads/$AMP.json"
cat >"$H/.gemini/tmp/proj/chats/session-2026-01-01T00-00-$(printf %.8s "$GEMINI").jsonl" <<JSON
{"sessionId":"$GEMINI","projectHash":"x","startTime":"2026-01-01T00:00:00Z","kind":"main"}
{"id":"1","timestamp":"2026-01-01T00:00:01Z","type":"info","content":"Signed in"}
{"id":"2","timestamp":"2026-01-01T00:00:02Z","type":"user","content":[{"text":"gemini *first* prompt"}]}
JSON
sqlite3 "$H/.codex/state_5.sqlite" "create table threads(id text primary key, name text,
  first_user_message text, updated_at integer);
  insert into threads values('$CODEX', 'Codex named thread', 'first', strftime('%s', 'now') - 20 * 86400);"
D mode=choices | tail -1 >"$T/choices.json"
title_of() { jq -r --arg k "$1" '.[] | select(.key == $k) | "\(.title // "-") | \(.ago // "-")"' "$T/choices.json"; }
expect "claude: a rename wins over its own titles" test "$(title_of "claude:$NEW_CLAUDE")" = "Renamed chat | now"
expect "claude: else the first prompt a person typed" test "$(title_of "claude:$CLAUDE")" = "Fix the login bug | now"
expect "codex: the thread's name and last activity" test "$(title_of "codex:$CODEX")" = "Codex named thread | 2w"
expect "pi: its first prompt" test "$(title_of "pi:$PI")" = "pi first prompt | now"
expect "gemini: its first prompt" test "$(title_of "gemini:$GEMINI")" = "gemini first prompt | now"
expect "amp: the thread's title" test "$(title_of "amp:$AMP")" = "Amp thread title | now"
expect "choices lists the saved chats" json --arg c "codex:$CODEX" --arg p "pi:$PI" --arg n "claude:$NEW_CLAUDE" \
  '[.[].key] | (index($c) != null) and (index($p) != null) and (index($n) != null)' "$T/choices.json"
expect "choices lists chats only" json 'length == 10 and all(.[]; .agent != null and .session != null)' "$T/choices.json"
# Five chats active now, codex 20 days ago, then four with no conversation file.
expect "recently active chats come first" json --arg c "codex:$CODEX" '[.[].key] | index($c) == 5' "$T/choices.json"
expect "a chat idle over two weeks starts unticked" \
  json --arg c "codex:$CODEX" 'all(.[]; .ticked == (.key != $c))' "$T/choices.json"
# The chat that ran outside Rex left its tab an idle shell, and the saves since
# say so: it isn't brought into Rex, where it would run twice.
expect "a chat that moved out of Rex isn't offered" \
  json --arg a "claude:$PAIR_A" '[.[].key] | index($a) == null' "$T/choices.json"
D mode=restore "only=codex:$CODEX" >"$T/only.log"
expect "only= brings back the chosen chat" grep -q "resume $CODEX (run)" "$T/only.log"
expect "only= types nothing else" test "$(typed "$T/only.log")" = 1
D mode=startup >"$T/startup3.log"
expect "startup brings back the rest" grep -q -- "--session $PI (run)" "$T/startup3.log"
expect "startup doesn't bring the chosen chat back again" sh -c "! grep -q 'resume $CODEX (run)' '$T/startup3.log'"
sleep 3
D mode=save
listing=$(show)
expect "one codex on its chat" test "$(running "$T/bin/codex resume $CODEX")" = 1

echo "5. The watcher, run like a login service, brings everything back by itself"
(
  cd /
  HOME="$H" REX_SERVER="$SOCK" exec env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT -u REX_CONFIG \
    sh "$here/service.sh" "$REX" "$here/revive.lua" "state_dir=$T/saves" notify=false ask=false \
    >>"$T/watch.log" 2>&1
) &
watch_pid=$!
for _ in $(seq 1 20); do grep -q watching "$T/watch.log" 2>/dev/null && break; sleep 0.5; done
expect "the watcher started" grep -q watching "$T/watch.log"
stop_server
start_server
up=$(date +%s)
for _ in $(seq 1 60); do grep -q 'Reopened [1-9]' "$T/watch.log" && break; sleep 0.5; done
took=$(($(date +%s) - up))
expect "the watcher brought the chats back" grep -q 'Reopened [1-9]' "$T/watch.log"
# launchd and systemd alone would restart the watcher only after 10 s.
expect "within 6 s of the server (took ${took}s)" test "$took" -le 6
expect "the log says the server stopped" grep -q "the Rex server stopped; waiting for it to start again" "$T/watch.log"
sleep 3
D mode=save
listing=$(show)
expect "claude is back" has "^work 1\.1 agent claude $NEW_CLAUDE\$"
expect "codex is back" has "^work 1\.2 agent codex $CODEX\$"
expect "pi is back" has "^work 2\.1 agent pi $PI\$"
expect "one copy of each claude" test "$(running "$T/bin/claude --resume $CLAUDE")" = 1
stop_watcher
expect "the log says why the watcher stopped" grep -q "rex-revive stopped: the login service was stopped" "$T/watch.log"

echo "6. The command palette actions load"
sed -e "s|@REX@|$REX|" -e "s|@SCRIPT@|$here/revive.lua|" -e "s|@LOG@|$T/palette.log|" \
  "$here/integrations/rex_revive.lua" >"$T/rex_revive.lua"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("rex_revive")\n' "$T" >"$T/check.lua"
expect "rex config check passes" sh -c "'$REX' config check '$T/check.lua' >'$T/check.log' 2>&1"
expect "it defines six actions" grep -q '^actions: 6$' "$T/check.log"
expect "it binds shift+cmd+t" grep -q '^bindings: 1$' "$T/check.log"
printf 'rex.bind("shift+cmd+t", "pane.zoom")\n' | cat - "$T/check.lua" >"$T/check2.lua"
"$REX" config check "$T/check2.lua" >"$T/check2.log" 2>&1 || true
expect "but not over a binding of the person's" grep -q '^bindings: 1$' "$T/check2.log"

echo "7. The setting to reopen every chat without asking"
# Not D: D passes ask=false, which is the setting under test.
settings() { (cd / && HOME="$H" R do "$here/revive.lua" "state_dir=$T/saves" mode=settings "$@") | tail -1; }
expect "asking is the default" test "$(settings)" = '{"ask":true}'
settings ask=false >/dev/null
expect "ask=false is kept" test "$(settings)" = '{"ask":false}'
expect "status shows it" sh -c "(cd / && HOME='$H' '$REX' --autostart=false -S '$SOCK' do '$here/revive.lua' 'state_dir=$T/saves' mode=status) | grep -q 'After a restart: reopen every chat'"
settings ask=true >/dev/null
expect "ask=true turns it back on" test "$(settings)" = '{"ask":true}'

echo "8. Closed chats come back in a new tab"
newest() { ls -t "$T/saves/snapshots"/*.json | head -1; }
window_of() {   # the window of the tab that held a block in before.json
  R api call -s "$1" session.view '{}' | jq -r --arg b "$(block "$1" "$2" "$T/before.json" | head -1)" \
    '.windows[] | select([.layers[].blocks[]?.block_id] | index($b)) | .window_id'
}
close_tab() { R api call -s "$1" session.close_window "{\"window_id\": \"$(window_of "$1" "$2")\"}" >/dev/null; }
closed_keys() { jq -r '[.[].key] | join(" ")' "$T/saves/closed.json"; }
D mode=save
SIDE=$(jq -r '[.panes[] | select(.session_label == "side")][0].session_id' "$(newest)")
close_tab work 3
sleep 1
D mode=save >"$T/close.log"
close_tab work 2
sleep 1
D mode=save >>"$T/close.log"
expect "a save remembers the chats it lost, newest first" test "$(closed_keys)" = "pi:$PI claude:$CLAUDE"
expect "and logs each" sh -c "grep -q 'closed claude:$CLAUDE (work' '$T/close.log' && grep -q 'closed pi:$PI (work' '$T/close.log'"
D mode=closed | tail -1 >"$T/closed.json"
expect "the closed chats have their titles" \
  json '[.[].title] == ["pi first prompt", "Fix the login bug"]' "$T/closed.json"
D mode=reopen "log=$T/palette.log" >"$T/reopen.log"
sleep 3
D mode=save
listing=$(show)
expect "the newest closed chat is back, in a new tab of its session" has "^work [0-9]+\.1 agent pi $PI\$"
expect "and out of the list" test "$(closed_keys)" = "claude:$CLAUDE"
expect "log= appends to the log, as from the palette" grep -q "reopened pi:$PI in a new tab" "$T/palette.log"
D mode=reopen "key=claude:$CLAUDE" "session=$SIDE" >>"$T/reopen.log"
sleep 3
D mode=save
listing=$(show)
expect "key= and session= pick the chat and the session" has "^side [0-9]+\.1 agent claude $CLAUDE\$"
expect "one claude on that chat" test "$(running "$T/bin/claude --resume $CLAUDE")" = 1
# An agent that quits leaves its tab an idle shell: the chat comes back there.
pkill -f -x "$T/bin/codex resume $CODEX" || true
sleep 1
D mode=save >/dev/null
D mode=reopen >>"$T/reopen.log"
sleep 3
D mode=save >/dev/null
listing=$(show)
expect "a chat whose agent quit comes back in its own tab" has "^work 1\.2 agent codex $CODEX\$"
expect "and the log says so" grep -q "reopened codex:$CODEX in its tab" "$T/reopen.log"
# A closed pane of a split comes back beside the pane it shared the tab with.
R api call -s work block.close "{\"block_id\": \"$(block work 1 "$T/before.json" | sed -n 2p)\"}" >/dev/null
sleep 1
D mode=save >/dev/null
D mode=reopen >>"$T/reopen.log"
sleep 3
D mode=save >/dev/null
listing=$(show)
expect "a closed pane comes back in its old place" grep -q "reopened codex:$CODEX in its old place" "$T/reopen.log"
expect "on its side of the split" has "^work 1\.2 agent codex $CODEX\$"
expect "with nothing closed, nothing opens" test "$(D mode=reopen | tail -1)" = "No closed chats to reopen."
# A restart that can't bring a chat back leaves it closed: here its tab is gone.
expect "before the restart, the chat in tab 6 is saved" has " agent claude $PAIR_B\$"
stop_server
start_server
close_tab work 6
D mode=startup >"$T/startup4.log"
expect "a chat whose tab is gone after a restart is closed" grep -q "claude:$PAIR_B" "$T/saves/closed.json"

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
