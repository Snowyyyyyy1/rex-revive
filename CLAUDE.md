# rex-revive - bring coding agents back into their Rex tabs after a server restart
Lua 5.1 (Rex's embedded runtime, `rex do`) + POSIX sh + TypeScript (pi extension) + C and bash (tests only). Built against Rex 0.1.0-preview.21, control API revision 18; `rex.ui` needs revision 17.

<directory>
lib/ - the engine: process facts, agent registry, snapshots, restore planning and typing, chat titles, closed chats (7 modules)
integrations/ - code that runs inside other programs: the Rex config palette actions, the pi extension, the Gemini CLI and Droid hook, the amp and opencode plugins (5 files)
test/ - unit tests in Rex Lua, end-to-end test on a throwaway Rex server, fake agents (4 files)
</directory>

<config>
revive.lua - the entry point: `rex do revive.lua [--all] mode=…`; owns arguments, settings.json (the person's choices), state.json, closed.json's path, the once-per-server restore, the order and ticks of a question's rows (every question lists from a save, never from the tabs, which may still be starting), and the history and preview modes
service.sh - the login service's command: runs the watcher, restarts it within 1 s of the server's return (launchd/systemd alone wait 10 s), and logs why the watcher stopped
install.sh - installs the app, the launchd/systemd watcher, the palette actions, and with --pi, --gemini, --droid, --amp, --opencode what records each agent's session
uninstall.sh - the exact inverse of install.sh; --purge also deletes the saves
README.md - the user's manual
</config>

Data flow: Rex view + `terminal.process` + ps/lsof → `snapshot.collect` → snap on disk (non-shell panes only; the chats the last save had and this one lacks go to `closed.json`) → after a restart `restore.pending` (chats, then programs) → `titles.label` and revive.lua's ranking → the question in the Rex app (`revive_choose`; skipped when settings.json says ask=false or there is no chat; no answer means everything) → `restore.plan` (pure) → `restore.run` types into idle shells → the chats it didn't bring back go to `closed.json`. A closed chat comes back through `mode=reopen`: `restore.into_tab` types it into its own tab when one process call shows an idle shell there (its agent quit), else `restore.open` → a new pane in its old place (`place`, the split it sat in, recorded by `snapshot.collect`) or a new tab, whose `initial_input` is the resume command. Every save also goes to `snapshots/history/` (every 30 min at most, when changed); `mode=reopen from=<id>` brings back the chats of such an earlier save that aren't open. `mode=preview` lists what a restart would bring back now, from a fresh collect. Palette runs append to the watcher's log through `log=`.

Invariants:
- A chat is "agent:session". Only an idle shell is typed into. A chat open anywhere is never opened again.
- Only a Reopen press narrows a restore. A closed question, a timeout, or no Rex app reopens everything, unticked rows too: the app can close a question nobody saw.
- A chat is closed when a save no longer has it, or a restart didn't bring it back. Its entry keeps what reopening needs; a chat open anywhere is never listed.
- A pid record counts only when its startedAt matches the process's start (pids are reused). Claude's procStart text is never trusted: it can be off by the time zone.
- Agents are data: a new agent is one entry in `lib/agents.lua` REGISTRY, plus, when the agent can't say which session it is on, a record writer in integrations/ (extension, plugin, or hook) that writes `{pid, sessionId, startedAt}`.
- install.sh edits another program's settings only behind a flag (`--gemini`, `--droid`), with jq, after a backup, written through (never moved over a link); rex.json is unfit for it: it turns `[]` into `{}` and drops nulls.
- Nothing outside test/ starts or kills processes, except the watcher's own lifecycle.

Run the tests with `test/e2e.sh` (full) or `test/e2e.sh --unit`.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
