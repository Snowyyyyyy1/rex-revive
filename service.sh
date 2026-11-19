#!/bin/sh
# The login service's command: run the watcher, and start it again as soon as
# the Rex server is back.
#
#   service.sh REX SCRIPT [ARG...]    ARGs go to revive.lua after --all
#
# [INPUT]: depends on the rex command (REX) and revive.lua (SCRIPT); uses REX_SERVER when it is set
# [OUTPUT]: runs `rex do SCRIPT --all rex=REX ARG...` for as long as it lives
# [POS]: what install.sh's launchd agent and systemd unit run, and what test/e2e.sh runs
#        as "the watcher". revive.lua does the work; this file only keeps it running.
# [PROTOCOL]: Update this header on change, then check CLAUDE.md
#
# rex do exits when the server stops. launchd and systemd restart a service at
# most once every 10 seconds, so a restart through them leaves a restored Rex
# without its chats for up to 10 seconds. This loop waits for the server itself.

rex=$1 script=$2
shift 2

while :; do
  "$rex" --autostart=false do "$script" --all "rex=$rex" "$@"
  sleep 1 # never spin, even when the watcher fails while the server is up
  waited=0
  until "$rex" --autostart=false server status >/dev/null 2>&1; do
    # Every second while a restart is likely, then every 10 s, as launchd would.
    if [ "$waited" -lt 120 ]; then
      sleep 1
      waited=$((waited + 1))
    else
      sleep 10
    fi
  done
done
