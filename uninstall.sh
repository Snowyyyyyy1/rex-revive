#!/bin/sh
# Remove rex-revive. Your Rex sessions and the programs in them are not touched.
#
#   ./uninstall.sh          keep the saves, in case you install it again
#   ./uninstall.sh --purge  delete the saves too
#
# [INPUT]: depends on the paths install.sh writes
# [OUTPUT]: removes the login service and its log, the app, the palette actions, the pi extension,
#           the Gemini and Droid hooks (with jq), the amp plugin, and their records
# [POS]: the exact inverse of install.sh; it leaves init.lua for you to edit.
# [PROTOCOL]: Update this header on change, then check CLAUDE.md
set -eu

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || { echo "uninstall.sh: HOME is not a folder" >&2; exit 1; }
purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
if [ "$(uname -s)" = Darwin ]; then
  label=io.github.snowyyyyyy1.rex-revive
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/Library/Logs/rex-revive.log"
  app="$HOME/Library/Application Support/rex-revive/app"
  state="$HOME/Library/Application Support/rex-revive"
else
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now rex-revive.service 2>/dev/null || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/rex-revive.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  app="${XDG_DATA_HOME:-$HOME/.local/share}/rex-revive"
  state="${XDG_STATE_HOME:-$HOME/.local/state}/rex-revive"
fi

rm -rf "$app"
rm -f "$config/rex_revive.lua" "$HOME/.pi/agent/extensions/rex-revive.ts"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/amp/plugins/rex-revive.ts"
rm -rf "$HOME/.pi/agent/rex-revive" "$HOME/.gemini/rex-revive" "$HOME/.factory/rex-revive" \
  "$HOME/.local/share/amp/rex-revive"
# The SessionStart hooks install.sh --gemini and --droid added.
for file in "$HOME/.gemini/settings.json" "$HOME/.factory/settings.json"; do
  [ -f "$file" ] && grep -q 'rex-revive.*agent-hook\.sh' "$file" || continue
  if command -v jq >/dev/null 2>&1; then
    jq '.hooks.SessionStart |= map(select(any(.hooks[]?; (.command // "") | test("rex-revive.*agent-hook\\.sh")) | not))' \
      "$file" >"$file.rex-revive-new" && cat "$file.rex-revive-new" >"$file" && rm -f "$file.rex-revive-new"
    echo "Removed the rex-revive SessionStart hook from $file"
  else
    echo "Remove the SessionStart hook that runs agent-hook.sh from $file (jq isn't installed to do it)."
  fi
done
if [ "$purge" = 1 ]; then
  rm -rf "$state"
  echo "Removed rex-revive and its saves."
else
  echo "Removed rex-revive. The saves stay in $state (remove them with --purge)."
fi
if [ -f "$config/init.lua" ] && grep -q 'rex_revive' "$config/init.lua"; then
  echo "Remove the require(\"rex_revive\") line from $config/init.lua, then run: rex config reload"
fi
