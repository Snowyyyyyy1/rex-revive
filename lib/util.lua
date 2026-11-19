--[[
[INPUT]: depends on rex.exec and rex.json from the Rex Lua API; on io and os from Lua 5.1
[OUTPUT]: exports util: files and JSON, directory listing, command output, shell quoting, times,
          the state directory, notifications, logging
[POS]: the base layer of lib/. Every other module calls it. Its only knowledge of rex-revive
       is where the state lives and the notification title.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = {}

---------------------------------------------------------------------------
-- Values

function util.list(t) return type(t) == "table" and t or {} end

function util.basename(path)
  return (tostring(path or ""):match("([^/]+)/*$")) or ""
end

function util.words(text)
  local out = {}
  for word in tostring(text or ""):gmatch("%S+") do out[#out + 1] = word end
  return out
end

function util.lines(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

-- A time as UTC ISO 8601, which sorts as text. Now, when t is nil.
function util.iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
function util.now_iso() return util.iso(os.time()) end

-- A timestamped line on stdout, and appended to util.log_file when a run sets
-- it: a run started from the command palette has no stdout anyone reads.
util.log_file = nil
function util.log(message)
  local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. message
  print(line)
  if util.log_file then
    local f = io.open(util.log_file, "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end
end

---------------------------------------------------------------------------
-- Commands

-- The output of a command, or "" when it couldn't start. No shell reads argv.
function util.stdout(argv, opts)
  local r = rex.exec(argv, opts)
  return r and r.stdout or "", r
end

-- One word for a POSIX shell. Plain words stay as they are.
function util.quote(word)
  word = tostring(word)
  if word:match("^[%w@%%+=:,%./_%-]+$") then return word end
  return "'" .. word:gsub("'", "'\\''") .. "'"
end

function util.join(argv)
  local out = {}
  for i, word in ipairs(argv) do out[i] = util.quote(word) end
  return table.concat(out, " ")
end

---------------------------------------------------------------------------
-- Files

function util.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- Write through a temporary file, so a reader never sees half a file.
function util.write_file(path, data)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  local wrote, werr = f:write(data)
  local closed, cerr = f:close()
  if not (wrote and closed) then
    os.remove(tmp)
    return nil, werr or cerr
  end
  return os.rename(tmp, path)
end

-- A JSON file's value, or nil when it is missing, half written, or not JSON.
function util.read_json(path)
  local text = util.read_file(path)
  if not text then return nil end
  local ok, value = pcall(rex.json.decode, text)
  if ok then return value end
end

function util.write_json(path, value)
  return util.write_file(path, rex.json.encode(value, { indent = true }) .. "\n")
end

function util.is_dir(path)
  local _, r = util.stdout({ "test", "-d", path })
  return r ~= nil and r.ok
end

function util.mkdirs(...) rex.exec({ "mkdir", "-p", ... }) end

-- Full paths of the entries in dir whose names end with suffix.
function util.list_dir(dir, suffix)
  local out = {}
  local text, r = util.stdout({ "ls", "-1", dir })
  if not (r and r.ok) then return out end
  for _, name in ipairs(util.lines(text)) do
    if not suffix or name:sub(-#suffix) == suffix then out[#out + 1] = dir .. "/" .. name end
  end
  return out
end

---------------------------------------------------------------------------
-- Where things are

function util.home() return os.getenv("HOME") or "" end

util.IS_MAC = util.stdout({ "uname", "-s" }):match("^Darwin") ~= nil

-- Saves and state: state_dir=DIR, else the system's place for app state.
function util.state_dir(args)
  if args and args.state_dir then return args.state_dir end
  if util.IS_MAC then return util.home() .. "/Library/Application Support/rex-revive" end
  return (os.getenv("XDG_STATE_HOME") or (util.home() .. "/.local/state")) .. "/rex-revive"
end

function util.notify(message)
  if util.IS_MAC then
    rex.exec({ "osascript", "-e", "on run argv", "-e",
               'display notification (item 1 of argv) with title "Rex"', "-e", "end run", message })
  else
    rex.exec({ "notify-send", "Rex", message })
  end
end

return util
