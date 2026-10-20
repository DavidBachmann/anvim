-- Sessions: resume one from a picker, restart the sidecar, /clear, the model
-- picker, and yanking Claude's last reply.
local config = require("anvim.config")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

---@class anvim.SessionItem
---@field id string
---@field title string
---@field modified integer ms since the epoch
---@field created integer?
---@field size integer? bytes
---@field branch string?
---@field first_prompt string?

---@type string? The model the user chose, which a restart keeps.
M.model = nil

---@param opts? table Fields to add, such as resume and history.
function M.start_command(opts)
  return vim.tbl_extend("force", {
    type = "start",
    cwd = state.cwd,
    model = M.model or config.options.model,
    permission_mode = config.options.permission_mode,
    append_system_prompt = config.options.append_system_prompt,
  }, opts or {})
end

local function redraw()
  require("anvim.input").redraw()
end

-- What belongs to one session. A new session starts with none of it.
local function forget()
  state.session_id, state.last_turn, state.cost_usd, state.context, state.turns = nil, nil, 0, nil, 0
  require("anvim.follow").forget()
end

-- Draws a resumed session's past with the same functions as live events.
local draw = {
  user = function(ev)
    transcript.turn_end()
    transcript.user(ev.text)
  end,
  text_start = transcript.text_start,
  text_delta = function(ev)
    transcript.text_delta(ev.text)
  end,
  text_stop = transcript.text_stop,
  tool_use = transcript.tool_use,
  tool_result = transcript.tool_result,
  output = function(ev)
    transcript.output(ev.text)
  end,
  compact = transcript.compact,
  -- A notification starts a turn of its own, as a prompt does.
  agent_end = function(ev)
    transcript.turn_end()
    transcript.agent_end(ev)
  end,
  notice = function(ev)
    transcript.notice(ev.level, ev.text)
  end,
}

function M.history(ev)
  transcript.clear()
  transcript.batch(function()
    for _, e in ipairs(ev.events or {}) do
      local fn = draw[e.type]
      if fn then
        local ok, err = pcall(fn, e)
        if not ok then
          sidecar.log(("history %s failed: %s"):format(e.type, err))
        end
      end
    end
    transcript.turn_end()
    transcript.settle_past()
  end)
  state.session_id = ev.session_id
  state.turns = 1
  transcript.reveal()
  redraw()
end

---@param id string
function M.resume(id)
  forget()
  transcript.turn_end()
  transcript.clear()
  transcript.notice("info", "Resuming session " .. id)
  sidecar.restart(M.start_command({ resume = id, history = true }))
  redraw()
end

-- Starts the sidecar again, as after it exited or hung. A session that has
-- saved a turn goes on where it was.
function M.restart()
  local id = (state.turns or 0) > 0 and state.session_id or nil
  -- Tool calls that the old sidecar runs end with it.
  transcript.turn_end()
  transcript.notice("info", id and "Restarting Claude in this session" or "Restarting Claude")
  state.process = "starting"
  sidecar.restart(M.start_command({ resume = id }))
  redraw()
end

-- /clear: Claude Code drops the conversation, and the next init names the
-- new session.
function M.reset()
  forget()
  transcript.clear()
  redraw()
end

-- 5 min ago, 3 h ago, as session lists show times.
function M.ago(ms, now)
  local secs = math.max(0, ((now or os.time() * 1000) - ms) / 1000)
  if secs < 60 then
    return "just now"
  elseif secs < 3600 then
    return ("%d min ago"):format(math.floor(secs / 60))
  elseif secs < 86400 then
    return ("%d h ago"):format(math.floor(secs / 3600))
  elseif secs < 86400 * 30 then
    local days = math.floor(secs / 86400)
    return days == 1 and "yesterday" or ("%d days ago"):format(days)
  end
  return os.date("%Y-%m-%d", math.floor(ms / 1000)) --[[@as string]]
end

function M.size(bytes)
  if not bytes then
    return ""
  elseif bytes < 1024 * 1024 then
    return ("%d KB"):format(math.max(1, math.floor(bytes / 1024 + 0.5)))
  end
  return ("%.1f MB"):format(bytes / 1024 / 1024)
end

