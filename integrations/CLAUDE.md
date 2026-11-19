# integrations/
> L2 | Parent: ../CLAUDE.md

Code that runs inside another program, not inside `rex do`. Each file talks to the engine only through files or the `rex` command.

rex_revive.lua: Rex config actions. install.sh fills @REX@ and @SCRIPT@ and copies it to ~/.config/rex/. `revive_choose` has two callers. From the palette, it runs `mode=choices`, asks with `rex.ui.pick{multiple=true}`, then starts `mode=restore only=…`. From the watcher after a restart, `rex do revive_choose --args {chats}` asks in every connected Rex app and returns `{keys}` only when someone pressed Reopen. `rex.ui.pick` works only in an action's own body: never in pcall, rex.on, or rex.invoke. Rex requires a `title` on every action and has no hidden action, so the watcher reuses this one.
pi-rex-revive.ts: the pi extension behind pi's pid records. On session_start (UI sessions only) it writes ~/.pi/agent/rex-revive/<pid>.json with sessionId, startedAt from process.uptime, and pi's argv, which pi hides from ps; it removes the file on quit. No network, no output.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
