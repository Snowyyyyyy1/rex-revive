#!/bin/sh
# The login service's command: run the watcher, and start it again as soon as
# the Rex server is back.
#
#   service.sh REX SCRIPT [ARG...]    ARGs go to revive.lua after --all
#
# [INPUT]: depends on the rex command (REX) and revive.lua (SCRIPT); uses REX_SERVER when it is set
# [OUTPUT]: runs `rex do SCRIPT --all rex=REX ARG...` for as long as it lives, and logs why it stops
# [POS]: what install.sh's launchd agent and systemd unit run, and what test/e2e.sh runs
#        as "the watcher". revive.lua does the work; this file only keeps it running.
# [PROTOCOL]: Update this header on change, then check CLAUDE.md
#
# rex do exits when the server stops. launchd and systemd restart a service at
# most once every 10 seconds, so a restart through them leaves a restored Rex
# without its chats for up to 10 seconds. This loop waits for the server itself.

rex=$1 script=$2
shift 2

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
# sh runs a trap only after a foreground command ends; a background one plus wait lets it run at once.
pause() { sleep "$1" & wait "$!"; }

# launchd or systemd stops the service on a reinstall, a logout, or a shutdown.
# rex do then prints "Error: interrupted"; the line after it says why.
child=""
stop() {
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null
    wait "$child"
  fi
  say "rex-revive stopped: the login service was stopped (a reinstall, logout, or shutdown)"
  exit 0
}
trap stop TERM INT HUP

while :; do
  "$rex" --autostart=false do "$script" --all "rex=$rex" "$@" &
  child=$!
  wait "$child"
  child=""
  pause 1 # never spin, even when the watcher fails while the server is up
  if "$rex" --autostart=false server status >/dev/null 2>&1; then
    say "rex-revive: the watcher stopped while the Rex server runs; starting it again"
    continue
  fi
  say "rex-revive: the Rex server stopped; waiting for it to start again"
  waited=0
  until "$rex" --autostart=false server status >/dev/null 2>&1; do
    # Every second while a restart is likely, then every 10 s, as launchd would.
    if [ "$waited" -lt 120 ]; then
      pause 1
      waited=$((waited + 1))
    else
      pause 10
    fi
  done
done
