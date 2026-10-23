-- mcp__anvim__reload, for anvim's own development: Neovim restarts with the
-- code on disk once Claude is idle, and the new anvim resumes the session.
-- The restart starts the new server with this server's env, so the env
-- carries the session, the model, the effort, the mode and the draft.
local agents = require("anvim.agents")
local config = require("anvim.config")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

local M = {}

local api = vim.api

M.root = vim.fs.dirname(sidecar.dir)
-- What a reload sets for the new anvim. It removes them, so that Claude's
-- shell does not get them.
M.vars = { "ANVIM_RELOADED", "ANVIM_RESUME", "ANVIM_CONTINUE", "ANVIM_MODEL", "ANVIM_EFFORT", "ANVIM_MODE" }
-- A background agent's end starts a main turn, whose init comes a moment
-- later. Without an init in this time, its end came inside a turn.
M.notify_ms = 3000

-- Whether a terminal shows this Neovim. :restart moves the UIs to the new server.
function M.tui()
  return vim.iter(api.nvim_list_uis()):any(function(ui)
    return ui.stdout_tty
  end)
end

-- :restart! writes no session file, and +qall! quits also with changed buffers.
function M.exec()
  vim.cmd("restart! +qall!")
end

local pending = false
-- The main agent works: from a turn's init to its end.
local in_turn = false
-- A background agent ended, and the main turn that its end starts has not begun.
local awaiting = false
---@type uv.uv_timer_t?
local awaiting_timer
local scheduled = false

