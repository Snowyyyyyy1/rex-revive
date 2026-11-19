# test/
> L2 | Parent: ../CLAUDE.md

Two layers. unit.lua checks every pure function in Rex's own Lua; e2e.sh checks real Rex: real restarts, real typing. Neither touches the user's Rex server or real chats.

unit.lua: run as `rex do test/unit.lua root=DIR`. Injects JSON readers and process tables, so it needs no files and no sessions. Covers titles' formatting (clip, ago); e2e covers its file readers.
e2e.sh: starts its own `rex server run` on its own socket and state folder, builds the fakes, and runs seven scenarios: save, restart, no double typing, choose with only= (with conversation files and a Codex database for the titles), the watcher as a service (the real service.sh, back within 6 s of the server), palette config check, the ask setting. The fake home holds files that look like records but aren't, such as ~/.claude/sessions/notes.json, as a real one does. Start the server with `env`, never through a shell function: `$!` must be the server, or "restart" stops nothing.
scene.lua: creates the "work" and "side" sessions the scenarios use, each tab with a known agent, program, or shell.
fake_agent.c: one source, one binary per agent (-DAGENT, -DHOME_DIR). It leaves the real agent's traces: Claude's pid record, Codex's held rollout file, pi's extension record and blanked argv.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
