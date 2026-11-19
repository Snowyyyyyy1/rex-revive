#!/bin/bash
# End-to-end test of rex-revive on a throwaway Rex server.
#
#   test/e2e.sh            unit tests, then the end-to-end test (needs Rex, jq, and a C compiler)
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
D() { HOME="$H" R do "$here/revive.lua" "state_dir=$T/saves" notify=false "$@"; }

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
stop_watcher() {
  rm -f "$T/supervise"
  [ -f "$T/watch.pid" ] && kill "$(cat "$T/watch.pid")" 2>/dev/null || true
  [ -n "$watch_pid" ] && { kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; }
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

for agent in claude codex pi; do
  cc -O0 -o "$T/bin/$agent" -DAGENT="\"$agent\"" -DHOME_DIR="\"$H\"" "$here/test/fake_agent.c"
done
mkdir -p "$H/.pi/agent/extensions"
cp "$here/integrations/pi-rex-revive.ts" "$H/.pi/agent/extensions/rex-revive.ts"
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
D mode=choices | tail -1 >"$T/choices.json"
expect "choices lists the saved chats" json --arg c "codex:$CODEX" --arg p "pi:$PI" --arg n "claude:$NEW_CLAUDE" \
  '[.[].key] | (index($c) != null) and (index($p) != null) and (index($n) != null)' "$T/choices.json"
expect "choices lists chats only" json 'length == 6 and all(.[]; .agent != null and .session != null)' "$T/choices.json"
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
touch "$T/supervise"
(
  while [ -e "$T/supervise" ]; do
    HOME="$H" env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG \
      "$REX" --autostart=false -S "$SOCK" do "$here/revive.lua" --all \
      "state_dir=$T/saves" notify=false >>"$T/watch.log" 2>&1 &
    echo $! >"$T/watch.pid"
    wait $! || true
    sleep 1
  done
) &
watch_pid=$!
for _ in $(seq 1 20); do grep -q watching "$T/watch.log" 2>/dev/null && break; sleep 0.5; done
expect "the watcher started" grep -q watching "$T/watch.log"
stop_server
start_server
for _ in $(seq 1 60); do grep -q 'Reopened [1-9]' "$T/watch.log" && break; sleep 0.5; done
expect "the watcher brought the chats back" grep -q 'Reopened [1-9]' "$T/watch.log"
sleep 3
D mode=save
listing=$(show)
expect "claude is back" has "^work 1\.1 agent claude $NEW_CLAUDE\$"
expect "codex is back" has "^work 1\.2 agent codex $CODEX\$"
expect "pi is back" has "^work 2\.1 agent pi $PI\$"
expect "one copy of each claude" test "$(running "$T/bin/claude --resume $CLAUDE")" = 1
stop_watcher

echo "6. The command palette actions load"
sed -e "s|@REX@|$REX|" -e "s|@SCRIPT@|$here/revive.lua|" "$here/integrations/rex_revive.lua" >"$T/rex_revive.lua"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("rex_revive")\n' "$T" >"$T/check.lua"
expect "rex config check passes" sh -c "'$REX' config check '$T/check.lua' >'$T/check.log' 2>&1"

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
