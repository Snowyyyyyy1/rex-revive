--[[
[INPUT]: depends on rex.call, rex.session, rex.block from the Rex Lua API; lib/util; lib/proc; lib/agents
[OUTPUT]: exports snapshot: TERMINAL, chain(process), describe(process, info, opts) -> pane fields (pure);
          collect(opts) -> snap; save(dir, snap); all(dir); previous(dir, instance); summary(snap)
[POS]: the reader side of rex-revive. It turns what Rex shows now into a snap, and keeps snaps on disk.
       restore.lua consumes both a saved snap and a fresh one. It never writes to a terminal.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = require("util")
local proc = require("proc")
local agents = require("agents")

local snapshot = {}

local TERMINAL = "com.superlogical.terminal"
snapshot.TERMINAL = TERMINAL
local KEEP = 10  -- snaps kept, one per Rex server instance

local SHELLS = {}
for _, name in ipairs({ "bash", "zsh", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish" }) do
  SHELLS[name] = true
end

local function is_shell(p)
  for name in pairs(proc.names(p)) do
    if SHELLS[name] then return true end
  end
  return false
end

-- The processes of a tab, nearest the screen first: the foreground process,
-- then its parents up to the one the terminal started. login is skipped.
function snapshot.chain(process)
  local out, seen = {}, {}
  local candidates = { process.foreground }
  for _, p in ipairs(util.list(process.ancestors)) do candidates[#candidates + 1] = p end
  for _, p in ipairs(candidates) do
    if type(p) == "table" and p.pid and not seen[p.pid] and p.name ~= "login" then
      seen[p.pid] = true
      out[#out + 1] = p
    end
  end
  return out
end

-- A process's command line as ps shows it, without trailing blanks.
local function command_of(p, info)
  local args = (info.ps[p.pid] or {}).args
  args = args and args:gsub("%s+$", "")
  if args and args ~= "" then return args end
end

-- What a tab runs, from its process chain:
--   { kind = "agent", agent, session, options, exe, file, cwd }   a coding agent's chat
--   { kind = "program", command, cwd }                            anything else in the foreground
--   { kind = "shell", cwd }                                       an idle prompt
-- An agent whose session isn't certain becomes a program, so it comes back typed, not run.
function snapshot.describe(process, info, opts)
  local chain = snapshot.chain(process)
  local outer = chain[#chain] or process.child or {}
  for _, p in ipairs(chain) do
    local chat = agents.identify(p, info, opts)
    if chat then
      chat.cwd = p.cwd or outer.cwd
      if chat.session then
        chat.kind = "agent"
        return chat
      end
      return { kind = "program", cwd = chat.cwd, note = "session unknown",
               command = command_of(p, info) or chat.agent }
    end
  end
  local top = chain[1]
  if not top or is_shell(top) then return { kind = "shell", cwd = (top or outer).cwd } end
  return { kind = "program", cwd = top.cwd or outer.cwd, command = command_of(top, info) or top.name }
end

-- The leaves of a tiled layout, in order: before before after.
local function leaves(node, out)
  out = out or {}
  if type(node) ~= "table" then return out end
  if node.split then
    leaves(node.split.before, out)
    leaves(node.split.after, out)
  elseif node.block_id then
    out[#out + 1] = node.block_id
  end
  return out
end

-- Everything Rex shows now: one pane per local terminal, with where it sits.
--   opts.home, opts.reader  passed on to agents.identify (tests use them)
function snapshot.collect(opts)
  local status = assert(rex.call("server.status"))
  local attached = assert(rex.call("session.attach_all", { event_scope = "session" }))
  local found, pids, file_pids = {}, {}, {}
  for _, s in ipairs(util.list(attached.sessions)) do
    local view = rex.session.view{ session_id = s.session_id }
    for wi, w in ipairs(util.list(view and view.windows)) do
      local terminals = {}
      for _, layer in ipairs(util.list(w.layers)) do
        for _, b in ipairs(util.list(layer.blocks)) do
          -- Only this machine's terminals: a block on another host has its own processes.
          local here = b.host_id == nil or b.host_id == status.host_id
          if b.creator_name == TERMINAL and here then terminals[b.block_id] = true end
        end
      end
      for _, layer in ipairs(util.list(w.layers)) do
        if layer.kind == "tiled" then
          for pi, block_id in ipairs(leaves(layer.layout)) do
            if terminals[block_id] then
              local process = rex.block.call(TERMINAL, "process",
                { session_id = s.session_id, block_id = block_id }) or {}
              for _, p in ipairs(snapshot.chain(process)) do
                pids[#pids + 1] = p.pid
                if agents.needs_files(p) then file_pids[#file_pids + 1] = p.pid end
              end
              found[#found + 1] = {
                process = process,
                pane = { session_id = s.session_id, session_label = s.label, window_id = w.window_id,
                         window_index = wi, pane_index = pi, block_id = block_id },
              }
            end
          end
        end
      end
    end
  end
  local info = proc.info(pids, file_pids)
  local panes = {}
  for _, f in ipairs(found) do
    for key, value in pairs(snapshot.describe(f.process, info, opts)) do f.pane[key] = value end
    panes[#panes + 1] = f.pane
  end
  return {
    tool = "rex-revive", version = 1, saved_at = util.now_iso(),
    server = { instance = status.instance_id, started_at = status.started_at },
    panes = panes,
  }
end

---------------------------------------------------------------------------
-- Snaps on disk: <dir>/<server instance>.json, the newest KEEP of them

-- Only what is worth bringing back: idle shells are left out.
function snapshot.save(dir, snap)
  local path = dir .. "/" .. snap.server.instance .. ".json"
  -- A new server instance adds a file: only then make the folder and prune.
  local new = not util.exists(path)
  if new then util.mkdirs(dir) end
  local kept = {}
  for _, p in ipairs(snap.panes) do
    if p.kind ~= "shell" then kept[#kept + 1] = p end
  end
  local out = {}
  for key, value in pairs(snap) do out[key] = value end
  out.panes = kept
  util.write_json(path, out)
  if new then
    local all = snapshot.all(dir)
    for i = KEEP + 1, #all do os.remove(all[i].path) end
  end
  return out
end

-- Every snap in dir, newest first.
function snapshot.all(dir)
  local out = {}
  for _, path in ipairs(util.list_dir(dir, ".json")) do
    local snap = util.read_json(path)
    if type(snap) == "table" and type(snap.server) == "table" and snap.saved_at and type(snap.panes) == "table" then
      snap.path = path
      out[#out + 1] = snap
    end
  end
  table.sort(out, function(a, b) return a.saved_at > b.saved_at end)
  return out
end

-- The newest snap of another server instance: what was open before this one.
function snapshot.previous(dir, instance)
  for _, snap in ipairs(snapshot.all(dir)) do
    if snap.server.instance ~= instance then return snap end
  end
end

function snapshot.summary(snap)
  local counts, programs = {}, 0
  for _, p in ipairs(util.list(snap and snap.panes)) do
    if p.kind == "agent" then
      counts[p.agent] = (counts[p.agent] or 0) + 1
    elseif p.kind == "program" then
      programs = programs + 1
    end
  end
  local parts = {}
  for _, name in ipairs(agents.ORDER) do
    if counts[name] then parts[#parts + 1] = counts[name] .. " " .. name end
  end
  local chats = #parts > 0 and table.concat(parts, ", ") or "no chats"
  return string.format("%s; %d other programs", chats, programs)
end

return snapshot
