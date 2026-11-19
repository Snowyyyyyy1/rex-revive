--[[
[INPUT]: depends on lib/util (command output, directory listing, home, JSON files); lib/agents (valid); rex.json;
         find, stat, and for Codex sqlite3, on the PATH
[OUTPUT]: exports titles: label(chats, opts) fills in each chat's title, idle, and ago;
          clip(text, n) and ago(seconds), the formatting both use
[POS]: the only module that reads the agents' conversation files. It runs only when a person is
       asked which chats to reopen, never on a save: Claude's files reach hundreds of megabytes.
       A title it can't read is left out; it never stops a restore.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = require("util")
local agents = require("agents")

local titles = {}

local MAX_CHARS = 60     -- longer titles are cut, with an ellipsis
local FIRST_LINES = 400  -- how far into a conversation file to look for its first prompt

-- One line of at most n characters (UTF-8 aware), or nil when there is no text.
function titles.clip(text, n)
  if type(text) ~= "string" then return nil end
  text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if text == "" then return nil end
  local out = {}
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if #out == n then return table.concat(out) .. "…" end
    out[#out + 1] = char
  end
  return text
end

-- How long ago, in a few characters: "now", "5m", "3h", "2d", "6w".
function titles.ago(seconds)
  if not seconds then return nil end
  if seconds < 60 then return "now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  if seconds < 14 * 86400 then return math.floor(seconds / 86400) .. "d" end
  return math.floor(seconds / (7 * 86400)) .. "w"
end

-- What a person typed, from a message's content: a string, or a list whose
-- first part is text ({type = "text", text} or Gemini's {text}). Tool results
-- and wrappers such as <command-name> are not.
local function typed(content)
  if type(content) == "table" then
    local part = content[1]
    content = type(part) == "table" and (part.type == "text" or part.type == nil) and part.text
  end
  if type(content) ~= "string" or content:match("^%s*<") then return nil end
  -- A prompt is often Markdown: keep the words, drop the marks.
  content = content:gsub("%[([^%]]*)%]%([^)]*%)", "%1"):gsub("[*`]", ""):gsub("^%s*[#>]+", "")
  return titles.clip(content, MAX_CHARS)
end

-- The first prompt in a JSON-lines file. pick(entry) returns the message
-- content of an entry a person wrote, else nil. marker skips other lines
-- without decoding them, as some lines are megabytes long.
local function first_prompt(path, marker, pick)
  local f = io.open(path, "r")
  if not f then return nil end
  local n, text = 0, nil
  for line in f:lines() do
    n = n + 1
    if n > FIRST_LINES then break end
    if line:find(marker, 1, true) then
      local ok, entry = pcall(rex.json.decode, line)
      text = ok and type(entry) == "table" and typed(pick(entry))
      if text then break end
    end
  end
  f:close()
  return text
end

local function find(dir, name)
  return util.stdout({ "find", dir, "-maxdepth", "2", "-name", name }):match("[^\n]+")
end

local function modified(path)
  local argv = util.IS_MAC and { "stat", "-f", "%m", path } or { "stat", "-c", "%Y", path }
  return tonumber((util.stdout(argv):match("%d+")))
end

-- Each reader returns the title (or nil) and when the chat was last active.
local READERS = {}

-- The last line of a JSON-lines text that starts {"type":"<kind>", decoded.
local function last_entry(text, kind)
  local marker, at, from = '\n{"type":"' .. kind .. '"', nil, 1
  while true do
    local i = text:find(marker, from, true)
    if not i then break end
    at, from = i, i + 1
  end
  local ok, entry = pcall(rex.json.decode, at and text:match("^\n([^\n]*)", at) or "")
  return ok and type(entry) == "table" and entry or {}
end

-- The end of a file, at most n bytes, starting on a line of its own.
local function tail(path, n)
  local f = io.open(path, "rb")
  if not f then return "" end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - n))
  local text = f:read("*a") or ""
  f:close()
  return "\n" .. text
end

-- ~/.claude/projects/<folder>/<id>.jsonl. A rename (custom-title) wins over
-- Claude's own title (ai-title), and the last of each counts. Claude writes
-- them again as a chat goes on: in 376 real chats, the last rename was within
-- 0.6 MB of the end, so reading the last 4 MB of a file of up to 500 MB does.
function READERS.claude(id, home)
  local path = find(home .. "/.claude/projects", id .. ".jsonl")
  if not path then return nil end
  local text = tail(path, 4 * 1024 * 1024)
  local title = titles.clip(last_entry(text, "custom-title").customTitle, MAX_CHARS)
    or titles.clip(last_entry(text, "ai-title").aiTitle, MAX_CHARS)
    or first_prompt(path, '"type":"user"', function(e)
      return e.type == "user" and not e.isMeta and e.message and e.message.content
    end)
  return title, modified(path)
end

-- ~/.codex/state_N.sqlite, table threads: the name a person gave the thread,
-- else its first prompt. Without sqlite3 there is no Codex title.
function READERS.codex(id, home)
  local db, newest = nil, -1
  for _, path in ipairs(util.list_dir(home .. "/.codex", ".sqlite")) do
    local version = tonumber((util.basename(path):match("^state_(%d+)%.sqlite$")))  -- see agents.running
    if version and version > newest then db, newest = path, version end
  end
  if not db then return nil end
  local out = util.stdout({ "sqlite3", "-readonly", "-json", db,
    "select name, substr(first_user_message, 1, 400) as first, updated_at from threads where id = '" .. id .. "'" })
  local ok, rows = pcall(rex.json.decode, out)
  local row = ok and type(rows) == "table" and rows[1]
  if type(row) ~= "table" then return nil end
  local first = type(row.first) == "string" and not row.first:match("^# AGENTS%.md") and row.first
  return titles.clip(row.name, MAX_CHARS) or typed(first), tonumber(row.updated_at)
end

-- ~/.pi/agent/sessions/<folder>/<time>_<id>.jsonl. pi keeps no title.
function READERS.pi(id, home)
  local path = find(home .. "/.pi/agent/sessions", "*_" .. id .. ".jsonl")
  if not path then return nil end
  local title = first_prompt(path, '"role":"user"', function(e)
    return e.type == "message" and e.message and e.message.role == "user" and e.message.content
  end)
  return title, modified(path)
end

-- ~/.gemini/tmp/<project>/chats/session-<time>-<first 8 of id>.jsonl, whose
-- first line names the session. Gemini keeps no title: its first prompt.
function READERS.gemini(id, home)
  local out = util.stdout({ "find", home .. "/.gemini/tmp", "-maxdepth", "3", "-path", "*/chats/*",
                            "-name", "session-*-" .. id:sub(1, 8) .. "*.jsonl" })
  for path in out:gmatch("[^\n]+") do
    local f = io.open(path, "r")
    local first = f and f:read("*l")
    if f then f:close() end
    local ok, head = pcall(rex.json.decode, first or "")
    if ok and type(head) == "table" and head.sessionId == id then
      local title = first_prompt(path, '"type":"user"', function(e) return e.type == "user" and e.content end)
      return title, modified(path)
    end
  end
end

-- ~/.local/share/amp/threads/T-<uuid>.json: its title, else its first prompt.
function READERS.amp(id, home)
  local path = home .. "/.local/share/amp/threads/" .. id .. ".json"
  local thread = util.read_json(path)
  if type(thread) ~= "table" then return nil end
  local title = titles.clip(thread.title, MAX_CHARS)
  if not title then
    for _, m in ipairs(util.list(thread.messages)) do
      if type(m) == "table" and m.role == "user" then
        title = typed(m.content)
        if title then break end
      end
    end
  end
  return title, modified(path)
end

-- Fills in chat.title, chat.idle (seconds since it was last active) and
-- chat.ago ("3h") where the files tell, for the chats among items such as
-- restore.pending returns. opts.home and opts.now are for the tests.
function titles.label(chats, opts)
  opts = opts or {}
  local home, now = opts.home or util.home(), opts.now or os.time()
  for _, chat in ipairs(chats) do
    local read = READERS[chat.agent]
    if read and agents.valid(chat.agent, chat.session) then
      local ok, title, active = pcall(read, chat.session, home)
      if ok then
        chat.title = title
        chat.idle = active and now - active
        chat.ago = chat.idle and titles.ago(chat.idle)
      end
    end
  end
  return chats
end

return titles
