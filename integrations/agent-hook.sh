#!/bin/sh
# A SessionStart hook for Gemini CLI and Droid: records which session each
# running agent is on, as Claude Code does on its own.
#
#   agent-hook.sh gemini|droid        the hook's JSON on stdin, with "session_id"
#
# [INPUT]: depends on the hook JSON the agent writes to stdin; ps, awk, sed
# [OUTPUT]: ~/.gemini/rex-revive/<pid>.json or ~/.factory/rex-revive/<pid>.json,
#           {"pid", "sessionId", "startedAt" (ms)}; prints nothing, exits 0
# [POS]: the Gemini and Droid side of rex-revive's pid records. install.sh --gemini and
#        --droid add it to the agent's settings.json; lib/agents.lua reads the records
#        the way it reads Claude Code's. test/fake_agent.c runs it as the agents would.
# [PROTOCOL]: Update this header on change, then check CLAUDE.md
#
# Neither agent keeps a file open or a record of its own, so nothing outside it
# can tell which session a running agent is on. The agent runs this hook on
# start, /resume, and /clear. The record's pid is the agent's, the nearest
# ancestor of this hook named like it, and startedAt is when that process
# started, so rex-revive can check the record against ps (pids are reused).

name=$1
case "$name" in
  gemini) dir="$HOME/.gemini/rex-revive" ;;
  droid) dir="$HOME/.factory/rex-revive" ;;
  *) exit 0 ;;
esac

id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
# Only an ID that is safe in a typed command; rex-revive checks it again.
case "$id" in
  "" | *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# The agent: the nearest ancestor with a word on its command line named
# NAME, NAME.js, or a path ending in one of them (Gemini runs as node .../gemini.js).
named() {
  ps -o args= -p "$1" 2>/dev/null | awk -v want="$name" '{
    for (i = 1; i <= NF; i++) { w = $i; sub(/.*\//, "", w); sub(/\.[cm]?js$/, "", w); if (w == want) found = 1 }
  } END { exit !found }'
}
pid=$PPID
while [ "${pid:-0}" -gt 1 ] && ! named "$pid"; do
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done
[ "${pid:-0}" -gt 1 ] || exit 0

# ps prints elapsed time as [[dd-]hh:]mm:ss.
age=$(ps -o etime= -p "$pid" | awk '{
  n = split($1, d, "-"); days = n > 1 ? d[1] : 0; rest = n > 1 ? d[2] : d[1]
  m = split(rest, t, ":"); s = 0; for (i = 1; i <= m; i++) s = s * 60 + t[i]
  print days * 86400 + s
}')
[ -n "$age" ] || exit 0
started=$(( ($(date +%s) - age) * 1000 ))

mkdir -p "$dir" 2>/dev/null || exit 0
printf '{"pid":%s,"sessionId":"%s","startedAt":%s}\n' "$pid" "$id" "$started" >"$dir/$pid.json.tmp" &&
  mv "$dir/$pid.json.tmp" "$dir/$pid.json"

# Forget the agents that quit.
for f in "$dir"/*.json; do
  p=${f##*/}
  p=${p%.json}
  case "$p" in *[!0-9]*) continue ;; esac
  kill -0 "$p" 2>/dev/null || rm -f "$f"
done
exit 0
