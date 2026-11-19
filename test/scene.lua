--[[
Sets up the sessions test/e2e.sh works with, on its throwaway Rex server only:

  rex do test/scene.lua bin=DIR dir=DIR codex=ID claude=ID pi=ID

  work  tab 1  claude (new, with a pid record) | codex resume <codex>
        tab 2  pi --thinking high --session <pi>
        tab 3  claude --no-record --resume <claude>  (found by its command line)
        tab 4  sleep 4242                            (another program)
        tab 5  an idle shell
        tab 6  claude | claude                       (two new chats in one folder)
  side  tab 1  pi (new)

[INPUT]: depends on session.create from the Rex server API
[OUTPUT]: the two sessions above; returns "ok"
[POS]: the scene of test/e2e.sh, which checks what rex-revive saves and brings back.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local a = rex.args
local function q(word) return "'" .. word:gsub("'", "'\\''") .. "'" end
local function tab(command)
  local options = { cwd = a.dir }
  if command then options.initial_input = command .. "\n" end
  return { block = { flavor = "com.superlogical.terminal.shell", options = options } }
end
local function split(before, after)
  return { split = { direction = "horizontal", ratio = 0.5, before = before, after = after } }
end
local claude, codex, pi = q(a.bin .. "/claude"), q(a.bin .. "/codex"), q(a.bin .. "/pi")

assert(rex.call("session.create", { label = "work", initial_windows = {
  { layout = split(tab(claude), tab(codex .. " resume " .. a.codex)) },
  { layout = tab(pi .. " --thinking high --session " .. a.pi) },
  { layout = tab(claude .. " --no-record --resume " .. a.claude) },
  { layout = tab("sleep 4242") },
  { layout = tab(nil) },
  { layout = split(tab(claude), tab(claude)) },
} }))
assert(rex.call("session.create", { label = "side", initial_windows = { { layout = tab(pi) } } }))
return "ok"
