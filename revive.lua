--[[
rex-revive: bring back the coding agents and programs in your Rex tabs after
the Rex server restarts.

  rex do revive.lua --all                       watch: save as tabs change; restore after a restart
  rex do revive.lua mode=status                 what is saved, and the last restore
  rex do revive.lua mode=save                   save now
  rex do revive.lua mode=restore [dry_run=true] [only=agent:id,...] [programs=false]
  rex do revive.lua mode=choices                the chats a restore would bring back, as JSON
  rex do revive.lua mode=version

Common arguments: state_dir=DIR (where saves go), palette=true (also notify), notify=false.
Watch arguments: rex=PATH (the rex command, to ask in the Rex app), ask=false (never ask).

[INPUT]: depends on lib/util, lib/snapshot, lib/restore from this repository; rex.args, rex.on,
         rex.after, rex.every, rex.call from the Rex Lua API
[OUTPUT]: the rex-revive command: one mode per run, or a long-running watcher
[POS]: the entry point. It owns arguments, state.json, and the restart check;
       lib/ does the reading, deciding, and typing.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local args = rex.args or {}

-- lib/ sits next to this file; root=DIR overrides it when a run can't tell.
-- Rex gives the script path with or without Lua's usual "@" prefix.
local function root()
  if args.root then return args.root end
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return source:match("^(.*)/[^/]*$") or "."
end
package.path = root() .. "/lib/?.lua;" .. package.path

local util = require("util")
local snapshot = require("snapshot")
local restore = require("restore")

local VERSION = "0.1.0"
local STATE_DIR = util.state_dir(args)
local SNAPS = STATE_DIR .. "/snapshots"
local STATE_FILE = STATE_DIR .. "/state.json"
local MAX_AGE_DAYS = 30   -- an older save is never restored on its own
local SAVE_EVERY = 60     -- seconds between saves while watching, at the least
local SAVE_AFTER = 3      -- seconds to wait after a change before saving
local APP_WAIT = 20       -- seconds to wait for a Rex app to connect after a restart
local ASK_WAIT = 60       -- seconds to wait for an answer before reopening every chat

-- notify=false keeps a run quiet (the tests use it).
local function notify(message)
  if args.notify ~= false then util.notify(message) end
end

local function tell(message)
  print(message)
  if args.palette == true then notify(message) end
end

-- only=claude:ID,pi:ID -> { ["claude:ID"] = true, ... }
local function only()
  if type(args.only) ~= "string" or args.only == "" then return nil end
  local out = {}
  for key in args.only:gmatch("[^,]+") do out[key] = true end
  return out
end

local function save()
  local snap = snapshot.save(SNAPS, snapshot.collect())
  if args.verbose == true or args.palette == true then tell("Saved " .. snapshot.summary(snap) .. ".") end
  return snap
end

-- The save to bring back: the newest one of an earlier server, else the newest.
local function source(instance)
  return snapshot.previous(SNAPS, instance) or snapshot.all(SNAPS)[1]
end

local function count(n, noun)
  return string.format("%d %s%s", n, noun, n == 1 and "" or "s")
end

local function report(result)
  local text = "Reopened " .. count(result.agents, "chat")
  if result.programs > 0 then text = text .. " and typed " .. count(result.programs, "other program") end
  return text .. "."
end

local function app_connected()
  for _ = 1, APP_WAIT / 2 do
    for _, c in ipairs(util.list((rex.call("client.list") or {}).clients)) do
      if c.info and c.info.kind == "app" then return true end
    end
    rex.sleep(2)
  end
  return false
end

-- After a restart, ask in the Rex app which chats to reopen, through the
-- revive_choose action of integrations/rex_revive.lua. Returns the chats to
-- leave closed, or nil unless someone pressed Reopen: then every chat comes
-- back. A closed question counts as no answer, as the app can close it unseen.
local function ask(saved)
  if args.ask == false then return nil end
  local chats = restore.chats(saved)
  if #chats == 0 or not app_connected() then return nil end
  util.log("asking in the Rex app which of " .. #chats .. " chats to reopen")
  local out = util.stdout({ args.rex or "rex", "--autostart=false", "do", "revive_choose",
                            "--args", rex.json.encode({ chats = chats }), "--timeout", ASK_WAIT .. "s" },
                          { timeout = ASK_WAIT + 10 })
  local ok, answer = pcall(rex.json.decode, out:match("([^\n]+)\n*$") or "")
  if not ok or type(answer) ~= "table" or type(answer.keys) ~= "table" then
    util.log("no answer (" .. tostring(type(answer) == "table" and answer.status or "none")
             .. "); reopening every chat")
    return nil
  end
  local chosen, leave = {}, {}
  for _, key in ipairs(answer.keys) do chosen[key] = true end
  for _, c in ipairs(chats) do
    if not chosen[c.key] then leave[c.key] = true end
  end
  util.log(string.format("reopening %d of %d chats, as chosen", #answer.keys, #chats))
  return leave
end

-- Once per server instance: bring back the save of the server before it.
local function startup()
  local status = assert(rex.call("server.status"))
  local state = util.read_json(STATE_FILE) or {}
  if state.instance == status.instance_id then return save() end
  -- Record the instance first, so a crash below never restores twice.
  state.instance = status.instance_id
  util.mkdirs(STATE_DIR)
  util.write_json(STATE_FILE, state)
  local saved = snapshot.previous(SNAPS, status.instance_id)
  local cutoff = util.iso(os.time() - MAX_AGE_DAYS * 86400)
  if not saved or #saved.panes == 0 or saved.saved_at < cutoff then
    util.log("new Rex server; nothing to bring back")
    return save()
  end
  util.log("new Rex server; bringing back the save from " .. saved.saved_at)
  local leave = ask(saved)
  local result = restore.run(saved, { programs = args.programs, leave = leave })
  util.log(report(result))
  -- Someone who pressed Reopen knows what comes back; tell the others.
  if not leave and result.agents + result.programs > 0 then notify(report(result)) end
  state.last_restore = { at = util.now_iso(), from = saved.saved_at, instance = status.instance_id,
                         agents = result.agents, programs = result.programs }
  util.write_json(STATE_FILE, state)
  return save()
end

local function status_mode()
  local status = rex.call("server.status") or {}
  print("rex-revive " .. VERSION .. " (" .. STATE_DIR .. ")")
  print("Rex server " .. tostring(status.instance_id) .. ", started " .. tostring(status.started_at))
  local snaps = snapshot.all(SNAPS)
  if #snaps == 0 then print("No saves yet.") end
  for i, snap in ipairs(snaps) do
    if i > 3 then break end
    local which = snap.server.instance == status.instance_id and "this server" or "an earlier server"
    print(string.format("Save of %s (%s): %s", snap.saved_at, which, snapshot.summary(snap)))
  end
  local state = util.read_json(STATE_FILE) or {}
  if state.last_restore then
    print(string.format("Last restore at %s, from the save of %s", state.last_restore.at, state.last_restore.from))
  end
end

local function choices_mode()
  local live = snapshot.collect()
  local saved = source(live.server.instance)
  local out = {}
  if saved then
    local actions = restore.plan(saved, live, restore.running(saved), { programs = false })
    for _, a in ipairs(actions) do
      out[#out + 1] = { key = a.key, agent = a.agent, session = a.session, cwd = a.cwd, where = a.where }
    end
  end
  if #out == 0 and args.palette == true then notify("No saved chats to reopen.") end
  print(rex.json.encode(out))
end

-- Save after each change and on a timer; restore when the server is new.
-- A failed save is logged, never fatal: the watcher must keep running.
local function watch()
  local instance
  local function guarded(f)
    local ok, err = pcall(f)
    if not ok then util.log("error: " .. tostring(err)) end
  end
  local function tick()
    local status = rex.call("server.status")
    if not status then return end
    if status.instance_id ~= instance then
      instance = status.instance_id
      guarded(startup)
    else
      guarded(save)
    end
  end
  local pending
  local function soon()
    if pending then return end
    pending = rex.after(SAVE_AFTER, function() pending = nil; guarded(save) end)
  end
  for _, event in ipairs({ "session_created", "session_destroyed", "session_view_changed", "block_created",
                           "block_closed", "terminal.process_changed", "terminal.pwd_changed" }) do
    rex.on(event, soon)
  end
  util.log("rex-revive " .. VERSION .. " watching; saves in " .. STATE_DIR)
  tick()
  rex.every(SAVE_EVERY, tick)
end

local MODES = {
  watch = watch,
  save = save,
  startup = startup,
  status = status_mode,
  choices = choices_mode,
  version = function() print("rex-revive " .. VERSION) end,
  restore = function()
    local live = snapshot.collect()
    local saved = source(live.server.instance)
    if not saved then return print("No save to restore from.") end
    print("Restoring from the save of " .. saved.saved_at)
    local result = restore.run(saved, { dry_run = args.dry_run == true, only = only(), programs = args.programs })
    if args.dry_run ~= true then tell(report(result)) end
  end,
}

local mode = MODES[args.mode or "watch"]
if not mode then
  error("unknown mode " .. tostring(args.mode) .. "; use watch, save, restore, choices, status, or version", 0)
end
mode()
