--[[
[INPUT]: depends on rex.action, rex.bind, rex.bindings, rex.exec, rex.ui.pick, rex.json from the Rex
         config Lua API; runs revive.lua through the rex command
[OUTPUT]: command palette actions revive_choose (asks with rex.ui.pick), revive_restore, revive_save,
          revive_reopen_closed (asks with rex.ui.pick), revive_reopen_last (bound to ⇧⌘T unless this
          config already binds that key), revive_preview (lists what a restart would bring back; a
          pick shows that tab), revive_reopen_earlier (picks an earlier save, then its chats),
          revive_settings (asks with rex.ui.pick whether to ask after a restart). The watcher also runs revive_choose with args.items after a restart, to ask in
          the Rex app.
[POS]: the Rex config side of rex-revive. install.sh copies it to ~/.config/rex/rex_revive.lua and
       fills in @REX@, @SCRIPT@, and @LOG@ (the watcher's log, empty without one); init.lua loads it with require("rex_revive"). It only starts
       revive.lua runs and asks questions; revive.lua does the work.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local REX = "@REX@"
local SCRIPT = "@SCRIPT@"
local LOG = "@LOG@"
local HOME = os.getenv("HOME") or ""
local REOPEN_KEY = "shift+cmd+t"

local function command(mode, extra)
  local argv = { REX, "--autostart=false", "do", SCRIPT, "mode=" .. mode, "palette=true" }
  -- Its output goes nowhere, so it appends to the watcher's log.
  if LOG ~= "" then argv[#argv + 1] = "log=" .. LOG end
  for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
  return argv
end

-- Start a revive.lua run in the background; it reports with a notification.
local function start(mode, extra)
  local handle, err = rex.exec.start(command(mode, extra), { detach = true })
  if not handle then error("rex-revive: " .. tostring(err), 0) end
end

-- Run revive.lua and wait for the JSON it prints last, after any log lines.
local function run_revive(mode, extra)
  local r = rex.exec(command(mode, extra), { timeout = 60 })
  if not (r and r.ok) then error("rex-revive: " .. tostring(r and r.stderr or "couldn't run rex"), 0) end
  local ok, value = pcall(rex.json.decode, r.stdout:match("([^\n]+)\n*$") or "")
  if ok and type(value) == "table" then return value end
end

local function short(path)
  path = tostring(path or "")
  if HOME ~= "" and path:sub(1, #HOME) == HOME then return "~" .. path:sub(#HOME + 1) end
  return path
end

-- One row of a pick. item: a chat { key, agent, session, cwd, where or session_label,
-- and from lib/titles: title, ago } or a program { key, kind = "program", command, cwd, where }.
-- In a multiple pick, item.ticked == false starts it unticked. A chat reads its title, else its folder.
local function row(item, multiple)
  local folder = short(item.cwd)
  local selected = multiple and item.ticked ~= false or nil
  if item.kind == "program" then
    return { id = item.key, icon = "terminal", selected = selected, title = item.command,
             subtitle = "typed, not run · " .. folder .. " · " .. tostring(item.where) }
  end
  return {
    id = item.key, icon = "code", selected = selected,
    title = item.title or (folder:match("([^/]+)/*$") or folder),
    subtitle = item.agent .. " · " .. folder .. " · " .. tostring(item.where or item.session_label),
    detail = item.ago or tostring(item.session):sub(1, 8),
  }
end

-- rex.ui.pick: the answer, or nil and why not (cancelled, timeout, busy, ...).
-- It must run in the action's own body: no pcall around this, or Rex answers "failed".
local function pick(question)
  if not (rex.ui and rex.ui.pick) then error("rex-revive: this Rex has no rex.ui; update Rex", 0) end
  local answer, status, err = rex.ui.pick(question)
  if status == "failed" then error("rex-revive: " .. tostring(err), 0) end
  return answer, status
end

-- Ask which items to reopen, each ticked as revive.lua says. Returns the chosen
-- keys, or nil and why not.
local function choose(items, title, timeout)
  local rows = {}
  for _, item in ipairs(items) do rows[#rows + 1] = row(item, true) end
  -- In a multiple pick Cmd+Return answers (Rex docs, Custom UI), which is easy to miss.
  local keys, status = pick{ title = title, timeout = timeout, placeholder = "Filter · ⌘↩ reopens the ticked ones",
                             items = rows, multiple = true, confirm = "Reopen" }
  return type(keys) == "table" and keys or nil, status
end

-- From the palette: ask, then start a restore of the chosen chats.
-- From the watcher after a restart (args.items set: chats and programs): ask,
-- and answer with the chosen keys. A closed question answers with no keys, and
-- the watcher then reopens everything: an app can close a question that nobody saw.
rex.action{
  name = "revive_choose",
  title = "Choose Chats to Reopen…",
  description = "Lists the saved chats that aren't open, recent ones ticked, and reopens the ones you tick.",
  category = "rex-revive",
  keywords = "revive restore resume reopen choose pick chats claude codex pi",
  args = { items = "array?", timeout = "number?" },
  run = function(_, a)
    if a.items then
      local programs = false
      for _, item in ipairs(a.items) do programs = programs or item.kind == "program" end
      local title = programs and "Rex restarted · Reopen chats and programs" or "Rex restarted · Reopen chats"
      local keys, status = choose(a.items, title, a.timeout)
      return { keys = keys, status = status }
    end
    local chats = run_revive("choices")
    if not chats or #chats == 0 then return end
    local keys = choose(chats, "Reopen chats")
    if not keys or #keys == 0 then return end
    start("restore", { "only=" .. table.concat(keys, ",") })
  end,
}

rex.action{
  name = "revive_restore",
  title = "Reopen Chats and Programs in Their Tabs",
  description = "Reopens every saved chat that isn't open, and types other programs at their prompts.",
  category = "rex-revive",
  keywords = "revive restore resume reopen chats programs claude codex pi",
  run = function() start("restore") end,
}

rex.action{
  name = "revive_save",
  title = "Save Open Chats and Programs Now",
  description = "Saves now. rex-revive also saves a few seconds after any change.",
  category = "rex-revive",
  keywords = "revive save snapshot chats programs",
  run = function() start("save") end,
}

-- A new tab goes into the session the app shows (ctx.session_id), when Rex says which.
local function reopen(ctx, extra)
  extra = extra or {}
  if ctx and ctx.session_id then extra[#extra + 1] = "session=" .. ctx.session_id end
  start("reopen", extra)
end

rex.action{
  name = "revive_reopen_closed",
  title = "Reopen a Closed Chat…",
  description = "Lists the chats whose tab was closed or whose agent quit, newest first, and reopens one in a new tab.",
  category = "rex-revive",
  keywords = "revive reopen closed chat tab undo history resume claude codex pi",
  run = function(ctx)
    local chats = run_revive("closed")
    if not chats or #chats == 0 then return end
    local rows = {}
    for _, chat in ipairs(chats) do rows[#rows + 1] = row(chat) end
    local key = pick{ title = "Reopen a closed chat", placeholder = "Filter closed chats", items = rows }
    if type(key) == "string" then reopen(ctx, { "key=" .. key }) end
  end,
}

rex.action{
  name = "revive_reopen_last",
  title = "Reopen the Last Closed Chat",
  description = "Reopens the chat closed most recently in a new tab. Press it again for the one before.",
  category = "rex-revive",
  keywords = "revive reopen last closed chat tab undo resume",
  run = function(ctx) reopen(ctx) end,
}

rex.action{
  name = "revive_preview",
  title = "Preview What a Restart Brings Back…",
  description = "Lists each tab a restart would bring back and what it would type there. Pick one to show it.",
  category = "rex-revive",
  keywords = "revive preview restart restore what check chats programs",
  run = function()
    local items = run_revive("preview")
    if not items or #items == 0 then return end
    local rows, by_key = {}, {}
    for _, item in ipairs(items) do
      local r = row(item)
      if item.kind == "agent" then
        r.subtitle = "runs " .. item.typed .. " · " .. tostring(item.where)
      elseif item.note then
        r.subtitle = "chat not known: typed, not run · " .. item.typed .. " · " .. tostring(item.where)
      end
      rows[#rows + 1] = r
      by_key[item.key] = item
    end
    local key = pick{ title = "A restart now brings back", placeholder = "Filter · ↩ shows the tab", items = rows }
    local item = type(key) == "string" and by_key[key]
    if item then start("focus", { "session=" .. item.session_id, "block=" .. item.block_id }) end
  end,
}

rex.action{
  name = "revive_reopen_earlier",
  title = "Reopen Chats from an Earlier Save…",
  description = "Lists earlier saves, kept every half hour, then the chats of one that aren't open, and reopens the ones you tick.",
  category = "rex-revive",
  keywords = "revive history earlier save layout yesterday restore reopen chats",
  run = function(ctx)
    local saves = run_revive("history")
    if not saves or #saves == 0 then return end
    local rows, by_id = {}, {}
    for _, s in ipairs(saves) do
      rows[#rows + 1] = { id = s.id, icon = "clock", title = s.title, detail = s.ago,
                          subtitle = s.chats .. " not open now · saved: " .. s.summary }
      by_id[s.id] = s
    end
    local id = pick{ title = "Reopen chats from an earlier save", placeholder = "Filter saves", items = rows }
    if type(id) ~= "string" then return end
    local chats = run_revive("choices", { "from=" .. id })
    if not chats or #chats == 0 then return end
    local keys = choose(chats, "Reopen chats from " .. by_id[id].title)
    if not keys or #keys == 0 then return end
    reopen(ctx, { "from=" .. id, "only=" .. table.concat(keys, ",") })
  end,
}

-- Rex has no default for this key. Bound only when nothing before require("rex_revive")
-- in init.lua binds it. To free it, put rex.unbind("shift+cmd+t", "revive_reopen_last") after.
if #rex.bindings({ key = REOPEN_KEY }) == 0 then rex.bind(REOPEN_KEY, "revive_reopen_last") end

rex.action{
  name = "revive_settings",
  title = "Choose What Happens After a Restart…",
  description = "Ask which chats to reopen when the Rex server restarts, or reopen them all.",
  category = "rex-revive",
  keywords = "revive settings restart ask question reopen chats",
  run = function()
    local ask = (run_revive("settings") or {}).ask ~= false
    local function now(on) return on and "Now" or nil end
    local choice = pick{ title = "After Rex restarts", items = {
      { id = "ask", title = "Ask which chats to reopen", subtitle = "Recent chats ticked; ⌘↩ reopens",
        icon = "gear", detail = now(ask) },
      { id = "all", title = "Reopen every chat without asking", subtitle = "A notification says how many",
        icon = "gear", detail = now(not ask) },
    } }
    if choice == nil then return end
    run_revive("settings", { "ask=" .. tostring(choice == "ask") })
  end,
}
