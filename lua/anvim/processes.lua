-- The Processes window: the processes that use the CPU, grouped by app or by
-- name, as in htop. This anvim's own processes form one row, and each Bash
-- call that runs forms a row named after its agent. A process whose parent
-- ended keeps ANVIM_PID in its environment, and forms a row of its own.
local agents = require("anvim.agents")
local keys = require("anvim.keys")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.processes")
-- ps prints comm last, so a path with spaces stays whole. top would cost
-- far more CPU than it measures.
local LIST = { "ps", "-axo", "pid=,ppid=,pcpu=,rss=,time=,comm=" }
-- The environments of the user's processes: about 2 MB and 70 ms of work.
local ENV = { "ps", "-axEww", "-o", "pid=,command=" }
local MARK = "◆"

-- Runs ps with these arguments. With a callback, it runs in the background
-- and gives the callback the output; without one, it returns the output.
-- The output is nil when ps fails, as a fork does when the system is out of
-- processes. Specs replace it, and the kill and the clock too.
---@param args string[]
---@param cb? fun(out: string?)
---@return string?
function M.ps(args, cb)
  local on_exit = cb
    and function(obj)
      vim.schedule(function()
        cb(obj.code == 0 and obj.stdout or nil)
      end)
    end
  local ok, proc = pcall(vim.system, args, { text = true }, on_exit)
  if not ok then
    if cb then
      vim.schedule(function()
        cb(nil)
      end)
    end
    return nil
  elseif not cb then
    local obj = proc:wait()
    return obj.code == 0 and obj.stdout or nil
  end
end
M.kill = vim.uv.kill
---@return number seconds
function M.clock()
  return vim.uv.hrtime() / 1e9
end
M.interval = 2000
-- Seconds between two scans of the environments.
M.scan_interval = 10

---@class anvim.Rusage
---@field footprint integer KB, the memory figure of Activity Monitor.
---@field ended number The CPU time of the ended processes that it waited for, in seconds.

-- proc_pid_rusage() of macOS, or false where it is missing.
---@type (fun(pid: integer): anvim.Rusage?)|false|nil
local reader

local function load_rusage()
  if jit.os ~= "OSX" then
    return false
  end
  local ffi = require("ffi")
  pcall(
    ffi.cdef,
    [[
    typedef struct {
      uint8_t ri_uuid[16];
      uint64_t ri_user_time, ri_system_time, ri_pkg_idle_wkups, ri_interrupt_wkups, ri_pageins, ri_wired_size,
        ri_resident_size, ri_phys_footprint, ri_proc_start_abstime, ri_proc_exit_abstime, ri_child_user_time,
        ri_child_system_time, ri_child_pkg_idle_wkups, ri_child_interrupt_wkups, ri_child_pageins,
        ri_child_elapsed_abstime, ri_diskio_bytesread, ri_diskio_byteswritten;
    } anvim_rusage_info_v2;
    typedef struct { uint32_t numer; uint32_t denom; } anvim_timebase_info;
  ]]
  )
  -- Each in its own call, as another plugin may declare one of them already.
  pcall(ffi.cdef, "int proc_pid_rusage(int pid, int flavor, void *buffer);")
  pcall(ffi.cdef, "int mach_timebase_info(void *info);")
  local info, base = ffi.new("anvim_rusage_info_v2"), ffi.new("anvim_timebase_info")
  local ok, err = pcall(ffi.C.mach_timebase_info, base)
  if not ok or err ~= 0 or base.denom == 0 then
    return false
  end
  -- The times are in Mach absolute time units.
  local unit = base.numer / base.denom / 1e9
  local function read(pid)
    if ffi.C.proc_pid_rusage(pid, 2, info) ~= 0 then
      return nil
    end
    return {
      footprint = math.floor(tonumber(info.ri_phys_footprint) / 1024),
      ended = tonumber(info.ri_child_user_time + info.ri_child_system_time) * unit,
    }
  end
  return pcall(read, vim.fn.getpid()) and read
