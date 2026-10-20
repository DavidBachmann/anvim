-- Runs the Agent SDK sidecar and speaks its line protocol (sidecar/src/protocol.ts).
local config = require("anvim.config")

local M = {}

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
M.dir = root .. "/sidecar"
M.log_path = vim.fn.stdpath("log") .. "/anvim.log"

---@type vim.SystemObj?
local proc
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
    vim.system({ opts.bun, "install" }, { cwd = M.dir }):wait()
  end
  return { opts.bun, M.dir .. "/src/main.ts" }
end

-- Splits stdout into lines and decodes them off the main loop. Dispatch is
-- scheduled, so handlers may call any API.
local function line_reader()
  local pending = ""
  return function(err, data)
    if err then
      M.log("stdout error: " .. err)
    end
    if not data then
      return
    end
    pending = pending .. data
    local events = {}
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
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
    stdout = line_reader(),
    stderr = function(_, data)
      if data then
        M.log(vim.trim(data))
      end
    end,
  }, function(obj)
    vim.schedule(function()
      proc = nil
      M.dispatch({ type = "exit", code = obj.code })
    end)
  end)
  M.send(start)
end

function M.send(msg)
  if proc then
    proc:write(vim.json.encode(msg) .. "\n")
  end
end

function M.running()
  return proc ~= nil
end

-- Closing stdin lets the sidecar close its Claude Code process before it exits.
function M.stop()
  if proc then
    proc:write(nil)
  end
end

return M
