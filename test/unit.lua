--[[
Unit tests for lib/. They only read, and need no Rex sessions:

  rex do test/unit.lua root="$PWD"     (test/e2e.sh runs them too)

[INPUT]: depends on lib/proc, lib/agents, lib/snapshot, lib/restore, lib/titles, lib/closed of the repository at root=
[OUTPUT]: prints each failure and "N passed, M failed"; raises when any failed
[POS]: the fast layer of test/. It covers every pure function; e2e.sh covers Rex itself.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local root = rex.args.root or "."
package.path = root .. "/lib/?.lua;" .. package.path
local util = require("util")
local proc = require("proc")
local agents = require("agents")
local snapshot = require("snapshot")
local restore = require("restore")
local titles = require("titles")
local closed = require("closed")

local passed, failed = 0, 0
local function show(v) return type(v) == "table" and rex.json.encode(v) or tostring(v) end
local function check(name, got, want)
  if show(got) == show(want) then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want))
  end
end

local ID = "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"
local ID2 = "cccccccc-4444-4555-8666-dddddddddddd"
local NOW = 1795050000

---------------------------------------------------------------------------
-- proc

check("etime m:s", proc.parse_etime("05:07"), 307)
check("etime h:m:s", proc.parse_etime("1:02:03"), 3723)
check("etime days", proc.parse_etime("2-01:00:00"), 2 * 86400 + 3600)
local ps = proc.parse_ps("  101 01:00 /bin/claude --resume x\n  202 2-00:00:01 -zsh\n")
check("ps args", ps[101].args, "/bin/claude --resume x")
check("ps age", ps[202].age, 2 * 86400 + 1)
check("lsof files", proc.parse_lsof("p101\nfcwd\nn/tmp\np202\nn/a b/c.jsonl\n"),
  { [101] = { "/tmp" }, [202] = { "/a b/c.jsonl" } })

---------------------------------------------------------------------------
-- agents: recognizing them

check("claude binary shows a version as its name",
  agents.match({ name = "2.1.328", argv0 = "claude", path = "/x/versions/2.1.328" }), "claude")
check("claude from npm", agents.match({ name = "node", argv0 = "node",
  script = "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js" }), "claude")
check("codex binary", agents.match({ name = "codex", argv0 = "codex" }), "codex")
check("codex from npm", agents.match({ name = "node", script = "/n/@openai/codex/bin/codex.js" }), "codex")
check("pi runs as node", agents.match({ name = "node", argv0 = "pi" }), "pi")
check("a login shell is no agent", agents.match({ name = "zsh", argv0 = "-zsh" }), nil)
check("vim is no agent", agents.match({ name = "vim", argv0 = "vim" }), nil)

local function record_at(path, value) return function(p) return p == path and value or nil end end
local live = { pid = 42, sessionId = ID, startedAt = (NOW - 60) * 1000 + 400 }
local rec = "/h/.claude/sessions/42.json"
check("pid record", agents.pid_record(rec, 42, 60, NOW, record_at(rec, live)), live)
check("pid record written a few seconds late", agents.pid_record(rec, 42, 63, NOW, record_at(rec, live)), live)
check("pid reused by a later process", agents.pid_record(rec, 42, 5, NOW, record_at(rec, live)), nil)
check("pid record of another pid", agents.pid_record(rec, 42, 60, NOW,
  record_at(rec, { pid = 7, sessionId = ID, startedAt = live.startedAt })), nil)
check("pid record without a UUID", agents.pid_record(rec, 42, 60, NOW,
  record_at(rec, { pid = 42, sessionId = "latest", startedAt = live.startedAt })), nil)
check("no pid record", agents.pid_record(rec, 42, 60, NOW, record_at(rec, nil)), nil)
check("process age unknown", agents.pid_record(rec, 42, nil, NOW, record_at(rec, live)), nil)

local claude_spec = agents.REGISTRY.claude
check("claude keeps model and permissions", agents.keep(
  { "claude", "--model", "opus", "--verbose", "--dangerously-skip-permissions", "--permission-mode=plan" },
  claude_spec.options), { "--model", "opus", "--dangerously-skip-permissions", "--permission-mode=plan" })