---@param list anvim.SessionItem[]
function M.items(list, now)
  local items = {}
  for i, s in ipairs(list) do
    local current = s.id == state.session_id
    local title = vim.trim((s.title or ""):gsub("%s+", " "))
    local about = { "# " .. title, "", ("- Modified %s, %s"):format(M.ago(s.modified, now), M.size(s.size)) }
    if s.created then
      about[#about + 1] = "- Created " .. M.ago(s.created, now)
    end
    if s.branch then
      about[#about + 1] = ("- Branch `%s`"):format(s.branch)
    end
    about[#about + 1] = ("- Session `%s`%s"):format(s.id, current and " (this one)" or "")
    if s.first_prompt and s.first_prompt ~= s.title then
      vim.list_extend(about, { "", "First prompt:", "", "> " .. s.first_prompt:gsub("\n", "\n> ") })
    end
    items[i] = {
      idx = i,
      text = title,
      id = s.id,
      current = current,
      ago = M.ago(s.modified, now),
      size = M.size(s.size),
      branch = s.branch,
      preview = { text = table.concat(about, "\n"), ft = "markdown" },
    }
  end
  return items
end

-- Reads this directory's sessions through the SDK, in a short process of its own.
---@param cb fun(list: anvim.SessionItem[]?, err: string?)
function M.fetch(cb)
  local cmd = { config.options.bun, sidecar.dir .. "/src/sessions.ts", "list", state.cwd }
  vim.system(cmd, { text = true, cwd = sidecar.dir }, function(obj)
    vim.schedule(function()
      local ok, list = pcall(vim.json.decode, obj.stdout or "", { luanil = { object = true, array = true } })
      if obj.code == 0 and ok and type(list) == "table" then
        cb(list)
      else
        cb(nil, vim.trim(obj.stderr or "") ~= "" and vim.trim(obj.stderr) or "no answer")
      end
    end)
  end)
end

local function format(item)
  local ret = {
    { ("%-12s"):format(item.ago), "SnacksPickerComment" },
    { " " },
    { item.current and "⏺ " or "  ", "AnvimClaude" },
    { item.text },
  }
  local extra = item.size
  if item.branch then
    extra = extra ~= "" and (extra .. " · " .. item.branch) or item.branch
  end
  if extra ~= "" then
    ret[#ret + 1] = { "  " .. extra, "SnacksPickerComment" }
  end
  return ret
end

---@param items table[]
function M.show_picker(items)
  local ok, snacks = pcall(require, "snacks")
  if not (ok and snacks.picker) then
    vim.ui.select(items, {
      prompt = "Resume a session",
      format_item = function(item)
        return ("%s  %s"):format(item.ago, item.text)
      end,
    }, function(item)
      if item then
        M.resume(item.id)
      end
    end)
    return
  end
  snacks.picker.pick({
    source = "anvim_sessions",
    title = "Resume a session",
    items = items,
    format = format,
    preview = "preview",
    layout = { preset = "select", hidden = {} },
    confirm = function(picker, item)
      picker:close()
      if item and not item.current then
        M.resume(item.id)
      end
    end,
  })
end

function M.pick()
  M.fetch(function(list, err)
    if not list then
      vim.notify("anvim: could not list sessions: " .. err, vim.log.levels.ERROR)
    elseif #list == 0 then
      vim.notify("anvim: no saved sessions in this directory", vim.log.levels.INFO)
    else
      M.show_picker(M.items(list))
    end
  end)
end

---@type fun(models: table[])?
local on_models

---@param model { value: string, name: string, resolved: string? }
function M.set_model(model)
  M.model = model.value
  state.model = model.resolved or model.value
  sidecar.send({ type = "set_model", model = model.value })
  transcript.notice("info", "Set model to " .. model.name)
  redraw()
end

function M.show_models(models)
  vim.ui.select(models, {
    prompt = "Model",
    format_item = function(m)
      local current = (m.resolved or m.value) == state.model and "⏺ " or "  "
      return ("%s%-24s %s"):format(current, m.name, m.description or "")
    end,
  }, function(choice)
    if choice then
      M.set_model(choice)
    end
  end)
end

function M.pick_model()
  if not sidecar.running() then
    vim.notify("anvim: Claude is not running. :AnvimRestart starts it", vim.log.levels.WARN)
    return
  end
  on_models = M.show_models
  sidecar.send({ type = "list_models" })
end

-- Slash commands that Claude Code's TUI runs itself, and anvim runs here.
---@return boolean handled
function M.command(text)
  local name, arg = text:match("^(/%S+)%s*(.-)%s*$")
  if name == "/resume" then
    M.pick()
    return true
  elseif name == "/model" and arg == "" then
    M.pick_model()
    return true
  elseif name == "/model" then
    M.set_model({ value = arg, name = arg })
    return true
  end
  return false
end

---@param reg? string The register, + by default.
function M.yank(reg)
  local text = transcript.last_reply()
  if text == "" then
    vim.notify("anvim: Claude has not replied yet", vim.log.levels.INFO)
    return
  end
  reg = reg or "+"
  -- Without a clipboard tool, the + register fails. The unnamed one still works.
  if not pcall(vim.fn.setreg, reg, text) then
    reg = '"'
    vim.fn.setreg(reg, text)
  end
  local lines = select(2, text:gsub("\n", "")) + 1
  vim.notify(("anvim: copied Claude's last reply to %s (%d line%s)"):format(reg, lines, lines == 1 and "" or "s"))
end

-- The commands of M.command, for the prompt's completion. Claude Code's list
-- comes first, because completion.lua's handlers run before these.
local own_commands = {
  { name = "resume", description = "Resume a session of this directory" },
  { name = "model", description = "Choose Claude's model", argument_hint = "[model]" },
}

local function add_commands()
  local completion = package.loaded["anvim.completion"]
  if not completion then
    return
  end
  for _, cmd in ipairs(own_commands) do
    local known = vim.iter(completion.commands):any(function(c)
      return c.name == cmd.name
    end)
    if not known then
      completion.commands[#completion.commands + 1] = cmd
    end
  end
end

function M.attach()
  sidecar.on("init", add_commands)
  sidecar.on("commands", add_commands)
  sidecar.on("history", M.history)
  sidecar.on("reset", M.reset)
  -- A /clear also ends a turn, but saves none.
  sidecar.on("turn_end", function(ev)
    if (ev.num_turns or 0) > 0 then
      state.turns = (state.turns or 0) + 1
    end
  end)
  sidecar.on("context", function(ev)
    state.context = ev
    redraw()
  end)
  sidecar.on("models", function(ev)
    local cb = on_models
    on_models = nil
    if cb and #(ev.models or {}) > 0 then
      cb(ev.models)
    elseif cb then
      vim.notify("anvim: Claude Code listed no models", vim.log.levels.WARN)
    end
  end)
end

return M
