# lib/
> L2 | Parent: ../CLAUDE.md

The engine. Dependencies point one way: util ← proc ← agents ← snapshot ← restore, and agents ← titles. revive.lua loads them through `package.path`.

util.lua: the base layer. Files with atomic writes, JSON that never raises, `rex.exec` output, POSIX quoting, UTC times, the state directory, notifications. Its only rex-revive knowledge: where state lives, and the notification title.
proc.lua: the only reader of OS process state. `names` reads Rex's process fields (argv0, script, invoked_path, name). ps gives age and command line; lsof gives open files, run only for the pids that need them; /proc on Linux. Fills what Rex's `terminal.process` omits: start times, full argv, open files.
agents.lua: the only module that knows coding agents. REGISTRY entry per agent (match, pid-record folder, held-file rule, argv rule, kept options, resume command). `identify` tries pid record → held file → argv; `running` finds chats open anywhere; `key` is the one spelling of "agent:session". Rex's `string.match` returns no value on a miss, and `tonumber()` with no argument raises: wrap a match in parentheses before `tonumber`.
snapshot.lua: the reader side. `collect` attaches with `session.attach_all{event_scope="session"}`, walks tiled layouts, keeps this host's terminals only (block host_id equals server host_id). `describe` turns a process chain into shell, program, or agent. Saves keep non-shell panes, one file per server instance, newest 10; pruning runs only when an instance adds a file.
restore.lua: the writer side, the only module that types into terminals. `plan` is pure: match by block ID, then by session label and position; skip busy tabs, open chats, and chats in `leave` (unticked in the question). `chats` lists the saved chats not open anywhere, from the save alone, so it works while restored tabs start. `run` re-collects and re-plans up to 10 times, 3 s apart, while restored shells settle.
titles.lua: the only reader of the agents' conversation files, for the rows of the question. Claude: the last rename, else the last AI title, read from the last 4 MB of the file (files reach 500 MB; the last title sat within 0.6 MB of the end in 376 real chats), else the first prompt. Codex: `threads.name` in ~/.codex/state_N.sqlite through sqlite3, else the first prompt. pi: the first prompt. `ago` comes from the file's mtime or Codex's updated_at. It runs only when a person is asked, never on a save, and a failure leaves the title out.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