end

-- The memory footprint and the ended CPU time of a process. It is nil for
-- the processes of other users, and where macOS's call is missing.
---@param pid integer
---@return anvim.Rusage?
function M.rusage(pid)
  if reader == nil then
    local ok, found = pcall(load_rusage)
    reader = ok and found or false
  end
  return reader and reader(pid) or nil
end

---@class anvim.Process
---@field pid integer
---@field ppid integer
---@field pcpu number
---@field rss integer KB
---@field mem integer? KB: the footprint, or the RSS where the footprint is unknown.
---@field ended number?
---@field time number The CPU time that it used, in seconds.
---@field comm string
---@field cpu number Percent of one core.

---@class anvim.ProcessGroup
---@field key string
---@field name string
---@field kind "anvim"|"bash"|"escaped"|"app"|"name"
---@field hl string? The color of anvim's mark.
---@field members integer[]
---@field cpu number
---@field mem integer

-- The Bash calls that may still run, by tool id. A call in the background
-- runs on after its result.
---@type table<string, { command: string, agent: anvim.Agent?, main: boolean }>
local calls = {}

---@type snacks.win?
local win
local timer ---@type uv.uv_timer_t?
local busy = false
-- The confirm of a signal has the focus, so leaving the window keeps it.
local asking = false
local sort = "cpu" ---@type "cpu"|"mem"
local expanded = {} ---@type table<string, true>
-- The last sample, which the next one measures the CPU time against.
local prev ---@type { at: number, procs: table<integer, anvim.Process> }?
local procs = {} ---@type table<integer, anvim.Process>
local args = {} ---@type table<integer, string>
local groups = {} ---@type anvim.ProcessGroup[]
local by_key = {} ---@type table<string, anvim.ProcessGroup>
local owner = {} ---@type table<integer, string>
-- This anvim's TUI, server, sidecar and Claude Code engines.
local core = {} ---@type table<integer, true>
-- The processes with this anvim's ANVIM_PID, and the time of that scan.
local marked = {} ---@type table<integer, true>
local scanned ---@type number?
-- The group key or the pid of each line, 1-based, and the group of each line.
local row_keys = {} ---@type table<integer, string|integer>
local row_groups = {} ---@type table<integer, string>
-- The line that draw() last put the cursor on. A cursor on another line was
-- moved by the user, onto the row that it then follows.
local placed ---@type integer?
local chosen ---@type string|integer?
local chosen_group ---@type string?
-- The processes above the TUI, such as the terminal. A signal to one of them
-- would end anvim too.
local above = {} ---@type table<integer, true>
-- The window that had the focus before the window opened.
local origin ---@type integer?

local function valid()
  return win ~= nil and win:valid()
end

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

-- "[dd-]hh:mm:ss.cc" or "mm:ss.cc".
local function seconds(time)
  local days, rest = time:match("^(%d+)%-(.+)$")
  local total = 0
  for part in (rest or time):gmatch("[^:]+") do
    total = total * 60 + (tonumber(part) or 0)
  end
  return total + (tonumber(days) or 0) * 86400
end

---@return table<integer, anvim.Process>
function M.parse(out)
  local list = {}
  for line in out:gmatch("[^\n]+") do
    local pid, ppid, pcpu, rss, time, comm = line:match("^%s*(%d+)%s+(%d+)%s+([%d.,]+)%s+(%d+)%s+(%S+)%s+(.-)%s*$")
    if pid then
      pid = tonumber(pid) --[[@as integer]]
      list[pid] = {
        pid = pid,
        ppid = tonumber(ppid),
        pcpu = tonumber((pcpu:gsub(",", "."))) or 0,
        rss = tonumber(rss),
        time = seconds(time),
        comm = comm,
      }
    end
  end
  return list
end

