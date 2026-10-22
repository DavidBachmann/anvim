-- Sessions: resume one from a picker, restart the sidecar, /clear, the model
-- and effort pickers, and yanking Claude's last reply.
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

---@class anvim.ModelInfo
---@field value string the id or alias to set
---@field name string
---@field description string?
---@field resolved string? the id that an alias names
---@field effort_levels string[]? absent for a model without effort levels

---@type string? The model the user chose, which a restart keeps.
M.model = nil
---@type string|false|nil The effort the user chose, which a restart keeps. False is the default.
M.effort_choice = nil
---@type anvim.ModelInfo[]? Claude Code's models, which the sidecar sends after start.
M.models = nil

local LEVELS = config.effort_levels
-- The default effort is the one that a new session takes: the user's Claude
-- Code settings for the model, else the model's own level.
local DEFAULT = "default (your settings, else the model's)"

-- The effort level that this session asks for, or nil for the default. A
-- start without one gets the default from Claude Code itself.
---@return string?
function M.effort()
  local effort = M.effort_choice
  if effort == nil then
    effort = config.options.effort
  end
  return effort or nil
end

-- The effort that the user chose for this session, "default" included, or
-- nil when they chose none.
---@return string?
local function chosen()
  if M.effort_choice == false then
    return "default"
  end
  return M.effort()
end

---@param opts? table Fields to add, such as resume and history.
function M.start_command(opts)
  if config.end_fallback() then
    state.permission_mode = config.options.permission_mode
  end
  return vim.tbl_extend("force", {
    type = "start",
    cwd = state.cwd,
    model = M.model or config.options.model,
    effort = M.effort(),
    permission_mode = config.options.permission_mode,
    permission_mode_chosen = config.mode_chosen,
    sandbox = config.options.sandbox ~= false,
    append_system_prompt = config.options.append_system_prompt,
  }, opts or {})
end

local function redraw()
  require("anvim.input").redraw()
end

-- A picker that the prompt opened in insert mode gives insert mode back when
-- it closes, also after a cancel. The prompt is the window it goes back to.
---@return fun()
local function from_prompt()
  local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  return function()
    if insert then
      require("anvim.input").resume()
    end
  end
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
        transcript.batch_time(e.time)
        local ok, err = pcall(fn, e)
        if not ok then
          sidecar.log(("history %s failed: %s"):format(e.type, err))
        end
      end
    end
    transcript.batch_time(nil)
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
  local back = from_prompt()
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
      back()
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
    main = { current = true },
    confirm = function(picker, item)
      picker:close()
      if item and not item.current then
        M.resume(item.id)
      end
    end,
    -- The picker gives the cursor back after this.
    on_close = function()
      vim.schedule(back)
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

-- What Claude Code's list says about a model, by its id or alias. Without an
-- id, the model of this session.
---@param id string?
---@return anvim.ModelInfo?
local function model_info(id)
  id = id or state.model or M.model or config.options.model or "default"
  for _, m in ipairs(M.models or {}) do
    if m.value == id or m.resolved == id then
      return m
    end
  end
end

