#!/bin/sh
# Install rex-revive, or update an installed copy.
#
#   ./install.sh                  copy the files and start the watcher as a login service
#   ./install.sh --add-to-config  also load the command palette actions from Rex's init.lua
#   ./install.sh --pi             also install the pi extension that records pi's session
#   ./install.sh --no-service     copy the files only
#   REX=/path/to/rex ./install.sh use this rex command
#
# Remove it with ./uninstall.sh.
#
# [INPUT]: depends on revive.lua, lib/, integrations/ of this repository; launchd or systemd
# [OUTPUT]: the installed app, a login service, ~/.config/rex/rex_revive.lua, and with --pi the pi extension
# [POS]: the only installer; uninstall.sh undoes each step it takes.
# [PROTOCOL]: Update this header on change, then check CLAUDE.md
set -eu

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || { echo "install.sh: HOME is not a folder" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
add_to_config=0 service=1 pi=0
for arg in "$@"; do
  case "$arg" in
    --add-to-config) add_to_config=1 ;;
    --no-service) service=0 ;;
    --pi) pi=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done
say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

os=$(uname -s)
case "$os" in
  Darwin) app="$HOME/Library/Application Support/rex-revive/app"; log="$HOME/Library/Logs/rex-revive.log" ;;
  Linux) app="${XDG_DATA_HOME:-$HOME/.local/share}/rex-revive" ; log="" ;;
  *) fail "rex-revive runs on macOS and Linux, not $os" ;;
esac
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
script="$app/revive.lua"

# On macOS, Rex keeps its current rex command at a path that survives updates.
find_rex() {
  if [ -n "${REX:-}" ]; then printf '%s\n' "$REX"; return; fi
  current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if [ "$os" = Darwin ] && [ -x "$current" ]; then printf '%s\n' "$current"; return; fi
  command -v rex
}
rex=$(find_rex) || fail "can't find the rex command; open Rex once, or run REX=/path/to/rex ./install.sh"
say "Using rex: $rex"

# The files: revive.lua and lib/, replaced as a whole so no old module stays behind.
mkdir -p "$app"
rm -rf "$app/lib.new" && mkdir "$app/lib.new"
cp "$here"/lib/*.lua "$app/lib.new/"
rm -rf "$app/lib" && mv "$app/lib.new" "$app/lib"
cp "$here/revive.lua" "$script.new" && mv "$script.new" "$script"
say "Installed $script"

# The service's PATH: where the agents and lsof live.
path="/usr/bin:/bin:/usr/sbin:/sbin"
for tool in claude codex pi lsof; do
  where=$(command -v "$tool" 2>/dev/null || true)
  case "$where" in /*) dir=$(dirname "$where"); case ":$path:" in *":$dir:"*) ;; *) path="$dir:$path" ;; esac ;; esac
done

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
if [ "$service" = 1 ] && [ "$os" = Darwin ]; then
  label=io.github.snowyyyyyy1.rex-revive
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$rex")</string>
    <string>--autostart=false</string>
    <string>do</string>
    <string>$(xml "$script")</string>
    <string>--all</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$path")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$log")</string>
  <key>StandardErrorPath</key><string>$(xml "$log")</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  say "Started the login service $label (log: $log)"
elif [ "$service" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$units"
  cat >"$units/rex-revive.service" <<EOF
[Unit]
Description=rex-revive: bring back the agents in your Rex tabs after a restart

[Service]
ExecStart="$rex" --autostart=false do "$script" --all
Restart=always
RestartSec=10
Environment="PATH=$path"

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now rex-revive.service
  systemctl --user restart rex-revive.service
  say "Started the systemd user service rex-revive"
elif [ "$service" = 1 ]; then
  say "No launchd or systemd here; keep this running yourself:"
  say "  \"$rex\" --autostart=false do \"$script\" --all"
fi

# pi hides which session it is on; this extension records it.
pi_extension="$HOME/.pi/agent/extensions/rex-revive.ts"
if [ "$pi" = 1 ] || [ -f "$pi_extension" ]; then
  mkdir -p "$(dirname "$pi_extension")"
  cp "$here/integrations/pi-rex-revive.ts" "$pi_extension"
  say "Installed the pi extension $pi_extension (pi chats started from now on use it)"
fi

# Command palette actions, with this install's paths filled in.
lua_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
sed_text() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
mkdir -p "$config"
sed -e "s|@REX@|$(sed_text "$(lua_string "$rex")")|" -e "s|@SCRIPT@|$(sed_text "$(lua_string "$script")")|" \
  "$here/integrations/rex_revive.lua" >"$config/rex_revive.lua"
say "Installed the command palette actions in $config/rex_revive.lua"
init="$config/init.lua"
if [ -f "$init" ] && grep -q 'rex_revive' "$init"; then
  :
elif [ "$add_to_config" = 1 ]; then
  printf '\n-- rex-revive: command palette actions\nrequire("rex_revive")\n' >>"$init"
  say "Added require(\"rex_revive\") to $init"
else
  say "To get the actions in the command palette, add this line to $init, or run ./install.sh --add-to-config:"
  say "  require(\"rex_revive\")"
fi
"$rex" --autostart=false config reload >/dev/null 2>&1 || true

say ""
say "Done. Check on it with:  \"$rex\" do \"$script\" mode=status"