check("codex keeps -c and --yolo", agents.keep({ "codex", "-c", "k=v", "--yolo", "resume", ID },
  agents.REGISTRY.codex.options), { "-c", "k=v", "--yolo" })

---------------------------------------------------------------------------
-- agents: which chat a process is on

local function info(pid, args, files, age)
  return { ps = { [pid] = { age = age or 60, args = args } }, files = { [pid] = files }, now = NOW }
end

check("claude by its pid record", agents.identify(
  { pid = 42, name = "2.1.328", argv0 = "claude", invoked_path = "/u/bin/claude", cwd = "/p" },
  info(42, "claude --model opus"), { home = "/h", reader = record_at(rec, live) }),
  { agent = "claude", session = ID, options = { "--model", "opus" }, exe = "/u/bin/claude" })
check("claude by its command line", agents.identify({ pid = 42, argv0 = "claude" },
  info(42, "claude --resume " .. ID2), { home = "/h", reader = record_at(rec, nil) }).session, ID2)
check("claude, session unknown", agents.identify({ pid = 42, argv0 = "claude" },
  info(42, "claude"), { home = "/h", reader = record_at(rec, nil) }).session, nil)
local rollout = "/h/.codex/sessions/2026/11/19/rollout-2026-11-19T10-00-00-" .. ID .. ".jsonl"
check("codex by the rollout file it holds", agents.identify({ pid = 9, name = "codex", argv0 = "codex" },
  info(9, "codex --yolo", { "/dev/null", rollout }), { home = "/h" }),
  { agent = "codex", session = ID, options = { "--yolo" }, exe = "codex", file = rollout })
check("codex by its command line", agents.identify({ pid = 9, argv0 = "codex" },
  info(9, "codex resume " .. ID2), { home = "/h" }).session, ID2)
local pi_rec = "/h/.pi/agent/rex-revive/77.json"
check("pi by its record, with the options it hides", agents.identify({ pid = 77, name = "node", argv0 = "pi" },
  info(77, "pi"), { home = "/h", reader = record_at(pi_rec,
    { pid = 77, sessionId = ID, startedAt = (NOW - 60) * 1000, argv = { "--thinking", "high", "--verbose" } }) }),
  { agent = "pi", session = ID, options = { "--thinking", "high" }, exe = "pi" })
check("pi without a record", agents.identify({ pid = 77, argv0 = "pi" }, info(77, "pi"),
  { home = "/h", reader = record_at(pi_rec, nil) }).session, nil)

check("claude resume command", agents.command({ agent = "claude", session = ID, options = { "--model", "opus" } }),
  { "claude", "--model", "opus", "--resume", ID })
check("codex resume command", agents.command({ agent = "codex", session = ID, exe = "/b/codex", options = { "--yolo" } }),
  { "/b/codex", "resume", "--yolo", ID })
check("pi resume command", agents.command({ agent = "pi", session = ID, options = { "--thinking", "high" } }),
  { "pi", "--thinking", "high", "--session", ID })

---------------------------------------------------------------------------
-- snapshot: what a tab runs

local zsh = { pid = 10, name = "zsh", argv0 = "-zsh", cwd = "/p" }
local login = { pid = 9, name = "login" }
check("idle shell", snapshot.describe({ foreground = zsh, ancestors = { login }, child = login },
  info(10, "-zsh")), { kind = "shell", cwd = "/p" })
check("a program", snapshot.describe({ foreground = { pid = 11, name = "vim", argv0 = "vim", cwd = "/p" },
  ancestors = { zsh, login } }, info(11, "vim notes.md  ")), { kind = "program", cwd = "/p", command = "vim notes.md" })
local chat = snapshot.describe({ foreground = { pid = 12, name = "2.1.328", argv0 = "claude", cwd = "/p" },
  ancestors = { zsh, login } }, info(12, "claude --resume " .. ID), { home = "/h", reader = record_at(rec, nil) })