-- low, medium and high
---@param last string the word before the last item, such as "and"
local function join(words, last)
  return #words < 2 and (words[1] or "")
    or ("%s %s %s"):format(table.concat(words, ", ", 1, #words - 1), last, words[#words])
end

-- The effort levels of this session's model: nil when Claude Code's list
-- does not name the model, and an empty list for a model without effort.
---@return string[]?
function M.effort_levels()
  local info = model_info()
  return info and (info.effort_levels or {})
end

---@param model { value: string, name: string, resolved: string? }
function M.set_model(model)
  M.model = model.value
  state.model = model.resolved or model.value
  sidecar.send({ type = "set_model", model = model.value })
  transcript.notice("info", "Set model to " .. model.name)
  -- Claude Code keeps the effort over a model switch, also to a model that
  -- lacks it, and applies it again on a model that has it.
  local info, effort = model_info(model.value), M.effort()
  if info and effort and not vim.tbl_contains(info.effort_levels or {}, effort) then
    transcript.notice(
      "info",
      ("%s has no %s effort. Claude Code keeps it for a model that has it."):format(info.name, effort)
    )
  end
  redraw()
end

---@param level string? Nil is the default.
function M.set_effort(level)
  M.effort_choice = level or false
  sidecar.send({ type = "set_effort", effort = level or vim.NIL })
  transcript.notice("info", "Set effort to " .. (level or DEFAULT))
  redraw()
end

---@param levels string[]
function M.show_efforts(levels)
  local current, back = chosen(), from_prompt()
  vim.ui.select(vim.list_extend({ "default" }, levels), {
    prompt = "Effort",
    format_item = function(level)
      return (level == current and "⏺ " or "  ") .. (level == "default" and DEFAULT or level)
    end,
  }, function(choice)
    if choice then
      M.set_effort(choice ~= "default" and choice or nil)
    end
    back()
  end)
end

-- A picker of the model's own levels. Without Claude Code's list, as in a
-- replay, it offers every level.
function M.pick_effort()
  local levels = M.effort_levels()
  if levels and #levels == 0 then
    local name = model_info().name
    transcript.notice("info", name .. " has no effort levels.")
    return
  end
  M.show_efforts(levels or LEVELS)
end

-- /effort, /effort <level> and /effort default. Claude Code answers
-- /effort current itself. A level that the model lacks goes nowhere, because
-- Claude Code would run another level, such as high for max. Any other word
-- goes nowhere too, because Claude Code takes some words that anvim does not
-- offer.
---@return boolean handled
local function effort_command(arg)
  local level, levels = arg:lower(), M.effort_levels()
  if level == "current" or level == "status" then
    return false
  elseif level == "" then
    M.pick_effort()
  elseif level == "default" or level == "auto" then
    M.set_effort(nil)
  elseif not vim.tbl_contains(LEVELS, level) then
    local known = vim.list_extend(vim.deepcopy(levels and #levels > 0 and levels or LEVELS), { "default" })
    transcript.notice("info", ("/effort takes %s."):format(join(known, "or")))
  elseif levels and not vim.tbl_contains(levels, level) then
    local name = model_info().name
    local has = #levels > 0 and (" It has " .. join(levels, "and") .. ".") or ""
    transcript.notice("info", ("%s has no %s effort.%s"):format(name, level, has))
  else
    M.set_effort(level)
  end
  return true
end

function M.show_models(models)
  local back = from_prompt()
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
    back()
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

-- Slash commands that Claude Code's TUI runs itself, and anvim runs here. A
-- built-in that does nothing here gets a notice, and goes nowhere.
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
  elseif name == "/effort" then
    return effort_command(arg)
  end
  local reason = name and require("anvim.completion").unusable(name:sub(2), arg)
  if reason then
    transcript.notice("info", reason)
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
-- comes first, because completion.lua's handlers run before these. Each one
-- takes the place of Claude Code's row of its name, whose argument hint
-- would keep Enter from sending it.
local own_commands = {
  { name = "resume", description = "Resume a session of this directory" },
  { name = "model", description = "Choose Claude's model", argument_hint = "[model]" },
  { name = "effort", description = "Set the effort level for this session", argument_hint = "[level]" },
}

local function add_commands()
  local completion = package.loaded["anvim.completion"]
  if not completion then
    return
  end
  for _, cmd in ipairs(own_commands) do
    local kept, at = {}, nil
    for _, c in ipairs(completion.commands) do
      if c.name == cmd.name then
        at = at or #kept + 1
      else
        kept[#kept + 1] = c
      end
    end
    table.insert(kept, at or #kept + 1, cmd)
    completion.commands = kept
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
  sidecar.on("effort", function(ev)
    state.effort = ev.level
    redraw()
  end)
  sidecar.on("models", function(ev)
    -- The effort picker and its checks need the models' levels.
    if #(ev.models or {}) > 0 then
      M.models = ev.models
    end
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
