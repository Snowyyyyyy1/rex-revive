--[[
[INPUT]: depends on rex.action, rex.exec, rex.ui.pick, rex.json from the Rex config Lua API;
         runs revive.lua through the rex command
[OUTPUT]: command palette actions revive_choose (asks with rex.ui.pick), revive_restore, revive_save
[POS]: the Rex config side of rex-revive. install.sh copies it to ~/.config/rex/rex_revive.lua and
       fills in @REX@ and @SCRIPT@; init.lua loads it with require("rex_revive"). It only starts
       revive.lua runs and asks questions; revive.lua does the work.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local REX = "@REX@"
local SCRIPT = "@SCRIPT@"
local HOME = os.getenv("HOME") or ""
local ICONS = { claude = "code", codex = "code", pi = "terminal" }

-- Start a revive.lua run in the background; it reports with a notification.
local function start(mode, extra)
  local argv = { REX, "--autostart=false", "do", SCRIPT, "mode=" .. mode, "palette=true" }
  for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
  local handle, err = rex.exec.start(argv, { detach = true })
  if not handle then error("rex-revive: " .. tostring(err), 0) end
end

local function short(path)
  path = tostring(path or "")
  if HOME ~= "" and path:sub(1, #HOME) == HOME then return "~" .. path:sub(#HOME + 1) end
  return path
end

rex.action{
  name = "revive_choose",
  title = "Choose Chats to Reopen…",
  category = "rex-revive",
  keywords = "revive restore resume reopen choose pick chats claude codex pi",
  run = function()
    if not (rex.ui and rex.ui.pick) then error("rex-revive: this Rex has no rex.ui; update Rex", 0) end
    local r = rex.exec({ REX, "--autostart=false", "do", SCRIPT, "mode=choices", "palette=true" },
                       { timeout = 60 })
    if not (r and r.ok) then error("rex-revive: " .. tostring(r and r.stderr or "couldn't run rex"), 0) end
    -- mode=choices prints its JSON last, after any log lines.
    local ok, chats = pcall(rex.json.decode, r.stdout:match("([^\n]+)\n*$") or "[]")
    if not ok or type(chats) ~= "table" or #chats == 0 then return end
    local items = {}
    for _, c in ipairs(chats) do
      local folder = short(c.cwd)
      items[#items + 1] = {
        id = c.key, icon = ICONS[c.agent], selected = true,
        title = c.agent .. " · " .. (folder:match("([^/]+)/*$") or folder),
        subtitle = c.where .. " · " .. folder,
        detail = tostring(c.session):sub(1, 8),
      }
    end
    local keys = rex.ui.pick{ title = "Reopen chats", placeholder = "Filter chats",
                              items = items, multiple = true, confirm = "Reopen" }
    if type(keys) ~= "table" or #keys == 0 then return end
    start("restore", { "only=" .. table.concat(keys, ",") })
  end,
}

rex.action{
  name = "revive_restore",
  title = "Reopen Chats and Programs in Their Tabs",
  category = "rex-revive",
  keywords = "revive restore resume reopen chats programs claude codex pi",
  run = function() start("restore") end,
}

rex.action{
  name = "revive_save",
  title = "Save Open Chats and Programs Now",
  category = "rex-revive",
  keywords = "revive save snapshot chats programs",
  run = function() start("save") end,
}
