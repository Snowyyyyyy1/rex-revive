--[[
[INPUT]: depends on rex.action, rex.exec, rex.ui.pick, rex.json from the Rex config Lua API;
         runs revive.lua through the rex command
[OUTPUT]: command palette actions revive_choose (asks with rex.ui.pick), revive_restore, revive_save,
          revive_settings (asks with rex.ui.pick whether to ask after a restart).
          The watcher also runs revive_choose with args.chats after a restart, to ask in the Rex app.
[POS]: the Rex config side of rex-revive. install.sh copies it to ~/.config/rex/rex_revive.lua and
       fills in @REX@ and @SCRIPT@; init.lua loads it with require("rex_revive"). It only starts
       revive.lua runs and asks questions; revive.lua does the work.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local REX = "@REX@"
local SCRIPT = "@SCRIPT@"
local HOME = os.getenv("HOME") or ""
local ICONS = { claude = "code", codex = "code", pi = "terminal" }

local function command(mode, extra)
  local argv = { REX, "--autostart=false", "do", SCRIPT, "mode=" .. mode, "palette=true" }
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

-- Ask which chats to reopen, all ticked. chats: { key, agent, session, cwd, where,
-- and from lib/titles: title, ago }. A row reads the chat's title, else its folder.
-- Returns the chosen keys, or nil and why not (cancelled, timeout, busy, ...).
-- rex.ui.pick must run in the action's own body: no pcall around this.
local function choose(chats, title, timeout)
  if not (rex.ui and rex.ui.pick) then error("rex-revive: this Rex has no rex.ui; update Rex", 0) end
  local items = {}
  for _, c in ipairs(chats) do
    local folder = short(c.cwd)
    items[#items + 1] = {
      id = c.key, icon = ICONS[c.agent], selected = true,
      title = c.title or (folder:match("([^/]+)/*$") or folder),
      subtitle = c.agent .. " · " .. folder .. " · " .. c.where,
      detail = c.ago or tostring(c.session):sub(1, 8),
    }
  end
  -- In a multiple pick Cmd+Return answers (Rex docs, Custom UI), which is easy to miss.
  local keys, status, err = rex.ui.pick{ title = title, timeout = timeout,
                                         placeholder = "Filter chats · ⌘↩ reopens the ticked ones",
                                         items = items, multiple = true, confirm = "Reopen" }
  if status == "failed" then error("rex-revive: " .. tostring(err), 0) end
  return type(keys) == "table" and keys or nil, status
end

-- From the palette: ask, then start a restore of the chosen chats.
-- From the watcher after a restart (args.chats set): ask, and answer with the
-- chosen keys. A closed question answers with no keys, and the watcher then
-- reopens every chat: an app can close a question that nobody saw.
rex.action{
  name = "revive_choose",
  title = "Choose Chats to Reopen…",
  description = "Lists the saved chats that aren't open, all ticked, and reopens the ones you keep ticked.",
  category = "rex-revive",
  keywords = "revive restore resume reopen choose pick chats claude codex pi",
  args = { chats = "array?", timeout = "number?" },
  run = function(_, a)
    if a.chats then
      local keys, status = choose(a.chats, "Rex restarted · Reopen chats", a.timeout)
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

rex.action{
  name = "revive_settings",
  title = "Choose What Happens After a Restart…",
  description = "Ask which chats to reopen when the Rex server restarts, or reopen them all.",
  category = "rex-revive",
  keywords = "revive settings restart ask question reopen chats",
  run = function()
    local ask = (run_revive("settings") or {}).ask ~= false
    local function now(on) return on and "Now" or nil end
    local choice = rex.ui.pick{ title = "After Rex restarts", items = {
      { id = "ask", title = "Ask which chats to reopen", subtitle = "Every saved chat ticked; ⌘↩ reopens",
        icon = "gear", detail = now(ask) },
      { id = "all", title = "Reopen every chat without asking", subtitle = "A notification says how many",
        icon = "gear", detail = now(not ask) },
    } }
    if choice == nil then return end
    run_revive("settings", { "ask=" .. tostring(choice == "ask") })
  end,
}
