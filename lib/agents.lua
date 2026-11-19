--[[
[INPUT]: depends on lib/util for paths and files; on lib/proc for command lines, ages, and held files
[OUTPUT]: exports agents: REGISTRY, ORDER, key(agent, session), is_uuid(s), valid(agent, id), match(p), needs_files(p),
          pid_record(...),
          keep(argv, spec), identify(p, info, opts) -> chat or nil, command(chat) -> argv,
          running(paths, opts) -> set
[POS]: the only place that knows coding agents. snapshot.lua asks it what a process is;
       restore.lua asks it how to resume a chat and which chats already run.
       A new agent is one more REGISTRY entry; when the agent can't say which session it is on,
       also a record writer in integrations/ (extension, plugin, or hook).
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = require("util")
local proc = require("proc")

local agents = {}

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
local START_SLACK = 10  -- seconds a chat may take between starting and recording itself

local function is_uuid(s) return type(s) == "string" and s:match("^" .. UUID .. "$") ~= nil end
agents.is_uuid = is_uuid

-- A chat's identity, the same in saves, plans, and the running set.
function agents.key(agent, session) return agent .. ":" .. session end

---------------------------------------------------------------------------
-- The agents
--
-- match     names Rex shows for the process (see agents.names)
-- valid     what a session ID looks like (default: a UUID); IDs end up in typed commands
-- records   folder under HOME of {"pid","sessionId","startedAt",...} files, one per pid:
--           the agent's own (claude), or written by rex-revive's extension, plugin, or hook
-- record_argv  the record keeps the options, because the agent hides them from ps
-- held      the session from a file the process holds open
-- from_argv the session from the command line
-- options   options kept on resume: values take a word, switches don't
-- resume    the command that reopens a session

local function after(argv, flags, valid)
  valid = valid or is_uuid
  for i = 1, #argv - 1 do
    if flags[argv[i]] and valid(argv[i + 1]) then return argv[i + 1] end
  end
  for _, a in ipairs(argv) do
    local flag, value = a:match("^(%-%-[%w%-]+)=(.+)$")
    if flag and flags[flag] and valid(value) then return value end
  end
end

-- An amp thread: T-<uuid>.
local function is_thread(s) return type(s) == "string" and s:match("^T%-" .. UUID .. "$") ~= nil end

-- A held rule: the session from an open file under HOME .. dir whose path matches pattern.
local function held_under(dir, pattern)
  return function(files, home)
    local prefix = home .. dir
    for _, f in ipairs(util.list(files)) do
      if f:sub(1, #prefix) == prefix then
        local id = f:match(pattern)
        if id then return id, f end
      end
    end
  end
end

local function set(...)
  local out = {}
  for _, word in ipairs({ ... }) do out[word] = true end
  return out
end

agents.REGISTRY = {
  claude = {
    match = function(names, p) return names.claude or tostring(p.script or ""):find("/claude-code/", 1, true) end,
    records = "/.claude/sessions",
    from_argv = function(argv) return after(argv, set("--resume", "-r", "--session-id")) end,
    options = {
      values = set("--model", "--permission-mode", "--add-dir", "--settings", "--agent"),
      switches = set("--dangerously-skip-permissions"),
    },
    resume = function(exe, options, id) return { exe, options, "--resume", id } end,
  },
  codex = {
    match = function(names) return names.codex end,
    held = held_under("/.codex/sessions/", "rollout%-.*%-(" .. UUID .. ")%.jsonl$"),
    from_argv = function(argv) return after(argv, set("resume")) end,
    options = {
      values = set("-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval",
                   "-c", "--config", "--add-dir"),
      switches = set("--dangerously-bypass-approvals-and-sandbox", "--yolo", "--search"),
    },
    resume = function(exe, options, id) return { exe, "resume", options, id } end,
  },
  pi = {
    match = function(names) return names.pi end,
    records = "/.pi/agent/rex-revive",
    record_argv = true,
    from_argv = function(argv) return after(argv, set("--session")) end,
    options = {
      values = set("--model", "--provider", "--thinking", "--session-dir"),
      switches = {},
    },
    resume = function(exe, options, id) return { exe, options, "--session", id } end,
  },
  gemini = {
    -- node runs it: Rex shows its script, bundle/gemini.js, or the gemini link.
    match = function(names) return names.gemini end,
    records = "/.gemini/rex-revive",  -- integrations/agent-hook.sh, a SessionStart hook
    from_argv = function(argv) return after(argv, set("--resume", "-r", "--session-id")) end,
    options = {
      values = set("-m", "--model", "--approval-mode", "--include-directories", "--policy", "-e", "--extensions"),
      switches = set("-y", "--yolo", "-s", "--sandbox"),
    },
    resume = function(exe, options, id) return { exe, options, "--resume", id } end,
  },
  droid = {
    match = function(names) return names.droid end,
    records = "/.factory/rex-revive",  -- integrations/agent-hook.sh, a SessionStart hook
    from_argv = function(argv) return after(argv, set("--resume", "-r")) end,
    options = { values = set("--settings"), switches = {} },
    resume = function(exe, options, id) return { exe, options, "--resume", id } end,
  },
  amp = {
    match = function(names) return names.amp end,
    valid = is_thread,
    records = "/.local/share/amp/rex-revive",  -- integrations/amp-rex-revive.ts, a plugin
    -- amp threads continue [options] T-<uuid> or a thread URL
    from_argv = function(argv)
      local continuing = false
      for _, a in ipairs(argv) do
        local id = a:match("(T%-" .. UUID .. ")$")
        if a == "continue" then
          continuing = true
        elseif continuing and id then
          return id
        end
      end
    end,
    options = {
      values = set("-m", "--mode", "--settings-file", "--visibility", "--mcp-config"),
      switches = {},
    },
    resume = function(exe, options, id) return { exe, "threads", "continue", options, id } end,
  },
  ["cursor-agent"] = {
    -- node runs it, as its cursor-agent or agent link, with .../cursor-agent/versions/<v>/index.js.
    match = function(names, p)
      return names["cursor-agent"] or names.agent or tostring(p.script or ""):find("/cursor-agent/", 1, true)
    end,
    -- ~/.cursor/chats/<md5 of its folder>/<id>/store.db, open from the chat's first message on
    held = held_under("/.cursor/chats/", "/(" .. UUID .. ")/store%.db$"),
    from_argv = function(argv) return after(argv, set("--resume")) end,
    options = {
      values = set("--model", "--mode", "--sandbox", "--workspace", "--add-dir", "--plugin-dir"),
      switches = set("-f", "--force", "--yolo", "--plan", "--auto-review", "--approve-mcps", "--trust"),
    },
    resume = function(exe, options, id) return { exe, options, "--resume", id } end,
  },
}
agents.ORDER = { "claude", "codex", "pi", "gemini", "droid", "amp", "cursor-agent" }

-- Whether id can be a session of this agent.
function agents.valid(agent, id)
  local spec = agents.REGISTRY[agent]
  return spec ~= nil and (spec.valid or is_uuid)(id)
end

---------------------------------------------------------------------------
-- Recognizing an agent

function agents.match(p)
  local names = proc.names(p)
  for _, name in ipairs(agents.ORDER) do
    if agents.REGISTRY[name].match(names, p) then return name end
  end
end

-- Whether identify needs this process's open files (only agents with a held rule).
function agents.needs_files(p)
  local name = agents.match(p)
  return name ~= nil and agents.REGISTRY[name].held ~= nil
end

-- A pid record, if it belongs to this very process: a pid can be reused, so
-- the record's startedAt (ms) must match the process's start. Claude Code's
-- procStart text is ignored; it can be off by the time zone. valid checks the
-- session ID (default: a UUID).
function agents.pid_record(path, pid, age, now, reader, valid)
  if not (pid and age and now) then return nil end
  local record = (reader or util.read_json)(path)
  if type(record) ~= "table" or tonumber(record.pid) ~= tonumber(pid) then return nil end
  local started = tonumber(record.startedAt)
  if not (valid or is_uuid)(record.sessionId) or not started then
    return nil
  end
  if math.abs(started / 1000 - (now - age)) > START_SLACK then return nil end
  return record
end

-- The options worth keeping on resume, from a command line (argv[1] is the program).
function agents.keep(argv, spec)
  local out, i = {}, 2
  while i <= #argv do
    local a = argv[i]
    local flag = a:match("^(%-%-?[%w%-]+)=") or a
    if spec.switches[a] then
      out[#out + 1] = a
    elseif spec.values[flag] then
      out[#out + 1] = a
      if flag == a and argv[i + 1] then
        out[#out + 1] = argv[i + 1]
        i = i + 1
      end
    end
    i = i + 1
  end
  return out
end

-- What chat this agent process is on.
--   p     a process as Rex's terminal process method describes it
--   info  proc.info for the pids involved
--   opts  { home = HOME, reader = read a JSON file, files = extra open files }
-- Returns nil when p is no known agent, else
--   { agent, session (nil when not certain), options, exe, file }
function agents.identify(p, info, opts)
  opts = opts or {}
  local name = agents.match(p)
  if not name then return nil end
  local spec, home = agents.REGISTRY[name], opts.home or util.home()
  local argv = proc.argv(p.pid, info)
  local ps = info.ps[p.pid]
  local record = spec.records and ps
    and agents.pid_record(home .. spec.records .. "/" .. p.pid .. ".json", p.pid, ps.age, info.now, opts.reader,
                          spec.valid)
  if record and spec.record_argv then
    argv = { argv[1] or name }
    for _, word in ipairs(util.list(record.argv)) do
      if type(word) == "string" then argv[#argv + 1] = word end
    end
  end
  local session, file = record and record.sessionId, nil
  if not session and spec.held then
    local files = {}
    for _, f in ipairs(util.list(info.files[p.pid])) do files[#files + 1] = f end
    for _, f in ipairs(util.list(opts.files)) do files[#files + 1] = f end
    session, file = spec.held(files, home)
  end
  session = session or spec.from_argv(argv)
  -- Retype the program the way it was started, when Rex knows that path.
  local exe = name
  if util.basename(p.invoked_path) == name then exe = p.invoked_path end
  return { agent = name, session = session, options = agents.keep(argv, spec.options), exe = exe, file = file }
end

-- The command that reopens a saved chat, as words.
function agents.command(chat)
  local spec = agents.REGISTRY[chat.agent]
  local out = {}
  for _, part in ipairs(spec.resume(chat.exe or chat.agent, util.list(chat.options), chat.session)) do
    if type(part) == "table" then
      for _, word in ipairs(part) do out[#out + 1] = word end
    else
      out[#out + 1] = part
    end
  end
  return out
end

-- Chats running anywhere on this machine, in Rex or not: { ["agent:session"] = true }.
-- The agents with pid records say so there; Codex and Cursor Agent hold their
-- session files (paths: the saved files to check).
function agents.running(paths, opts)
  opts = opts or {}
  local home, found, pids = opts.home or util.home(), {}, {}
  for _, name in ipairs(agents.ORDER) do
    local dir = agents.REGISTRY[name].records
    if dir then
      for _, path in ipairs(util.list_dir(home .. dir, ".json")) do
        -- Rex's string.match returns no value at all on a miss, and tonumber()
        -- with no argument raises: the extra parentheses make it a nil.
        local pid = tonumber((util.basename(path):match("^(%d+)%.json$")))
        if pid then
          found[#found + 1] = { name, pid, path, agents.REGISTRY[name].valid }
          pids[#pids + 1] = pid
        end
      end
    end
  end
  local out, info = {}, proc.info(pids)
  for _, entry in ipairs(found) do
    local name, pid, path, valid = entry[1], entry[2], entry[3], entry[4]
    local ps = info.ps[pid]
    local record = ps and agents.pid_record(path, pid, ps.age, info.now, opts.reader, valid)
    if record then out[agents.key(name, record.sessionId)] = true end
  end
  local list = {}
  for path in pairs(paths or {}) do list[#list + 1] = path end
  for path in pairs(proc.held(list)) do
    if paths[path] then out[paths[path]] = true end
  end
  return out
end

return agents
