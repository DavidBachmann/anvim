-- Each agent's files: the files under the cwd that it read, edited, wrote or
-- showed, with the last time it touched them. The main agent has the key "".
-- The code window's tab bar shows the slots of the agent that follow mode
-- follows.
local agents = require("anvim.agents")
local bashread = require("anvim.bashread")
local state = require("anvim.state")

local M = {}

local api = vim.api

-- The tabs of the bar.
M.slots = 5
-- The files that each agent keeps, newest first.
local MAX = 100

---@class anvim.File
---@field path string The real path.
---@field time integer? When the agent touched it last, in seconds. A resumed session's call can lack it.
---@field seq integer The order of the touches, over all agents.
---@field edited boolean An Edit, Write or NotebookEdit of the agent changed it.

---@class anvim.Files
---@field files table<string, anvim.File> By real path.
---@field slots string[] The real paths of the bar's tabs, left to right.

---@type table<string, anvim.Files>
local lists = {}
-- The edits that wait for their result, by tool id.
---@type table<string, { key: string, path: string }>
local edits = {}
local seq = 0
-- Real paths by the path given. A Write's file resolves through its folder
-- before it exists, and gets the same path once it does.
---@type table<string, string>
local reals = {}

---@param path string Absolute, or relative to the cwd.
---@return string
function M.real(path)
  local real = reals[path]
  if real then
    return real
  end
  local full = vim.fs.normalize(vim.fn.isabsolutepath(path) == 1 and path or vim.fs.joinpath(state.cwd, path))
  real = vim.uv.fs_realpath(full)
  if not real then
    local dir = vim.uv.fs_realpath(vim.fs.dirname(full))
    real = dir and vim.fs.joinpath(dir, vim.fs.basename(full)) or full
  end
  reals[path] = real
  return real
end

local function under_cwd(real)
  local cwd = M.real(state.cwd)
  return vim.startswith(real, cwd .. "/")
end

local function changed()
  api.nvim_exec_autocmds("User", { pattern = "AnvimFiles", modeline = false })
end

-- Whether an edit that waits for its result writes `path`.
local function pending(path)
  for _, edit in pairs(edits) do
    if edit.path == path then
      return true
    end
  end
  return false
end

