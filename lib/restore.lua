--[[
[INPUT]: depends on rex.block and rex.sleep from the Rex Lua API; lib/util; lib/agents; lib/snapshot
[OUTPUT]: exports restore: key(pane), id(pane), text(pane), plan(saved, live, running, opts) (pure);
          running(saved, opts) -> open chat set; pending(saved, opts) -> what a restore would bring back;
          run(saved, opts) -> { agents, programs, reopened }; open(chat, session_id) -> a new tab
[POS]: the writer side of rex-revive, and the only module that types into terminals.
       plan decides; run collects, plans, types, and tries again while restored tabs settle;
       open starts a closed chat in a new tab, which needs no plan.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = require("util")
local agents = require("agents")
local snapshot = require("snapshot")

local restore = {}

local TRIES = 10       -- plans while restored tabs are still starting their shells
local WAIT = 3         -- seconds between those plans
local TYPE_GAP = 0.3   -- seconds between two typed commands

-- "agent:session" for a chat, nil for anything else.
function restore.key(p)
  if p.kind == "agent" and p.agent and p.session then return agents.key(p.agent, p.session) end
end

-- What a person picks in a question: a chat's key, or "program:<block>" for another program.
function restore.id(p)
  return restore.key(p) or (p.kind == "program" and p.block_id and "program:" .. p.block_id) or nil
end

-- What to type into an idle tab: a chat's resume command, run; another
-- program's command line, typed but not run.
function restore.text(p)
  if p.kind == "agent" then return util.join(agents.command(p)) .. "\n" end
  if p.kind == "program" and p.command and p.command ~= "" then return p.command end
end

local function where(p)
  return string.format("%s tab %d pane %d", p.session_label or "session", p.window_index or 0, p.pane_index or 0)
end

local function position(p)
  if not p.session_label then return nil end
  return p.session_label .. "\0" .. tostring(p.window_index) .. "\0" .. tostring(p.pane_index)
end

-- What to type where, so the saved panes run again.
--   saved, live  snaps (saved: the panes to bring back; live: every pane now)
--   running      { ["agent:session"] = true } for chats open anywhere
--   opts.only    { [id] = true }: just these, nothing else (ids: restore.id)
--   opts.leave   { [id] = true }: what not to reopen, as someone chose
--   opts.programs  false: chats only
--   opts.skip    { [block_id] = true }: typed into on an earlier try
--   opts.dir_exists  (tests replace it)
-- Returns actions, notes, and how many target tabs were busy.
-- A tab is matched by block ID (Rex keeps it across a restart), else by
-- session name and position. Only an idle shell is typed into, and a chat
-- open anywhere is never opened again.
function restore.plan(saved, live, running, opts)
  opts = opts or {}
  local dir_exists = opts.dir_exists or util.is_dir
  local open, by_block, by_position = {}, {}, {}
  for key in pairs(running or {}) do open[key] = true end
  for _, p in ipairs(util.list(live and live.panes)) do
    by_block[p.block_id] = p
    local pos = position(p)
    if pos and not by_position[pos] then by_position[pos] = p end
    local key = restore.key(p)
    if key then open[key] = true end
  end
  local actions, notes, busy, claimed = {}, {}, 0, {}
  for _, p in ipairs(util.list(saved and saved.panes)) do
    local key, id, text = restore.key(p), restore.id(p), restore.text(p)
    local wanted = text and (p.kind == "agent" or opts.programs ~= false)
      and (not opts.only or (id and opts.only[id]))
      and not (id and opts.leave and opts.leave[id])
    if wanted then
      local target = by_block[p.block_id] or by_position[position(p) or ""]
      if not target then
        notes[#notes + 1] = where(p) .. ": its tab is gone"
      elseif (opts.skip or {})[target.block_id] then
        -- Typed into on an earlier try.
      elseif (key and restore.key(target) == key)
          or (p.kind == "program" and target.kind == "program" and target.command == p.command) then
        -- Already running in its tab.
      elseif target.kind ~= "shell" or claimed[target.block_id] then
        notes[#notes + 1] = where(p) .. ": the tab is busy, left alone"
        busy = busy + 1
      elseif key and open[key] then
        notes[#notes + 1] = where(p) .. ": " .. key .. " is already open"
      else
        if p.cwd and p.cwd ~= target.cwd and dir_exists(p.cwd) then
          text = "cd " .. util.quote(p.cwd) .. " && " .. text
        end
        claimed[target.block_id] = true
        if key then open[key] = true end
        actions[#actions + 1] = { session_id = target.session_id, block_id = target.block_id, text = text,
                                  kind = p.kind, key = key, where = where(p),
                                  agent = p.agent, session = p.session, cwd = p.cwd }
      end
    end
  end
  return actions, notes, busy
end

-- The saved chats open anywhere now. Codex chats are seen by the session
-- file they hold; Claude and pi chats by their pid records.
function restore.running(saved, opts)
  local held = {}
  for _, p in ipairs(util.list(saved and saved.panes)) do
    if p.file and restore.key(p) then held[p.file] = restore.key(p) end
  end
  return agents.running(held, opts)
end

-- What a restore of saved would bring back, in save order: each chat not open
-- anywhere, once, and unless opts.programs is false each other program.
--   { key = restore.id, kind, agent, session, command, cwd, where }
-- It looks at the save only, not at tabs, so it works while restored tabs
-- are still starting.
function restore.pending(saved, opts)
  opts = opts or {}
  local open, out = restore.running(saved, opts), {}
  for _, p in ipairs(util.list(saved and saved.panes)) do
    local key, id, wanted = restore.key(p), restore.id(p), nil
    if key then
      wanted = not open[key]
    else
      wanted = id and restore.text(p) and opts.programs ~= false
    end
    if wanted then
      if key then open[key] = true end
      out[#out + 1] = { key = id, kind = p.kind, agent = p.agent, session = p.session, command = p.command,
                        cwd = p.cwd, where = where(p) }
    end
  end
  return out
end

-- Bring the saved panes back into the tabs Rex shows now.
--   opts: dry_run, only, leave, programs, tries, home, reader (passed to collect)
-- result.reopened: { [key] = true } for each chat typed.
-- Tabs Rex has just restored may still be starting their shells, which can
-- look busy, so it plans again for a while. A tab is typed into at most once.
function restore.run(saved, opts)
  opts = opts or {}
  local tries = opts.dry_run and 1 or opts.tries or TRIES
  local done, typed = {}, {}
  local result = { agents = 0, programs = 0, reopened = typed }
  for try = 1, tries do
    if try > 1 then rex.sleep(WAIT) end
    local live = snapshot.collect(opts)
    local running = restore.running(saved, opts)
    for key in pairs(typed) do running[key] = true end
    local actions, notes, busy = restore.plan(saved, live, running,
      { only = opts.only, leave = opts.leave, programs = opts.programs, skip = done })
    for _, a in ipairs(actions) do
      util.log(string.format("  %s %s: %s", opts.dry_run and "would type" or "type", a.where,
                             (a.text:gsub("\n$", " (run)"))))
      if not opts.dry_run then
        local ok, err = rex.block.call(snapshot.TERMINAL, "write",
          { session_id = a.session_id, block_id = a.block_id, data = a.text })
        if ok then
          done[a.block_id] = true
          if a.key then typed[a.key] = true end
          local count = a.kind == "agent" and "agents" or "programs"
          result[count] = result[count] + 1
        else
          util.log("  " .. a.where .. ": couldn't type into the tab: " .. tostring(err))
        end
        rex.sleep(TYPE_GAP)
      end
    end
    if busy == 0 or try == tries then
      for _, note in ipairs(notes) do util.log("  skip " .. note) end
      break
    end
    util.log(string.format("  %d tabs are busy, maybe still starting; trying again in %ds", busy, WAIT))
  end
  return result
end

-- Starts a chat in a new tab of a session, in the chat's folder: a closed
-- chat has no tab left to type into. Returns the new tab, or nil and an error.
-- A script must attach to a session before it adds a window there.
function restore.open(chat, session_id)
  local attached, err = rex.call("session.attach", { session_id = session_id })
  if not attached then return nil, err end
  return rex.call("session.new_window", { session_id = session_id, layout = { block = {
    flavor = snapshot.TERMINAL .. ".shell", options = { cwd = chat.cwd, initial_input = restore.text(chat) } } } })
end

return restore
