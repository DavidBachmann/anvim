-- Runs the Agent SDK sidecar and speaks its line protocol (sidecar/src/protocol.ts).
local config = require("anvim.config")

local M = {}

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
M.dir = root .. "/sidecar"
M.log_path = vim.fn.stdpath("log") .. "/anvim.log"

---@type vim.SystemObj?
local proc
---@type table? The start command for the next sidecar, once this one exits.
local next_start
-- Commands sent while a restart waits, for the new sidecar.
local queued = {}
---@type table<string, fun(ev: table)[]>
local handlers = {}

---@param type string Event type, or '*' for every event.
---@param fn fun(ev: table)
function M.on(type, fn)
  handlers[type] = handlers[type] or {}
  table.insert(handlers[type], fn)
end

function M.dispatch(ev)
  for _, key in ipairs({ ev.type, "*" }) do
    for _, fn in ipairs(handlers[key] or {}) do
      local ok, err = pcall(fn, ev)
      if not ok then
        M.log(("handler for %s failed: %s"):format(ev.type, err))
      end
    end
  end
end

function M.log(text)
  local f = io.open(M.log_path, "a")
  if f then
    f:write(os.date("%H:%M:%S "), text, "\n")
    f:close()
  end
end

local function command()
  local opts = config.options
  if opts.sidecar_cmd then
    return opts.sidecar_cmd
  end
  if not vim.uv.fs_stat(M.dir .. "/node_modules") then
    vim.notify("anvim: installing sidecar dependencies...")
    vim.system({ opts.bun, "install", "--frozen-lockfile" }, { cwd = M.dir }):wait()
  end
  return { opts.bun, M.dir .. "/src/main.ts" }
end

-- The sidecar's env, and so the env of Claude's shell, without the variables
-- that tie a process to this Neovim. With them, an nvim that Claude starts
-- uses anvim's dirs, and NVIM names anvim's own socket.
function M.env()
  local env = vim.fn.environ()
  for _, name in ipairs({ "NVIM", "NVIM_APPNAME", "NVIM_LISTEN_ADDRESS", "NVIM_LOG_FILE", "VIMRUNTIME", "MYVIMRC" }) do
    env[name] = nil
  end
  return env
end

-- Splits stdout into lines and decodes them in the read callback. Dispatch is
-- scheduled, so handlers may call any API. A line can be megabytes long, as
-- a resumed session's history, so its chunks wait in a list until it ends.
function M.line_reader()
  local parts = {}
  return function(err, data)
    if err then
      M.log("stdout error: " .. err)
    end
    if not data then
      return
    end
    local events, from = {}, 1
    while true do
      local nl = data:find("\n", from, true)
      if not nl then
        parts[#parts + 1] = data:sub(from)
        break
      end
      parts[#parts + 1] = data:sub(from, nl - 1)
      local line = table.concat(parts)
      parts, from = {}, nl + 1
      if line ~= "" then
        local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
        if ok and type(ev) == "table" then
          events[#events + 1] = ev
        else
          M.log("bad event: " .. line:sub(1, 200))
        end
      end
    end
    if #events > 0 then
      vim.schedule(function()
        for _, ev in ipairs(events) do
          M.dispatch(ev)
        end
      end)
    end
  end
end

---@param start table The start command (see protocol.ts).
function M.start(start)
  if proc then
    return
  end
  proc = vim.system(command(), {
    stdin = true,
    cwd = start.cwd,
    env = M.env(),
    clear_env = true,
    stdout = M.line_reader(),
    stderr = function(_, data)
      if data then
        M.log(vim.trim(data))
      end
    end,
  }, function(obj)
    vim.schedule(function()
      proc = nil
      local start_next = next_start
      next_start = nil
      -- While Neovim quits, its buffers are unloaded and the handlers would fail.
      if vim.v.exiting == vim.NIL then
        M.dispatch({ type = "exit", code = obj.code, restart = start_next ~= nil or nil })
      end
      if start_next then
        M.start(start_next)
        local msgs = queued
        queued = {}
        for _, msg in ipairs(msgs) do
          M.send(msg)
        end
      end
    end)
  end)
  M.send(start)
end

-- Stops the sidecar and starts a new one with `start`. A sidecar that hangs
-- does not read its closed stdin, so it gets signals after a while.
---@param start table
function M.restart(start)
  if not proc then
    M.start(start)
    return
  end
  next_start = start
  local old = proc
  pcall(old.write, old, nil)
  vim.defer_fn(function()
    if proc == old then
      old:kill("sigterm")
    end
  end, 2000)
  vim.defer_fn(function()
    if proc == old then
      old:kill("sigkill")
    end
  end, 4000)
end

function M.send(msg)
  if next_start then
    queued[#queued + 1] = msg
  elseif proc then
    proc:write(vim.json.encode(msg) .. "\n")
  end
end

function M.running()
  return proc ~= nil
end

-- Closing stdin lets the sidecar close its Claude Code process before it exits.
function M.stop()
  next_start, queued = nil, {}
  if proc then
    pcall(proc.write, proc, nil)
  end
end

return M
