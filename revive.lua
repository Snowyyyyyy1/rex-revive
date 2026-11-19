--[[
rex-revive: bring back the coding agents and programs in your Rex tabs after
the Rex server restarts.

  rex do revive.lua --all                       watch: save as tabs change; restore after a restart
  rex do revive.lua mode=status                 what is saved, and the last restore
  rex do revive.lua mode=save                   save now
  rex do revive.lua mode=restore [dry_run=true] [only=agent:id,...] [programs=false]
  rex do revive.lua mode=choices                the chats a restore would bring back, as JSON
  rex do revive.lua mode=closed                 the closed chats, newest first, as JSON
  rex do revive.lua mode=reopen [key=agent:id] [session=ID]   a closed chat (else the newest) in a new tab
  rex do revive.lua mode=reopen from=ID [only=agent:id,...]   chats of an earlier save that aren't open
  rex do revive.lua mode=history                the saves with chats to reopen, newest first, as JSON
  rex do revive.lua mode=choices from=ID        the chats of that save that aren't open, as JSON
  rex do revive.lua mode=preview                what a restart would bring back now, as JSON
  rex do revive.lua mode=focus session=ID block=ID   show that tab
  rex do revive.lua mode=settings [ask=false]   show the settings, or change them
  rex do revive.lua mode=version

Common arguments: state_dir=DIR (where saves go), palette=true (also notify), notify=false,
log=FILE (also append log lines to FILE: the palette passes the watcher's log).
Watch arguments: rex=PATH (the rex command, to ask in the Rex app), ask=false (don't ask, whatever
the settings say).

[INPUT]: depends on lib/util, lib/snapshot, lib/restore, lib/titles, lib/closed from this repository; rex.args, rex.on,
         rex.after, rex.every, rex.call from the Rex Lua API
[OUTPUT]: the rex-revive command: one mode per run, or a long-running watcher
[POS]: the entry point. It owns arguments, settings.json, state.json, the restart check, and
       how a question's rows are ordered and ticked; lib/ does the reading, deciding, and typing.
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
if type(args.log) == "string" and args.log ~= "" then util.log_file = args.log end
local snapshot = require("snapshot")
local restore = require("restore")
local titles = require("titles")
local closed = require("closed")

local VERSION = "0.2.0"
local STATE_DIR = util.state_dir(args)
local SNAPS = STATE_DIR .. "/snapshots"
local STATE_FILE = STATE_DIR .. "/state.json"
local SETTINGS_FILE = STATE_DIR .. "/settings.json"   -- what the person chose; state.json is ours
local CLOSED_FILE = STATE_DIR .. "/closed.json"       -- lib/closed.lua
local MAX_AGE_DAYS = 30   -- an older save is never restored on its own
local SAVE_EVERY = 60     -- seconds between saves while watching, at the least
local SAVE_AFTER = 3      -- seconds to wait after a change before saving
local APP_WAIT = 20       -- seconds to wait for a Rex app to connect after a restart
local ASK_WAIT = 60       -- seconds to wait for an answer before reopening every chat
local STALE_DAYS = 14     -- a chat idle longer starts unticked in a question

-- What the person chose, defaults filled in. ask: ask in the Rex app which
-- chats to reopen after a restart (true), or reopen every chat (false).
local function settings()
  local chosen = util.read_json(SETTINGS_FILE) or {}
  chosen.ask = chosen.ask ~= false
  return chosen
end

-- notify=false keeps a run quiet (the tests use it).
local function notify(message)
  if args.notify ~= false then util.notify(message) end
end

-- A run's outcome: printed, logged when the run has a log file, and from the palette also notified.
local function tell(message)
  if util.log_file then util.log(message) else print(message) end
  if args.palette == true then notify(message) end
end

-- Remembers the gone chats as closed, forgets the keys in back, and logs each newly closed chat.
local function remember(gone, back, why)
  for _, chat in ipairs(closed.update(CLOSED_FILE, gone, back)) do
    util.log(string.format("closed %s (%s, %s): %s", chat.key, tostring(chat.session_label), tostring(chat.cwd), why))
  end
end

-- only=claude:ID,pi:ID -> { ["claude:ID"] = true, ... }
local function only()
  if type(args.only) ~= "string" or args.only == "" then return nil end
  local out = {}
  for key in args.only:gmatch("[^,]+") do out[key] = true end
  return out
end

-- A chat the last save had and this one hasn't is closed; one back in a tab isn't.
local function save()
  local snap, before = snapshot.save(SNAPS, snapshot.collect())
  snapshot.checkpoint(SNAPS, snap)
  local gone, present = closed.diff(before, snap)
  remember(gone, present, "its tab closed or its agent quit")
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

-- The watcher starts within a second of the server, often before the app reconnects.
local function app_connected()
  for _ = 1, APP_WAIT * 2 do
    for _, c in ipairs(util.list((rex.call("client.list") or {}).clients)) do
      if c.info and c.info.kind == "app" then return true end
    end
    rex.sleep(0.5)
  end
  return false
end

-- A question's rows, sorted in place: titles in, the chats active most
-- recently first, then the programs. A chat idle over STALE_DAYS starts unticked.
local function ranked(items)
  titles.label(items)
  local order = {}
  for i, item in ipairs(items) do
    order[item] = i
    item.ticked = not (item.idle and item.idle > STALE_DAYS * 86400)
  end
  local function weight(item)
    if item.kind ~= "agent" then return 3, order[item] end
    if item.idle then return 1, item.idle end
    return 2, order[item]
  end
  table.sort(items, function(a, b)
    local group_a, value_a = weight(a)
    local group_b, value_b = weight(b)
    if group_a ~= group_b then return group_a < group_b end
    if value_a ~= value_b then return value_a < value_b end
    return order[a] < order[b]
  end)
  return items
end

-- After a restart, ask in the Rex app what to reopen (items: restore.pending),
-- through the revive_choose action of integrations/rex_revive.lua. Returns the
-- ids to leave closed, or nil unless someone pressed Reopen: then everything
-- comes back. A closed question counts as no answer, as the app can close it
-- unseen. Programs are only typed, never run: alone they aren't worth a question.
local function ask(items)
  local wanted = args.ask
  if wanted == nil then wanted = settings().ask end
  if not wanted then return nil end
  local chats = 0
  for _, item in ipairs(items) do
    if item.kind == "agent" then chats = chats + 1 end
  end
  if chats == 0 or not app_connected() then return nil end
  util.log(string.format("asking in the Rex app which of %s and %s to reopen",
                         count(chats, "chat"), count(#items - chats, "program")))
  ranked(items)
  local out = util.stdout({ args.rex or "rex", "--autostart=false", "do", "revive_choose",
                            "--args", rex.json.encode({ items = items, timeout = ASK_WAIT }),
                            "--timeout", ASK_WAIT + 5 .. "s" },
                          { timeout = ASK_WAIT + 10 })
  local ok, answer = pcall(rex.json.decode, out:match("([^\n]+)\n*$") or "")
  if not ok or type(answer) ~= "table" or type(answer.keys) ~= "table" then
    util.log("no answer (" .. tostring(type(answer) == "table" and answer.status or "none")
             .. "); reopening everything")
    return nil
  end
  local chosen, leave = {}, {}
  for _, key in ipairs(answer.keys) do chosen[key] = true end
  for _, item in ipairs(items) do
    if not chosen[item.key] then leave[item.key] = true end
  end
  util.log(string.format("reopening %d of %d, as chosen", #answer.keys, #items))
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
  local items = restore.pending(saved, { programs = args.programs })
  local leave = ask(items)
  local result = restore.run(saved, { programs = args.programs, leave = leave })
  util.log(report(result))
  -- Someone who pressed Reopen knows what comes back; tell the others.
  if not leave and result.agents + result.programs > 0 then notify(report(result)) end
  -- The chats that didn't come back, unticked or with their tab gone, are closed now.
  local waiting, gone = {}, {}
  for _, item in ipairs(items) do waiting[item.key] = true end
  for _, p in ipairs(saved.panes) do
    local key = restore.key(p)
    if key and waiting[key] and not result.reopened[key] then gone[#gone + 1] = p end
  end
  remember(gone, {}, "not brought back after the restart")
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
  print("After a restart: " .. (settings().ask and "ask in the Rex app which chats to reopen" or "reopen every chat"))
  local state = util.read_json(STATE_FILE) or {}
  if state.last_restore then
    print(string.format("Last restore at %s, from the save of %s", state.last_restore.at, state.last_restore.from))
  end
end

-- An earlier save by the id snapshot.saves gives it, or nil.
local function earlier(id)
  for _, snap in ipairs(snapshot.saves(SNAPS)) do
    if snap.id == id then return snap end
  end
end

-- The chats of a save that aren't open anywhere now, as a question's rows.
local function pending_chats(saved)
  return ranked(restore.pending(saved, { programs = false }))
end

-- The chats a restore would bring back, as a question's rows: from the save
-- (from=, else the one restore uses), not from the tabs, so a tab still
-- starting after a restart doesn't hide its chat.
local function choices_mode()
  local saved
  if args.from then
    saved = earlier(args.from)
  else
    saved = source((rex.call("server.status") or {}).instance_id)
  end
  local out = saved and pending_chats(saved) or {}
  if #out == 0 and args.palette == true then notify("No saved chats to reopen.") end
  print(rex.json.encode(out))
end

-- The closed chats that aren't open anywhere now, newest first.
local function closed_chats()
  local list = closed.list(CLOSED_FILE)
  local open, out = restore.running({ panes = list }), {}
  for _, chat in ipairs(list) do
    if not open[chat.key] then out[#out + 1] = chat end
  end
  return out
end

local function closed_mode()
  local out = titles.label(closed_chats())
  if #out == 0 and args.palette == true then notify("No closed chats to reopen.") end
  print(rex.json.encode(out))
end

-- The saves with chats to reopen, newest first: { id, saved_at, title (local
-- time), summary, chats, ago }.
local function history_mode()
  local out, now, saves, panes = {}, os.time(), snapshot.saves(SNAPS), {}
  for _, snap in ipairs(saves) do
    for _, p in ipairs(snap.panes) do panes[#panes + 1] = p end
  end
  -- One look at what runs, for every save: ps and lsof once, not once a save.
  local running = restore.running({ panes = panes })
  for _, snap in ipairs(saves) do
    local chats = #restore.pending(snap, { programs = false, running = running })
    local at = util.epoch(snap.saved_at)
    if chats > 0 and at then
      out[#out + 1] = { id = snap.id, saved_at = snap.saved_at, title = os.date("%b %d, %H:%M", at),
                        summary = snapshot.summary(snap), chats = chats, ago = titles.ago(now - at) }
    end
  end
  if #out == 0 and args.palette == true then notify("No earlier saves with chats to reopen.") end
  print(rex.json.encode(out))
end

-- What a restart would bring back now, tab by tab: each chat with the command
-- that resumes it (runs = true), each other program typed but not run, and
-- each agent whose chat isn't known (note), which comes back typed only.
local function preview_mode()
  local out = {}
  for _, p in ipairs(snapshot.collect().panes) do
    local text = restore.text(p)
    if p.kind ~= "shell" and text then
      out[#out + 1] = { key = restore.id(p), kind = p.kind, agent = p.agent, session = p.session,
                        command = p.command, cwd = p.cwd, where = restore.where(p), note = p.note,
                        typed = (text:gsub("\n$", "")), runs = text:sub(-1) == "\n",
                        session_id = p.session_id, block_id = p.block_id }
    end
  end
  titles.label(out)
  if #out == 0 and args.palette == true then notify("A restart now would bring nothing back: no chats or programs run.") end
  print(rex.json.encode(out))
end

local function focus_mode()
  if not (args.session and args.block and rex.call("session.attach", { session_id = args.session })) then return end
  rex.session.focus_block{ session_id = args.session, block_id = args.block }
end

local function first_session()
  local first = util.list((rex.call("session.list") or {}).sessions)[1]
  return first and first.session_id
end

-- Brings one chat back, trying the sessions in order (nil and "" skipped):
-- in its own tab if that is an idle shell and its session comes first, else
-- in its old place beside its neighbour pane, else in a new tab. Returns
-- where it went ("its tab", "its old place", "a new tab"), or nil and an error.
local function bring_back(chat, sessions)
  local first = sessions[1]
  if (first == nil or first == chat.session_id) and restore.into_tab(chat) then return "its tab" end
  local err
  for i = 1, 3 do
    local session_id = sessions[i]
    if type(session_id) == "string" and session_id ~= "" then
      local opened, kind = restore.open(chat, session_id)
      if opened then return kind == "split" and "its old place" or "a new tab" end
      err = kind
    end
  end
  return nil, err
end

-- The chats of an earlier save (from=) that aren't open now, or those of
-- them in only=: each in its own session, else the one the person is in.
local function reopen_from()
  local saved = earlier(args.from)
  if not saved then return tell("No save " .. tostring(args.from) .. ".") end
  local wanted, todo, n = only(), {}, 0
  for _, item in ipairs(restore.pending(saved, { programs = false })) do
    if not wanted or wanted[item.key] then todo[item.key] = true end
  end
  for _, p in ipairs(saved.panes) do
    local key = restore.key(p)
    if key and todo[key] then
      todo[key] = nil
      local how, err = bring_back(p, { p.session_id, args.session, first_session() })
      if how then
        n = n + 1
        util.log("reopened " .. key .. " from the save of " .. saved.saved_at .. " in " .. how)
      else
        util.log("couldn't reopen " .. key .. ": " .. tostring(err))
      end
    end
  end
  tell("Reopened " .. count(n, "chat") .. " from the save of " .. saved.saved_at .. ".")
end

-- A closed chat (key=, else the newest), in the session the person is in
-- (session=, else the chat's own, else the first one). from= reopens from an earlier save instead.
local function reopen_mode()
  if args.from then return reopen_from() end
  local chat
  for _, c in ipairs(closed_chats()) do
    if not args.key or c.key == args.key then
      chat = c
      break
    end
  end
  if not chat then return tell("No closed chats to reopen.") end
  local how, err = bring_back(chat, { args.session or chat.session_id, chat.session_id, first_session() })
  if not how then return tell("Couldn't reopen " .. chat.key .. ": " .. tostring(err)) end
  -- Out of the list now, so a second press reopens the next one.
  closed.update(CLOSED_FILE, {}, { [chat.key] = true })
  util.log("reopened " .. chat.key .. " in " .. how)
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

-- Prints the settings as JSON; with ask=true or ask=false, changes them first.
local function settings_mode()
  local chosen = settings()
  if args.ask ~= nil then
    chosen.ask = args.ask ~= false
    util.mkdirs(STATE_DIR)
    util.write_json(SETTINGS_FILE, chosen)
  end
  print(rex.json.encode(chosen))
end

local MODES = {
  watch = watch,
  save = save,
  startup = startup,
  status = status_mode,
  choices = choices_mode,
  closed = closed_mode,
  reopen = reopen_mode,
  history = history_mode,
  preview = preview_mode,
  focus = focus_mode,
  settings = settings_mode,
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
  error("unknown mode " .. tostring(args.mode)
        .. "; use watch, save, restore, choices, closed, reopen, history, preview, focus, settings, status, or version", 0)
end
mode()
