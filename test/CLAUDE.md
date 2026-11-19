# test/
> L2 | Parent: ../CLAUDE.md

Two layers. unit.lua checks every pure function in Rex's own Lua; e2e.sh checks real Rex: real restarts, real typing. Neither touches the user's Rex server or real chats.

unit.lua: run as `rex do test/unit.lua root=DIR`. Injects JSON readers and process tables, so it needs no files and no sessions. Covers each agent's argv rule, ID check, and resume command, titles' formatting (clip, ago), and closed.lua's diff and merge; e2e covers the file readers and closed.json.
e2e.sh: starts its own `rex server run` on its own socket and state folder, builds the fakes, and runs eight scenarios: save (all seven agents: Gemini's and Droid's records written by the real hook, Cursor Agent by its held store), restart, no double typing, choose with only= (with conversation files and a Codex database for the titles, the order, and the ticks), the watcher as a service (the real service.sh, back within 6 s of the server, and its log lines), palette config check (six actions, ⇧⌘T only when free), the ask setting, closed chats (a closed tab, reopened in a new tab; an agent that quit, reopened in its own tab; a closed pane of a split, reopened in its old place; a tab gone after a restart; the log lines). Closing tabs renumbers the later ones: find a tab by its block ID in before.json, never by its number. The fake home holds files that look like records but aren't, such as ~/.claude/sessions/notes.json, as a real one does. Start the server with `env`, never through a shell function: `$!` must be the server, or "restart" stops nothing.
scene.lua: creates the "work", "side", and "more" sessions the scenarios use, each tab with a known agent, program, or shell; "more" holds gemini, droid, amp, and cursor-agent.
fake_agent.c: one source, one binary per agent (-DAGENT, -DHOME_DIR, -DHOOK). It leaves the real agent's traces: Claude's pid record, Codex's held rollout file, pi's extension record and blanked argv, amp's plugin record, Cursor Agent's held store.db; gemini and droid run the real integrations/agent-hook.sh as their SessionStart hook would, with HOME set to the test home.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