-- A file that the bar does not show yet goes in at the right. When the bar
-- is full, a file that is gone leaves first, as the bar hides it. Else the
-- file that the agent touched longest ago leaves.
---@param list anvim.Files
local function take_slot(list, path)
  if vim.tbl_contains(list.slots, path) then
    return
  end
  if #list.slots >= M.slots then
    local out
    for i, p in ipairs(list.slots) do
      if not vim.uv.fs_stat(p) and not pending(p) then
        out = i
        break
      elseif not out or list.files[p].seq < list.files[list.slots[out]].seq then
        out = i
      end
    end
    table.remove(list.slots, out)
  end
  list.slots[#list.slots + 1] = path
end

---@param list anvim.Files
local function trim(list)
  local all = vim.tbl_values(list.files)
  if #all <= MAX then
    return
  end
  table.sort(all, function(a, b)
    return a.seq > b.seq
  end)
  for i = MAX + 1, #all do
    if not vim.tbl_contains(list.slots, all[i].path) then
      list.files[all[i].path] = nil
    end
  end
end

-- Records that agent `key` touched `path`, and returns its real path, or
-- nil for a path that does not count.
---@param time integer?
---@param edit boolean? A Write's file may not exist yet.
---@return string?
local function touch(key, path, time, edit)
  if type(path) ~= "string" or path == "" then
    return
  end
  local real = M.real(path)
  local stat = vim.uv.fs_stat(real)
  if not under_cwd(real) or (stat and stat.type ~= "file") or not (stat or edit) then
    return
  end
  local list = lists[key] or { files = {}, slots = {} }
  lists[key] = list
  seq = seq + 1
  local file = list.files[real] or { path = real, edited = false }
  file.time, file.seq = time, seq
  list.files[real] = file
  take_slot(list, real)
  trim(list)
  changed()
  return real
end

local edit_paths = agents.edit_keys

-- The agent's key, or nil for an event of an agent that anvim does not know.
---@return string?
local function key_of(ev)
  local agent = agents.of(ev)
  if not agent and (ev.agent_id or ev.parent_id) then
    return
  end
  return agent and agent.id or ""
end

---@param time integer|false? The time of a resumed session's call, false when it has none. Live calls take the clock's.
function M.tool_use(ev, time)
  local key = key_of(ev)
  if not key then
    return
  end
  if time == nil then
    time = require("anvim.transcript").clock()
  end
  time = time or nil
  local input = type(ev.input) == "table" and ev.input or {}
  if ev.name == "Read" or ev.name == "Bash" then
    for _, read in ipairs(bashread.reads(ev)) do
      touch(key, read.path, time)
    end
  elseif edit_paths[ev.name] then
    local real = touch(key, input[edit_paths[ev.name]], time, true)
    if real then
      edits[ev.id] = { key = key, path = real }
    end
  elseif ev.name == "mcp__anvim__show_user" then
    touch(key, input.path, time)
  end
end

-- An edit counts once it worked. A new file that a failed Write did not make
-- gives its tab back.
function M.tool_result(ev)
  local edit = edits[ev.id]
  edits[ev.id] = nil
  local list = edit and lists[edit.key]
  local file = list and list.files[edit.path]
  if not file then
    return
  end
  if ev.is_error then
    if not vim.uv.fs_stat(file.path) and not pending(file.path) then
      list.files[file.path] = nil
      list.slots = vim.tbl_filter(function(p)
        return p ~= file.path
      end, list.slots)
      changed()
    end
  elseif not file.edited then
    file.edited = true
    changed()
  end
end

-- An edit's preview can show its file before the call's tool_use comes, so
-- the file takes its tab then. The main agent's path streams first, and a
-- subagent's whole input comes with the preview's request.
local function tool_field(ev)
  if ev.phase == "end" and edit_paths[ev.name] == ev.key then
    touch("", ev.value, require("anvim.transcript").clock(), true)
  end
end

local function await_preview(ev)
  local agent = ev.agent_id and agents.get(ev.agent_id)
  local input = type(ev.input) == "table" and ev.input or {}
  if agent and edit_paths[ev.name] then
    touch(agent.id, input[edit_paths[ev.name]], require("anvim.transcript").clock(), true)
  end
end

-- The bar's files of agent `key`, left to right. A file that is gone drops
-- out, unless it is `keep`, such as a Write preview's file.
---@param keep string? A real path.
---@return anvim.File[]
function M.bar(key, keep)
  local list = lists[key]
  local ret = {}
  for _, path in ipairs(list and list.slots or {}) do
    if path == keep or vim.uv.fs_stat(path) then
      ret[#ret + 1] = list.files[path]
    end
  end
  return ret
end

---@param path string A real path.
---@return anvim.File?
function M.get(key, path)
  return lists[key] and lists[key].files[path]
end

-- The files of agent `key` that exist, newest first.
---@param max integer?
---@return anvim.File[]
function M.list(key, max)
  local all = vim.tbl_values(lists[key] and lists[key].files or {})
  table.sort(all, function(a, b)
    return a.seq > b.seq
  end)
  local ret = {}
  for _, file in ipairs(all) do
    if #ret == (max or MAX) then
      break
    elseif vim.uv.fs_stat(file.path) then
      ret[#ret + 1] = file
    end
  end
  return ret
end

-- A resumed session replays its past into empty lists.
function M.clear()
  lists, edits, reals = {}, {}, {}
  changed()
end

function M.attach(sidecar)
  sidecar.on("tool_use", function(ev)
    M.tool_use(ev)
  end)
  sidecar.on("tool_result", M.tool_result)
  sidecar.on("tool_field", tool_field)
  sidecar.on("await_preview", await_preview)
  -- The next sidecar knows none of these calls.
  sidecar.on("exit", function()
    edits = {}
  end)
end

return M
