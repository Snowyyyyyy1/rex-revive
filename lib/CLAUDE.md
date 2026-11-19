# lib/
> L2 | Parent: ../CLAUDE.md

The engine. Dependencies point one way: util ← proc ← agents ← snapshot ← restore. revive.lua loads them through `package.path`.

util.lua: the base layer. Files with atomic writes, JSON that never raises, `rex.exec` output, POSIX quoting, UTC times, the state directory, notifications. Its only rex-revive knowledge: where state lives, and the notification title.
proc.lua: the only reader of OS process state. `names` reads Rex's process fields (argv0, script, invoked_path, name). ps gives age and command line; lsof gives open files, run only for the pids that need them; /proc on Linux. Fills what Rex's `terminal.process` omits: start times, full argv, open files.
agents.lua: the only module that knows coding agents. REGISTRY entry per agent (match, pid-record folder, held-file rule, argv rule, kept options, resume command). `identify` tries pid record → held file → argv; `running` finds chats open anywhere; `key` is the one spelling of "agent:session".
snapshot.lua: the reader side. `collect` attaches with `session.attach_all{event_scope="session"}`, walks tiled layouts, keeps this host's terminals only (block host_id equals server host_id). `describe` turns a process chain into shell, program, or agent. Saves keep non-shell panes, one file per server instance, newest 10; pruning runs only when an instance adds a file.
restore.lua: the writer side, the only module that types into terminals. `plan` is pure: match by block ID, then by session label and position; skip busy tabs, open chats, and chats in `leave` (unticked in the question). `chats` lists the saved chats not open anywhere, from the save alone, so it works while restored tabs start. `run` re-collects and re-plans up to 10 times, 3 s apart, while restored shells settle.

[PROTOCOL]: Update this header on change, then check CLAUDE.md
