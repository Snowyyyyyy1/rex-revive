# integrations/
> L2 | Parent: ../CLAUDE.md

Code that runs inside another program, not inside `rex do`. Each file talks to the engine only through files or the `rex` command.

rex_revive.lua: Rex config actions. install.sh fills @REX@ and @SCRIPT@ and copies it to ~/.config/rex/. `revive_choose` runs `mode=choices`, asks with `rex.ui.pick{multiple=true}`, then starts `mode=restore only=…`. `rex.ui` only works inside an action's run, so the choice is never part of the automatic restore.
pi-rex-revive.ts: the pi extension behind pi's pid records. On session_start (UI sessions only) it writes ~/.pi/agent/rex-revive/<pid>.json with sessionId, startedAt from process.uptime, and pi's argv, which pi hides from ps; it removes the file on quit. No network, no output.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
