--[[
[INPUT]: depends on lib/util for running ps and lsof
[OUTPUT]: exports proc: names(p), parse_etime, parse_ps, parse_lsof (pure);
          info(pids, file_pids) -> { ps, files, now }; held(paths) -> open-file set; argv(pid, info)
[POS]: the only reader of OS process state in lib/. Rex's own process method lacks start times,
       full command lines, and open files; this module fills those three gaps.
[PROTOCOL]: Update this header on change, then check CLAUDE.md
]]

local util = require("util")

local proc = {}

-- The names a process goes by, as a set, from Rex's description of it:
-- argv0 (pi shows "pi" while it runs as node), the script an interpreter
-- runs, the path it was started through, and the executable's name (a
-- version number for Claude Code's binary). Login shells' "-" is dropped.
function proc.names(p)
  local out = {}
  -- Walk the field names: any field of p may be missing.
  for _, field in ipairs({ "argv0", "script", "invoked_path", "name" }) do
    local name = util.basename(p[field]):gsub("^%-", ""):gsub("%.[cm]?js$", "")
    if name ~= "" then out[name] = true end
  end
  return out
end

-- ps prints elapsed time as [[dd-]hh:]mm:ss.
function proc.parse_etime(text)
  local days, rest = tostring(text or ""):match("^(%d+)%-(.+)$")
  if not days then days, rest = "0", tostring(text or "") end
  local seconds = 0
  for n in rest:gmatch("%d+") do seconds = seconds * 60 + tonumber(n) end
  return tonumber(days) * 86400 + seconds
end

-- `ps -o pid=,etime=,args=` -> { [pid] = { age = seconds, args = "command line" } }
function proc.parse_ps(text)
  local out = {}
  for _, line in ipairs(util.lines(text)) do
    local pid, etime, args = line:match("^%s*(%d+)%s+(%S+)%s*(.*)$")
    if pid then out[tonumber(pid)] = { age = proc.parse_etime(etime), args = args } end
  end
  return out
end

-- `lsof -Fpn`: "p<pid>" starts a process, "n<path>" names one of its open files.
function proc.parse_lsof(text)
  local out, pid = {}, nil
  for _, line in ipairs(util.lines(text)) do
    local kind, rest = line:sub(1, 1), line:sub(2)
    if kind == "p" then
      pid = tonumber(rest)
      out[pid] = out[pid] or {}
    elseif kind == "n" and pid then
      table.insert(out[pid], rest)
    end
  end
  return out
end

local function csv(pids)
  local seen, out = {}, {}
  for _, pid in ipairs(pids) do
    if not seen[pid] then seen[pid] = true; out[#out + 1] = tostring(pid) end
  end
  return table.concat(out, ",")
end

-- Ages and command lines of pids, and the open files of file_pids, read once
-- per save. lsof is the costly part, so only the processes that need it pay.
-- An exited process is simply missing from the result.
function proc.info(pids, file_pids)
  local info = { ps = {}, files = {}, now = os.time() }
  if #pids > 0 then
    info.ps = proc.parse_ps(util.stdout({ "ps", "-o", "pid=,etime=,args=", "-p", csv(pids) }))
  end
  if file_pids and #file_pids > 0 then
    info.files = proc.parse_lsof(util.stdout({ "lsof", "-nP", "-w", "-Fpn", "-p", csv(file_pids) }))
  end
  return info
end

-- Which of these files some process holds open now: { [path] = true }.
function proc.held(paths)
  local held = {}
  if #paths == 0 then return held end
  local argv = { "lsof", "-nP", "-w", "-Fn", "--" }
  for _, path in ipairs(paths) do argv[#argv + 1] = path end
  for _, line in ipairs(util.lines(util.stdout(argv))) do
    if line:sub(1, 1) == "n" then held[line:sub(2)] = true end
  end
  return held
end

-- A process's command line as words. Linux keeps the exact words in /proc;
-- macOS only gives ps's text, split at spaces.
function proc.argv(pid, info)
  if not util.IS_MAC then
    local raw = util.read_file("/proc/" .. pid .. "/cmdline")
    if raw and #raw > 0 then
      local out = {}
      for word in raw:gmatch("([^%z]*)%z") do out[#out + 1] = word end
      if #out > 0 then return out end
    end
  end
  return util.words(((info.ps or {})[pid] or {}).args)
end

return proc