-- ps prints control characters as octal escapes, such as \012 for a newline.
local function parse_args(out)
  local list = {}
  for line in out:gmatch("[^\n]+") do
    local pid, text = line:match("^%s*(%d+)%s(.*)$")
    if pid then
      list[tonumber(pid)] = text:gsub("\\(0[0-3][0-7])", function(o)
        return string.char(tonumber(o, 8))
      end)
    end
  end
  return list
end

-- The command of a Bash call's shell: the word after "eval", without the
-- shell's quotes. Claude Code quotes the command in single quotes.
---@param text string
---@return string?
function M.eval_text(text)
  local i = text:find("eval '", 1, true)
  if not i then
    return nil
  end
  i = i + 5
  local out = {}
  while i <= #text do
    local c = text:sub(i, i)
    if c == "'" then
      local j = text:find("'", i + 1, true) or #text + 1
      out[#out + 1] = text:sub(i + 1, j - 1)
      i = j + 1
    elseif c == '"' then
      i = i + 1
      while i <= #text and text:sub(i, i) ~= '"' do
        local d = text:sub(i, i)
        if d == "\\" and text:sub(i + 1, i + 1):match('[\\"$`]') then
          i = i + 1
          d = text:sub(i, i)
        end
        out[#out + 1] = d
        i = i + 1
      end
      i = i + 1
    elseif c == "\\" then
      out[#out + 1] = text:sub(i + 1, i + 1)
      i = i + 2
    elseif c:match("%s") then
      break
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function first_line(text)
  return vim.trim(text:match("^%s*([^\n]*)") or "")
end

-- The row name of a Bash call's shell, after the call that runs it.
local function bash_name(command)
  local found
  for _, call in pairs(calls) do
    if call.command == command then
      found = call
      break
    end
    if not found and first_line(call.command) == first_line(command) then
      found = call
    end
  end
  local who = found and (found.agent and agents.label(found.agent) or found.main and "Claude")
  local hl = found and (found.agent and agents.group(found.agent.slot) or found.main and agents.group(0)) or "Comment"
  return ("Bash · %s%s"):format(who and who .. " · " or "", first_line(command)), hl
end

-- The outermost app bundle of the path, such as Firefox for its helpers.
local function app(comm)
  local name = ("/" .. comm):match("^.-/([^/]+)%.app/")
  if name and comm:find("/Library/Developer/CoreSimulator/Devices/", 1, true) then
    name = name .. " (Simulator)"
  end
  return name
end

-- The key of a process outside this anvim: its app, or its name.
local function key_of(p)
  local name = app(p.comm)
  if name then
    return "app:" .. name, name, "app"
  end
  name = basename(p.comm)
  return "name:" .. name, name, "name"
end

---@param list table<integer, anvim.Process>
---@return table<integer, integer[]>
local function children_of(list)
  local children = {}
  for pid, p in pairs(list) do
    children[p.ppid] = children[p.ppid] or {}
    table.insert(children[p.ppid], pid)
  end
  return children
end

-- Calls fn for each process under pid. fn returns true to skip the ones
-- under that process.
local function below(children, pid, fn)
  for _, child in ipairs(children[pid] or {}) do
    if not fn(child) then
      below(children, child, fn)
    end
  end
end

-- The pids whose environment has ANVIM_PID=<pid> as a whole word.
---@param out string
---@param pid integer
---@return table<integer, true>
function M.marked(out, pid)
  local needle, found = "ANVIM_PID=" .. pid, {}
  for line in out:gmatch("[^\n]+") do
    local from = 1
    while true do
      local i, j = line:find(needle, from, true)
      if not i then
        break
      elseif line:sub(i - 1, i - 1) == " " and line:sub(j + 1, j + 1):match("^%s?$") then
        local at = tonumber(line:match("^%s*(%d+)"))
        if at then
          found[at] = true
        end
        break
      end
      from = j + 1
    end
  end
  return found
end

-- The server's TUI. A restarted server's parent is launchd, and its TUI
-- attaches over a socket, so the UI's client info gives its pid.
local function tuis(list, server)
  local parent = list[server] and list[list[server].ppid]
  if parent and basename(parent.comm) == "nvim" then
    return { parent.pid }
  end
  local found = {}
  for _, ui in ipairs(api.nvim_list_uis()) do
    local ok, info = pcall(api.nvim_get_chan_info, ui.chan or 0)
    local pid = ok and vim.tbl_get(info, "client", "attributes", "pid")
    if tonumber(pid) and list[tonumber(pid)] then
      found[#found + 1] = tonumber(pid)
    end
  end
  return found
end

-- The server's TUI, sidecar and engines, which anvim needs to run.
local function find_core(list, children, server)
  local found = { [server] = true }
  for _, pid in ipairs(tuis(list, server)) do
    found[pid] = true
  end
  local sidecar = require("anvim.sidecar").pid()
  if sidecar then
    found[sidecar] = true
  end
  local engines = {}
  below(children, server, function(pid)
    local p = list[pid]
    if basename(p.comm) == "claude" and p.comm:find("claude-agent-sdk", 1, true) then
      engines[#engines + 1] = pid
      found[pid], found[p.ppid] = true, true
    end
  end)
  return found, engines
end

-- The pids whose command lines the rows need: this anvim's processes, to
-- find the Bash calls, and the members of the expanded groups.
local function wanted(list)
  local pids, server = {}, vim.fn.getpid()
  local seen = { [server] = true }
  below(children_of(list), server, function(pid)
    seen[pid] = true
  end)
  for pid, p in pairs(list) do
    if seen[pid] or expanded[owner[pid] or (key_of(p))] or (expanded.anvim and core[pid]) then
      pids[#pids + 1] = pid
    end
  end
  return pids
end

---@param list table<integer, anvim.Process>
---@param cmdlines table<integer, string>
---@param marks? table<integer, true> The processes with this anvim's ANVIM_PID.
---@return anvim.ProcessGroup[], table<integer, string> owner, table<integer, true> core
function M.group(list, cmdlines, marks)
  local server = vim.fn.getpid()
  local children = children_of(list)
  local found_core, engines = find_core(list, children, server)
  local found, owners = {}, {} ---@type table<string, anvim.ProcessGroup>, table<integer, string>
  local function add(pid, key, name, kind, hl)
    local g = found[key]
    if not g then
      g = { key = key, name = name, kind = kind, hl = hl, members = {}, cpu = 0, mem = 0 }
      found[key] = g
    end
    local p = list[pid]
    g.members[#g.members + 1] = pid
    g.cpu, g.mem = g.cpu + (p.cpu or p.pcpu), g.mem + (p.mem or p.rss)
    owners[pid] = key
  end
  -- The sandbox may put a wrapper between the engine and the shell.
  for _, engine in ipairs(engines) do
    below(children, engine, function(pid)
      local command = cmdlines[pid] and M.eval_text(cmdlines[pid])
      if not command or owners[pid] then
        return false
      end
      local key = "bash:" .. pid
      local name, hl = bash_name(command)
      add(pid, key, name, "bash", hl)
      below(children, pid, function(child)
        add(child, key, name, "bash", hl)
      end)
      return true
    end)
  end
  local function own(pid)
    if list[pid] and not owners[pid] then
      add(pid, "anvim", "anvim", "anvim", agents.group(0))
    end
  end
  for pid in pairs(found_core) do
    own(pid)
  end
  below(children, server, function(pid)
    own(pid)
  end)
  -- A process whose parent ends moves to launchd. Its topmost marked
  -- ancestor outside the tree is the root of its row.
  for pid in pairs(marks or {}) do
    local root = list[pid] and not owners[pid]
    local up = root and list[pid].ppid
    while root and up > 1 and list[up] do
      root = not (marks[up] and not owners[up])
      up = list[up].ppid
    end
    if root then
      local key, _, name = "escaped:" .. pid, key_of(list[pid])
      local hl = agents.group(0)
      add(pid, key, name, "escaped", hl)
      below(children, pid, function(child)
        if owners[child] then
          return true
        end
        add(child, key, name, "escaped", hl)
      end)
    end
  end
  for pid, p in pairs(list) do
    if not owners[pid] then
      add(pid, key_of(p))
    end
  end
  return vim.tbl_values(found), owners, found_core
end

local function by_sort(a, b)
  local x, y = a[sort], b[sort]
  if x ~= y then
    return x > y
  end
  return (a.name or a.pid) < (b.name or b.pid)
end

-- This anvim's rows come first, so an idle one shows without a scroll.
local RANK = { anvim = 1, bash = 2, escaped = 3 }

local function by_rank(a, b)
  local x, y = RANK[a.kind] or 4, RANK[b.kind] or 4
  if x ~= y then
    return x < y
  end
  return by_sort(a, b)
end

local function cpu_text(cpu)
  return ("%d%%"):format(math.floor(cpu + 0.5))
end

local function mem_text(kb)
  if kb < 1000 then
    return ("%dK"):format(kb)
  elseif kb < 102400 then
    return ("%dM"):format(math.floor(kb / 1024 + 0.5))
  end
  return ("%.1fG"):format(kb / 1048576)
end

local function cpu_hl(cpu)
  return cpu >= 80 and "DiagnosticError" or cpu >= 30 and "DiagnosticWarn" or nil
end

-- Cuts the text to the width in cells.
local function fit(text, width)
  text = text:gsub("%c", " ")
  if api.nvim_strwidth(text) <= width then
    return text
  end
  local n = math.min(vim.fn.strchars(text), math.max(width - 3, 0))
  while n > 0 and api.nvim_strwidth(vim.fn.strcharpart(text, 0, n)) > width - 3 do
    n = n - 1
  end
  return vim.fn.strcharpart(text, 0, n) .. "..."
end

-- This anvim's processes: its own rows, the Bash calls and the escaped ones.
local function summary()
  local count, cpu, mem, outside, ended = 0, 0, 0, 0, nil
  for _, g in ipairs(groups) do
    if g.kind == "anvim" or g.kind == "bash" or g.kind == "escaped" then
      count, cpu, mem = count + #g.members, cpu + g.cpu, mem + g.mem
      outside = outside + (g.kind == "escaped" and #g.members or 0)
      for _, pid in ipairs(g.members) do
        local p = procs[pid]
        if p.ended then
          ended = (ended or 0) + p.ended
        end
      end
    end
  end
  local parts = {
    ("This anvim: %d %s"):format(count, count == 1 and "process" or "processes"),
    cpu_text(cpu) .. " CPU",
    mem_text(mem),
  }
  if outside > 0 then
    parts[#parts + 1] = ("%d outside its tree"):format(outside)
  end
  if ended then
    parts[#parts + 1] = "ended processes used " .. require("anvim.transcript").duration(ended * 1000)
  end
  return " " .. table.concat(parts, " · ")
end

local function render(width)
  local lines, marks, rows, in_group = {}, {}, {}, {}
  local function add(line, key, hls, group)
    lines[#lines + 1] = line
    rows[#lines], in_group[#lines] = key, group
    for _, h in ipairs(hls) do
      marks[#marks + 1] = { #lines - 1, h[1], h[2], h[3] }
    end
  end
  -- A mark of two cells, then CPU and MEM of five, for 1200% and 10.0G.
  local function row(mark, cpu, mem, name, key, group, name_hl)
    local head = (mark and " " .. MARK or "  ")
    local cpu_col = #head
    local line = ("%s%5s  %5s  "):format(head, cpu_text(cpu), mem_text(mem))
    local hls = { { #line, #line + #name, name_hl } }
    if mark then
      hls[#hls + 1] = { 1, 1 + #MARK, mark }
    end
    local hl = cpu_hl(cpu)
    if hl then
      hls[#hls + 1] = { cpu_col, cpu_col + 5, hl }
    end
    add(line .. name, key, hls, group)
  end
  local total = summary()
  local label = 1 + #"This anvim"
  add(total, nil, { { 1, label, agents.group(0) }, { label, #total, "AnvimResult" } })
  local head = "    CPU    MEM  NAME"
  local active = sort == "cpu" and { 4, 7 } or { 11, 14 }
  add(head, nil, { { 0, #head, "AnvimResult" }, { active[1], active[2], "Title" } })
  table.sort(groups, by_rank)
  local name_width = width - 16
  for _, g in ipairs(groups) do
    local name = #g.members > 1 and ("%s (%d)"):format(g.name, #g.members) or g.name
    if g.kind == "escaped" then
      name = name .. " · started by this anvim"
    end
    row(g.hl, g.cpu, g.mem, fit(name, name_width), g.key, g.key)
    if expanded[g.key] then
      local members = {}
      for _, pid in ipairs(g.members) do
        members[#members + 1] = procs[pid]
      end
      table.sort(members, by_sort)
      for _, p in ipairs(members) do
        local text = fit(("  %-6d %s"):format(p.pid, args[p.pid] or p.comm), name_width)
        row(g.hl, p.cpu, p.mem or p.rss, text, p.pid, g.key, "AnvimResult")
      end
    end
  end
  return lines, marks, rows, in_group
end

local function title()
  local load = vim.uv.loadavg()
  return (" Processes · load %.2f · %d cores "):format(load, vim.uv.available_parallelism())
end

local function draw()
  if not valid() then
    return
  end
  ---@cast win snacks.win
  local buf = win.buf
  local cursor = api.nvim_win_get_cursor(win.win)[1]
  if cursor ~= placed then
    chosen, chosen_group = row_keys[cursor], row_groups[cursor]
  end
  local view = api.nvim_win_call(win.win, vim.fn.winsaveview)
  local lines, marks, rows, in_group = render(api.nvim_win_get_width(win.win))
  row_keys, row_groups = rows, in_group
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    if m[4] then
      api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
  end
  win.opts.title = title()
  win.opts.height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.6)), 1)
  win:update()
  -- The cursor stays on the group or process that the user chose, so that x
  -- acts on it after the rows move. The view scrolls only to keep it shown.
  local row, group_row
  for i, key in pairs(rows) do
    if key == chosen then
      row = i
    elseif key == chosen_group then
      group_row = i
    end
  end
  -- The first two lines are the summary and the column header.
  row = math.min(row or group_row or math.max(cursor, 3), #lines)
  local topline = math.min(math.max(view.topline, row - api.nvim_win_get_height(win.win) + 1), row)
  api.nvim_win_call(win.win, function()
    vim.fn.winrestview({ lnum = row, col = 0, topline = math.max(topline, 1) })
  end)
  placed = row
end

local function run(cmd, sync, cb)
  if sync then
    cb(M.ps(cmd))
  else
    M.ps(cmd, cb)
  end
end

local function update(list, cmdlines, at)
  for pid, p in pairs(list) do
    local usage = M.rusage(pid)
    p.mem, p.ended = usage and usage.footprint or p.rss, usage and usage.ended
    local old = prev and prev.procs[pid]
    local dt = prev and at - prev.at or 0
    if old and old.comm == p.comm and p.time >= old.time and dt > 0 then
      p.cpu = (p.time - old.time) / dt * 100
    else
      p.cpu = p.pcpu
    end
  end
  prev = { at = at, procs = list }
  procs, args = list, cmdlines
  groups, owner, core = M.group(list, cmdlines, marked)
  -- The walk starts at each core process, as a restarted server's TUI is
  -- not its parent.
  above = {}
  for pid in pairs(core) do
    local p = list[pid]
    while p and p.ppid > 1 do
      above[p.ppid] = not core[p.ppid] or nil
      p = list[p.ppid]
    end
  end
  by_key = {}
  for _, g in ipairs(groups) do
    by_key[g.key] = g
  end
end

local function args_cmd(pids)
  return { "ps", "-ww", "-o", "pid=,command=", "-p", table.concat(pids, ",") }
end

-- Takes a sample, and then draws it.
---@param sync? boolean
local function sample(sync)
  if busy then
    return
  end
  busy = true
  -- A background step after the window closed does no more work. The first
  -- sample runs in the foreground, before the window opens.
  local function closed()
    if not sync and not valid() then
      busy = false
      return true
    end
  end
  local function list()
    run(LIST, sync, function(out)
      if closed() then
        return
      end
      local at = M.clock()
      local found = M.parse(out or "")
      -- A failed ps keeps the rows that the window shows.
      if next(found) == nil then
        busy = false
        return
      end
      local pids = wanted(found)
      local function done(text)
        if closed() then
          return
        end
        busy = false
        update(found, parse_args(text or ""), at)
        draw()
      end
      if #pids == 0 then
        done()
      else
        run(args_cmd(pids), sync, done)
      end
    end)
  end
  if scanned and M.clock() - scanned < M.scan_interval then
    list()
    return
  end
  run(ENV, sync, function(out)
    if closed() then
      return
    end
    scanned = M.clock()
    -- A failed scan keeps the marks of the last one.
    marked = out and M.marked(out, vim.fn.getpid()) or marked
    list()
  end)
end

-- Takes a sample now, as the timer does.
function M.refresh()
  if valid() then
    sample()
  end
end

---@return snacks.win?
function M.get()
  return valid() and win or nil
end

---@return string|integer?
local function key_at_cursor()
  local w = M.get()
  return w and row_keys[api.nvim_win_get_cursor(w.win)[1]] or nil
end

function M.toggle()
  local key = key_at_cursor()
  if type(key) == "number" then
    key = owner[key]
  end
  local g = key and by_key[key]
  if not key or not g then
    return
  end
  if expanded[key] then
    expanded[key] = nil
  else
    expanded[key] = true
    local missing = {}
    for _, pid in ipairs(g.members) do
      if not args[pid] then
        missing[#missing + 1] = pid
      end
    end
    if #missing > 0 then
      args = vim.tbl_extend("force", args, parse_args(M.ps(args_cmd(missing)) or ""))
    end
  end
  draw()
end

function M.toggle_sort()
  sort = sort == "cpu" and "mem" or "cpu"
  draw()
end

local function warn(msg)
  vim.notify("anvim: " .. msg, vim.log.levels.WARN)
end

---@param name "SIGTERM"|"SIGKILL"
function M.signal(name)
  local key = key_at_cursor()
  local g = key and by_key[type(key) == "number" and owner[key] or key]
  if not g then
    return
  end
  local pids, what = {}, nil
  if type(key) == "number" then
    pids, what = { key }, ("%s (pid %d)"):format(basename(procs[key].comm), key)
  else
    local member = {}
    for _, pid in ipairs(g.members) do
      member[pid] = true
    end
    for _, pid in ipairs(g.members) do
      if not member[procs[pid].ppid] then
        pids[#pids + 1] = pid
      end
    end
    table.sort(pids)
    what = #pids == 1 and ("%s (pid %d)"):format(g.name, pids[1]) or ("%d %s processes"):format(#pids, g.name)
  end
  local own, terminal = g.kind == "anvim" and type(key) ~= "number", nil
  for _, pid in ipairs(pids) do
    own = own or core[pid]
    terminal = terminal or (above[pid] and pid)
  end
  if own then
    warn("this is anvim itself. :AnvimRestart restarts Claude, and :q quits")
    return
  elseif terminal then
    warn(("pid %d runs anvim's terminal, so the signal would end anvim too"):format(terminal))
    return
  end
  asking = true
  -- The safe choice comes first, so that x and then <CR> sends nothing.
  local send = "Send " .. name
  vim.ui.select({ "Cancel", send }, { prompt = ("Send %s to %s?"):format(name, what) }, function(choice)
    asking = false
    local w = M.get()
    if w then
      w:focus()
    end
    if choice ~= send then
      return
    end
    local failed = {}
    for _, pid in ipairs(pids) do
      local ok, err = M.kill(pid, name:lower())
      if not ok then
        failed[#failed + 1] = ("pid %d: %s"):format(pid, err)
      end
    end
    if #failed > 0 then
      warn(("%s failed for %s"):format(name, table.concat(failed, ", ")))
    end
    M.refresh()
  end)
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- After a confirm, the previous window is the closed picker's, so the focus
-- goes back to the window that had it before.
function M.close()
  local w = M.get()
  if w then
    w:close()
    if origin and api.nvim_win_is_valid(origin) then
      api.nvim_set_current_win(origin)
    end
  end
end

function M.open()
  local w = M.get()
  if w then
    w:focus()
    return
  end
  prev, expanded, row_keys, row_groups, busy, asking = nil, {}, {}, {}, false, false
  procs, groups, placed, chosen, chosen_group = {}, {}, nil, nil, nil
  marked, scanned, owner = {}, nil, {}
  -- The first sample comes before the window, so no frame shows it empty.
  sample(true)
  if next(procs) == nil then
    warn("ps failed, so the Processes window has nothing to show")
    return
  end
  origin = api.nvim_get_current_win()
  win = Snacks.win({
    position = "float",
    border = "rounded",
    title = title(),
    footer = { { " ⏎ expand · x stop · X kill · s sort · q close ", "FloatFooter" } },
    width = function()
      return math.min(100, vim.o.columns - 4)
    end,
    height = 1,
    enter = true,
    backdrop = false,
    zindex = Snacks.win.zindex(20),
    -- A filetype in bo would fire FileType at each refresh, which sets bo again.
    bo = { modifiable = false },
    -- An animated jump would let x act on a row that the cursor passes.
    b = { snacks_scroll = false },
    wo = { wrap = false, cursorline = true, winbar = "", list = false },
    keys = { q = false },
    on_close = function()
      stop_timer()
      win, prev = nil, nil
    end,
  })
  local buf = win.buf
  vim.bo[buf].filetype = "anvim_processes"
  for _, key in ipairs({ "q", "<Esc>" }) do
    keys.set("processes", "n", key, M.close, { buffer = buf, nowait = true })
  end
  keys.set("processes", "n", "<CR>", M.toggle, { buffer = buf, nowait = true })
  keys.set("processes", "n", "s", M.toggle_sort, { buffer = buf, nowait = true })
  keys.set("processes", "n", "x", function()
    M.signal("SIGTERM")
  end, { buffer = buf, nowait = true })
  keys.set("processes", "n", "X", function()
    M.signal("SIGKILL")
  end, { buffer = buf, nowait = true })
  -- A click or a window key elsewhere closes it, as it closes the key view.
  win:on("WinLeave", function(self)
    vim.schedule(function()
      if not asking and self:valid() and api.nvim_get_current_win() ~= self.win then
        self:close()
      end
    end)
  end, { buf = true })
  vim.cmd.stopinsert()
  draw()
  timer = assert(vim.uv.new_timer())
  timer:start(M.interval, M.interval, vim.schedule_wrap(M.refresh))
end

function M.attach(sidecar)
  -- Each child inherits the mark, even after its parent ends. A restarted
  -- server copies the old server's environment, so it sets its own.
  vim.env.ANVIM_PID = tostring(vim.fn.getpid())
  sidecar.on("tool_use", function(ev)
    local input = type(ev.input) == "table" and ev.input or {}
    if ev.name == "Bash" and type(input.command) == "string" then
      calls[ev.id] = { command = input.command, agent = agents.of(ev), main = not (ev.agent_id or ev.parent_id) }
    end
  end)
  sidecar.on("tool_result", function(ev)
    local result = type(ev.result) == "table" and ev.result or {}
    if not result.backgroundTaskId then
      calls[ev.id] = nil
    end
  end)
  for _, type in ipairs({ "history", "exit" }) do
    sidecar.on(type, function()
      calls = {}
    end)
  end
end

return M