-- The first .lua file that does not parse, as Lua's message.
local function lua_error()
  local files = { M.root .. "/init.lua" }
  for name, kind in vim.fs.dir(M.root .. "/lua", { depth = math.huge }) do
    if kind == "file" and name:match("%.lua$") then
      files[#files + 1] = M.root .. "/lua/" .. name
    end
  end
  for _, file in ipairs(files) do
    local ok, err = loadfile(file)
    if not ok then
      return err
    end
  end
end

-- What the new anvim needs: the session, how it runs, and the prompt's draft.
-- The start mode stays as it is, chosen or not: a mode that nobody chose
-- falls back without a sandbox, and only a bypass start can switch to bypass.
-- The marker carries the mode that the session uses now.
local function new_env()
  local sessions = require("anvim.sessions")
  local start = config.options.permission_mode
  local draft = api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false)
  return {
    ANVIM_RESUME = state.session_id,
    ANVIM_MODEL = sessions.model or config.options.model,
    ANVIM_EFFORT = sessions.effort(),
    ANVIM_MODE = config.mode_chosen and start or nil,
    ANVIM_RELOADED = vim.json.encode({
      session_id = state.session_id,
      mode = state.permission_mode ~= start and state.permission_mode or nil,
      draft = (#draft > 1 or draft[1] ~= "") and draft or nil,
    }),
  }
end

local function restart()
  pending = false
  if not M.tui() then
    vim.notify("anvim: no terminal shows this Neovim, so it cannot reload", vim.log.levels.WARN)
    return
  end
  local env, old = new_env(), {}
  for _, name in ipairs(M.vars) do
    old[name] = vim.env[name]
    vim.env[name] = env[name]
  end
  local ok, err = pcall(M.exec)
  if not ok then
    for _, name in ipairs(M.vars) do
      vim.env[name] = old[name]
    end
    vim.notify("anvim: the reload failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function idle()
  return not (state.busy or in_turn or awaiting or require("anvim.permission").waiting() or #agents.running() > 0)
end

-- Event handlers only mark the check, which runs after the batch of events.
local function check()
  if not pending or scheduled then
    return
  end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    if pending and idle() then
      restart()
    end
  end)
end

local function stop_awaiting()
  awaiting = false
  if awaiting_timer and not awaiting_timer:is_closing() then
    awaiting_timer:stop()
    awaiting_timer:close()
  end
  awaiting_timer = nil
end

---@param done fun(result: string?, err: string?)
function M.request(done)
  if not config.options.debug then
    return done(nil, "The reload tool works only when anvim runs with --debug.")
  elseif not M.tui() then
    return done(nil, "No terminal shows this Neovim, and :restart needs one.")
  elseif vim.fn.exists(":restart") ~= 2 then
    return done(nil, "This Neovim has no :restart.")
  elseif vim.env.ANVIM_REPLAY then
    return done(nil, "anvim plays a recording, which a reload cannot resume.")
  elseif not state.session_id then
    return done(nil, "The session has no id yet, so a reload cannot resume it.")
  end
  local err = lua_error()
  if err then
    return done(nil, "anvim would not start, so it does not reload: " .. err)
  end
  -- A build resolves every import of the sidecar, and writes nothing.
  local cmd = { config.options.bun, "build", sidecar.dir .. "/src/main.ts", "--target=bun", "--outfile=/dev/null" }
  vim.system(cmd, { cwd = sidecar.dir, text = true, timeout = 8000 }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local out = vim.trim((obj.stderr or "") .. "\n" .. (obj.stdout or ""))
        return done(nil, "The sidecar does not build, so anvim does not reload:\n" .. out)
      end
      pending = true
      require("anvim.transcript").notice(
        "info",
        "anvim restarts once Claude and its agents are idle. Stopping Claude cancels the restart."
      )
      done(
        "anvim restarts with the code on disk when this turn ends and no agent runs. End your turn now. "
          .. "anvim then resumes this session and sends a prompt that says it restarted."
      )
      check()
    end)
  end)
end

-- The user stopped Claude, so the restart and the prompt after it would undo the stop.
function M.cancel()
  if pending then
    pending = false
    require("anvim.transcript").notice("info", "anvim does not restart, because you stopped Claude.")
  end
end

---@class anvim.Reloaded
---@field session_id string
---@field mode string? The permission mode, when it is not the start mode.
---@field draft string[]?

-- The prompt that tells Claude about the restart, once the git answers are in.
---@param info anvim.Reloaded
local function announce(info)
  ---@type string|false|nil False when git cannot tell.
  local commit
  ---@type 'dirty'|'clean'|false|nil
  local tree
  local history, sent = false, false
  local function send()
    if sent or not history or commit == nil or tree == nil then
      return
    end
    sent = true
    local text = {
      "This message comes from anvim, not from the user.",
      "anvim restarted, as you asked with mcp__anvim__reload.",
    }
    if commit then
      local sha, subject = commit:match("^(%S+) ?(.*)$")
      text[#text + 1] = ('It now runs commit %s of %s: "%s".'):format(sha, M.root, subject)
    else
      text[#text + 1] = ("anvim could not read the git commit of %s."):format(M.root)
    end
    if tree == "dirty" then
      text[#text + 1] = "The working tree has uncommitted changes."
    elseif tree == "clean" then
      text[#text + 1] = "The working tree has no uncommitted changes."
    end
    require("anvim.input").send(table.concat(text, " "))
  end
  local function git(args, cb)
    vim.system(vim.list_extend({ "git", "-C", M.root }, args), { text = true }, function(obj)
      vim.schedule(function()
        cb(obj.code == 0 and vim.trim(obj.stdout or "") or nil)
        send()
      end)
    end)
  end
  git({ "log", "-1", "--format=%h %s" }, function(out)
    commit = out ~= nil and out ~= "" and out
  end)
  git({ "status", "--porcelain" }, function(out)
    tree = out ~= nil and (out == "" and "clean" or "dirty")
  end)
  -- The history comes only when the session exists. A new session gets no prompt.
  sidecar.on("history", function(ev)
    if ev.session_id == info.session_id and not sent then
      history = true
      local input = require("anvim.input")
      if info.mode and info.mode ~= state.permission_mode and vim.tbl_contains(input.modes(), info.mode) then
        state.permission_mode = info.mode
        sidecar.send({ type = "set_permission_mode", mode = info.mode })
      end
      vim.schedule(send)
    end
  end)
  local function give_up()
    if not history then
      sent = true
    end
  end
  sidecar.on("init", give_up)
  sidecar.on("exit", give_up)
end

-- Takes the marker of a reload, if this anvim started from one.
---@return anvim.Reloaded?
local function take_marker()
  local raw = vim.env.ANVIM_RELOADED
  if not raw then
    return
  end
  for _, name in ipairs(M.vars) do
    vim.env[name] = nil
  end
  local ok, info = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if ok and type(info) == "table" and type(info.session_id) == "string" then
    return info
  end
end

-- Runs before the sidecar starts.
function M.attach()
  local info = take_marker()
  if info then
    if info.draft then
      local input = require("anvim.input")
      api.nvim_buf_set_lines(input.buf(), 0, -1, false, info.draft)
      input.render()
    end
    announce(info)
  end
  sidecar.on("init", function()
    in_turn = true
    stop_awaiting()
  end)
  sidecar.on("turn_start", function()
    in_turn = true
    stop_awaiting()
  end)
  sidecar.on("turn_end", function()
    in_turn = false
    check()
  end)
  sidecar.on("exit", function()
    in_turn = false
    stop_awaiting()
    check()
  end)
  sidecar.on("agent_end", function(ev)
    local agent = agents.get(ev.agent_id)
    if agent and agent.background then
      stop_awaiting()
      awaiting = true
      awaiting_timer = vim.defer_fn(function()
        awaiting_timer = nil
        awaiting = false
        check()
      end, M.notify_ms)
    end
    check()
  end)
  -- A permission request closes with a redraw, which fires AnvimStatus.
  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("anvim.reload", { clear = true }),
    pattern = { "AnvimStatus", "AnvimAgents" },
    callback = check,
  })
end

return M
