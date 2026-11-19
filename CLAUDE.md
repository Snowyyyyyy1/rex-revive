# rex-revive - bring coding agents back into their Rex tabs after a server restart
Lua 5.1 (Rex's embedded runtime, `rex do`) + POSIX sh + TypeScript (pi extension) + C and bash (tests only). Built against Rex 0.1.0-preview.21, control API revision 18; `rex.ui` needs revision 17.

<directory>
lib/ - the engine: process facts, agent registry, snapshots, restore planning and typing (5 modules)
integrations/ - code that runs inside other programs: the Rex config palette actions, the pi extension (2 files)
test/ - unit tests in Rex Lua, end-to-end test on a throwaway Rex server, fake agents (4 files)
</directory>

<config>
revive.lua - the entry point: `rex do revive.lua [--all] mode=…`; owns arguments, state.json, and the once-per-server restore
install.sh - installs the app, the launchd/systemd watcher, the palette actions, and with --pi the pi extension
uninstall.sh - the exact inverse of install.sh; --purge also deletes the saves
README.md - the user's manual
</config>

Data flow: Rex view + `terminal.process` + ps/lsof → `snapshot.collect` → snap on disk (non-shell panes only) → after a restart `restore.chats` → the question in the Rex app (`revive_choose`; no answer means every chat) → `restore.plan` (pure) → `restore.run` types into idle shells.

Invariants:
- A chat is "agent:session". Only an idle shell is typed into. A chat open anywhere is never opened again.
- Only a Reopen press narrows a restore. A closed question, a timeout, or no Rex app reopens every chat: the app can close a question nobody saw.
- A pid record counts only when its startedAt matches the process's start (pids are reused). Claude's procStart text is never trusted: it can be off by the time zone.
- Agents are data: a new agent is one entry in `lib/agents.lua` REGISTRY.
- Nothing outside test/ starts or kills processes, except the watcher's own lifecycle.

Run the tests with `test/e2e.sh` (full) or `test/e2e.sh --unit`.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
