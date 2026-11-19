--[[
[INPUT]: depends on lib/util (JSON files, times); lib/restore (key)
[OUTPUT]: exports closed: KEEP, diff(before, after) and merge(list, gone, back, now) (pure);
          update(path, gone, back) and list(path) on closed.json
[POS]: the memory of closed chats. A chat is closed when a save no longer has it: its tab
       was closed, or its agent quit, or a restart left it closed. revive.lua feeds it on
       every save and after a restart; mode=closed and mode=reopen read it.
       It keeps what reopening needs (restore.text and restore.running read the same fields).
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = require("util")
local restore = require("restore")

local closed = {}

closed.KEEP = 20  -- closed chats remembered, newest first

-- The saved fields that reopen a chat and tell whether it runs.
local FIELDS = { "kind", "agent", "session", "options", "exe", "file", "cwd", "session_id", "session_label" }

-- The chats of before that after lacks, as panes, and the keys of the chats in after.
function closed.diff(before, after)
  local present = {}
  for _, p in ipairs(util.list(after and after.panes)) do
    local key = restore.key(p)
    if key then present[key] = true end
  end
  local gone = {}
  for _, p in ipairs(util.list(before and before.panes)) do
    local key = restore.key(p)
    if key and not present[key] then gone[#gone + 1] = p end
  end
  return gone, present
end

-- The list with the gone chats in front and the chats in back taken out, at most KEEP.
-- A chat closed again moves to the front. Returns the new list and whether it changed.
function closed.merge(list, gone, back, now)
  local out, seen, changed = {}, {}, false
  for _, p in ipairs(gone) do
    local key = restore.key(p)
    if key and not seen[key] and not back[key] and #out < closed.KEEP then
      seen[key] = true
      local entry = { key = key, closed_at = now }
      for _, field in ipairs(FIELDS) do entry[field] = p[field] end
      out[#out + 1] = entry
      changed = true
    end
  end
  for _, entry in ipairs(list) do
    if seen[entry.key] or back[entry.key] or #out == closed.KEEP then
      changed = true
    else
      seen[entry.key] = true
      out[#out + 1] = entry
    end
  end
  return out, changed
end

function closed.list(path)
  local list = util.read_json(path)
  return type(list) == "table" and list or {}
end

-- Adds the gone chats and drops the chats in back (a set of keys); writes only on a change.
function closed.update(path, gone, back)
  local list, changed = closed.merge(closed.list(path), gone, back or {}, util.now_iso())
  if changed then util.write_json(path, list) end
end

return closed