check("an agent's chat", { chat.kind, chat.agent, chat.session, chat.cwd }, { "agent", "claude", ID, "/p" })
check("an agent with no certain session comes back typed", snapshot.describe(
  { foreground = { pid = 12, argv0 = "claude", cwd = "/p" }, ancestors = { zsh } },
  info(12, "claude"), { home = "/h", reader = record_at(rec, nil) }),
  { kind = "program", cwd = "/p", note = "session unknown", command = "claude" })
check("an agent found behind the tool it runs", snapshot.describe(
  { foreground = { pid = 13, name = "git", argv0 = "git" },
    ancestors = { { pid = 12, argv0 = "codex", cwd = "/p" }, zsh } },
  { ps = { [12] = { age = 9, args = "codex resume " .. ID } }, files = {}, now = NOW }, { home = "/h" }).session, ID)

---------------------------------------------------------------------------
-- restore: the plan

local function pane(t)
  t.session_id = t.session_id or "s1"
  t.session_label = t.session_label or "work"
  t.window_index = t.window_index or 1
  t.pane_index = t.pane_index or 1
  return t
end
local saved = { panes = {
  pane{ block_id = "b1", kind = "agent", agent = "claude", session = ID, cwd = "/p" },
  pane{ block_id = "b2", window_index = 2, kind = "agent", agent = "pi", session = ID2, cwd = "/q" },
  pane{ block_id = "b3", window_index = 3, kind = "program", command = "npm run dev", cwd = "/p" },
} }
local function now_panes(list) return { panes = list } end
local function texts(actions)
  local out = {}
  for _, a in ipairs(actions) do out[#out + 1] = a.block_id .. "=" .. a.text end
  return out
end
local yes = function() return true end
local idle = now_panes{
  pane{ block_id = "b1", kind = "shell", cwd = "/p" },
  pane{ block_id = "b2", window_index = 2, kind = "shell", cwd = "/p" },
  pane{ block_id = "b3", window_index = 3, kind = "shell", cwd = "/p" },
}
local actions, notes, busy = restore.plan(saved, idle, {}, { dir_exists = yes })
check("plan: chats run, programs typed, cd when the folder differs", texts(actions), {
  "b1=claude --resume " .. ID .. "\n",
  "b2=cd /q && pi --session " .. ID2 .. "\n",
  "b3=npm run dev",
})
check("plan: nothing busy", { busy, #notes }, { 0, 0 })
check("plan: programs=false", #restore.plan(saved, idle, {}, { programs = false, dir_exists = yes }), 2)
check("plan: only= the chats it names", texts(restore.plan(saved, idle, {},
  { only = { ["pi:" .. ID2] = true }, dir_exists = yes })), { "b2=cd /q && pi --session " .. ID2 .. "\n" })
actions, notes = restore.plan(saved, idle, { ["claude:" .. ID] = true }, { dir_exists = yes })
check("plan: a chat open elsewhere isn't opened again", { #actions, notes[1] },
  { 2, "work tab 1 pane 1: claude:" .. ID .. " is already open" })
local moved = now_panes{
  pane{ block_id = "new1", kind = "shell", cwd = "/p" },
  pane{ block_id = "b2", window_index = 2, kind = "program", command = "top" },
}
actions, notes, busy = restore.plan(saved, moved, {}, { dir_exists = yes, programs = false })
check("plan: a new block in the same place", texts(actions), { "new1=claude --resume " .. ID .. "\n" })
check("plan: a busy tab is left alone", { busy, notes[1] }, { 1, "work tab 2 pane 1: the tab is busy, left alone" })
local back = now_panes{
  pane{ block_id = "b1", kind = "agent", agent = "claude", session = ID },
  pane{ block_id = "b3", window_index = 3, kind = "program", command = "npm run dev" },
}
actions, notes, busy = restore.plan(saved, back, {}, { dir_exists = yes })
check("plan: what already runs in its tab is left alone quietly",
  { #actions, busy, notes[1] }, { 0, 0, "work tab 2 pane 1: its tab is gone" })
check("plan: skip= tabs typed into before", #restore.plan(saved, idle, {}, { dir_exists = yes,
  skip = { b1 = true, b2 = true, b3 = true } }), 0)
local twice = { panes = { saved.panes[1], pane{ block_id = "b2", window_index = 2, kind = "agent",
  agent = "claude", session = ID } } }
check("plan: one chat saved in two tabs opens once", #restore.plan(twice, idle, {}, { dir_exists = yes }), 1)
check("plan: leave= keeps those chats closed, programs still typed", texts(restore.plan(saved, idle, {},
  { leave = { ["claude:" .. ID] = true }, dir_exists = yes })),
  { "b2=cd /q && pi --session " .. ID2 .. "\n", "b3=npm run dev" })
check("plan: leave= a program by its id", texts(restore.plan(saved, idle, {},
  { leave = { ["program:b3"] = true }, dir_exists = yes, programs = true })),
  { "b1=claude --resume " .. ID .. "\n", "b2=cd /q && pi --session " .. ID2 .. "\n" })
check("id: a chat's key, a program's block, nothing for a shell",
  { restore.id(saved.panes[1]), restore.id(saved.panes[3]), restore.id({ kind = "shell", block_id = "b9" }) },
  { "claude:" .. ID, "program:b3" })
local none_open = { home = "/nonexistent-rex-revive-home" }
local function pending(opts)
  local out = {}
  local panes = { twice.panes[1], twice.panes[2], saved.panes[2], saved.panes[3] }
  for _, c in ipairs(restore.pending({ panes = panes }, opts)) do
    out[#out + 1] = c.key .. " " .. c.kind .. " @ " .. c.where
  end
  return out
end
check("pending: each chat once, then programs, in save order", pending(none_open), {
  "claude:" .. ID .. " agent @ work tab 1 pane 1", "pi:" .. ID2 .. " agent @ work tab 2 pane 1",
  "program:b3 program @ work tab 3 pane 1" })
check("pending: programs=false leaves programs out",
  #pending({ home = none_open.home, programs = false }), 2)

-- closed
local claude, pi = saved.panes[1], saved.panes[2]
local gone, present = closed.diff({ panes = { claude, pi, saved.panes[3] } }, { panes = { claude } })
check("closed.diff: the chats a save lost, and the chats it has",
  { #gone, gone[1].session, present }, { 1, ID2, { ["claude:" .. ID] = true } })
check("closed.diff: no earlier save, nothing lost", #closed.diff(nil, { panes = { claude } }), 0)
local list, changed = closed.merge({}, { claude, pi }, {}, "t1")
check("closed.merge: what reopening needs, newest first", { changed, list[1].key, list[2].key, list[2].cwd,
  list[2].closed_at, list[2].block_id }, { true, "claude:" .. ID, "pi:" .. ID2, "/q", "t1" })
list = closed.merge(list, { pi }, {}, "t2")
check("closed.merge: closed again moves to the front", { #list, list[1].key, list[1].closed_at }, { 2, "pi:" .. ID2, "t2" })
list, changed = closed.merge(list, {}, { ["pi:" .. ID2] = true }, "t3")
check("closed.merge: back in a tab, out of the list", { changed, #list, list[1].key }, { true, 1, "claude:" .. ID })
check("closed.merge: no change, no write", select(2, closed.merge(list, {}, { other = true }, "t4")), false)
local many = {}
for i = 1, closed.KEEP + 5 do
  many[i] = { kind = "agent", agent = "claude", session = string.format("%08d-0000-4000-8000-000000000000", i) }
end
check("closed.merge: at most KEEP", #closed.merge({}, many, {}, "t5"), closed.KEEP)
check("plan: quoting", restore.text({ kind = "agent", agent = "claude", session = ID, options = { "--add-dir", "my dir" } }),
  "claude --add-dir 'my dir' --resume " .. ID .. "\n")

-- titles: formatting
check("clip: one line, spaces collapsed", titles.clip("  Fix\n  the   bug ", 60), "Fix the bug")
check("clip: counts characters, not bytes", titles.clip("一二三四五", 3), "一二三…")
check("clip: exactly n characters stay whole", titles.clip("abc", 3), "abc")
check("clip: no text", titles.clip(" \n ", 5), nil)
check("ago", { titles.ago(30), titles.ago(300), titles.ago(7200), titles.ago(3 * 86400), titles.ago(30 * 86400) },
  { "now", "5m", "2h", "3d", "4w" })

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then error("unit tests failed", 0) end
