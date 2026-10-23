-- Claude Code's Settings dialog in a float, with Status, Usage and Context
-- tabs. /status, /usage and /context open it. Claude Code's /usage and
-- /context in the SDK print text, which would go into Claude's context, and
-- its /status does not run there.
local keys = require("anvim.keys")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.settings")
-- Room for the context grid and its legend side by side.
local WIDTH = 88
local BAR = 50
local TABS = { "status", "usage", "context" }
local NAMES = { status = "Status", usage = "Usage", context = "Context" }
-- The request that answers each tab.
local REQUESTS = { status = "session_info", usage = "usage", context = "context_usage" }
-- Claude Code's theme colors, as highlight groups. The rest are grey.
local COLORS = {
  claude = "AnvimClaude",
  warning = "DiagnosticWarn",
  error = "DiagnosticError",
  success = "DiagnosticOk",
  permission = "DiagnosticInfo",
  suggestion = "DiagnosticHint",
  text = "Normal",
}

---@type snacks.win?
local win
---@type "status"|"usage"|"context"
local tab = "status"
-- The answers since the window opened, by tab: the event, or nil while it loads.
---@type table<string, table>
local answers = {}

local function valid()
  return win ~= nil and win:valid()
end

---@class anvim.SettingsText
---@field lines string[]
---@field marks table[] { row, col, end_col, group }
local Text = {}
Text.__index = Text

function Text.new()
  return setmetatable({ lines = {}, marks = {} }, Text)
end

---@param chunks string|{[1]: string, [2]: string?}[]
function Text:add(chunks)
  chunks = type(chunks) == "string" and { { chunks } } or chunks
  local line = ""
  for _, chunk in ipairs(chunks) do
    if chunk[2] then
      self.marks[#self.marks + 1] = { #self.lines, #line, #line + #chunk[1], chunk[2] }
    end
    line = line .. chunk[1]
  end
  self.lines[#self.lines + 1] = line
end

-- "22:59 (in 1h 58m)", with the day when it is not today.
local function resets(at)
  local now = os.time()
  local fmt = os.date("%Y%m%d", at) == os.date("%Y%m%d", now) and "%H:%M" or "%a %b %d %H:%M"
  local left = math.max(at - now, 0)
  local d, h, m = math.floor(left / 86400), math.floor(left % 86400 / 3600), math.floor(left % 3600 / 60)
  local rel = d > 0 and ("%dd %dh"):format(d, h) or h > 0 and ("%dh %dm"):format(h, m) or ("%dm"):format(m)
  return ("Resets %s (in %s)"):format(os.date(fmt, at), rel)
end

local function section(t, s)
  t:add({ { s.title, "Title" } })
  for _, line in ipairs(s.lines) do
    t:add("  " .. line)
  end
  t:add("")
end

local function render_usage(t, usage)
  section(t, usage.session)
  for _, limit in ipairs(usage.limits) do
    local percent = math.min(math.max(math.floor(limit.percent), 0), 100)
    local filled = math.floor(BAR * percent / 100 + 0.5)
    local group = percent >= 90 and "DiagnosticError" or percent >= 80 and "DiagnosticWarn" or "AnvimClaude"
    t:add({ { limit.title, "Title" } })
    t:add({
      { ("█"):rep(filled), group },
      { ("░"):rep(BAR - filled), "AnvimResult" },
      { (" %d%% used"):format(percent) },
    })
    if limit.resets_at then
      t:add({ { resets(limit.resets_at), "AnvimResult" } })
    end
    t:add("")
  end
  if #usage.limits == 0 then
    t:add({ { "Plan limits do not apply to this session.", "AnvimResult" } })
    t:add("")
  end
  for _, window in ipairs(usage.windows) do
    section(t, window)
  end
end

local function color(name)
  local agent = name:match("^(%a+)_FOR_SUBAGENTS_ONLY$")
  if agent then
    return "MiniIcons" .. (agent == "pink" and "Red" or agent:sub(1, 1):upper() .. agent:sub(2))
  end
  return COLORS[name] or "Comment"
end

-- The grid with its legend at the right, as in Claude Code, or under it when
-- the window is too narrow.
local function render_context(t, ctx)
  local legend = { { { ctx.title } }, {} }
  local widest = 0
  for _, row in ipairs(ctx.legend) do
    legend[#legend + 1] = { { row.glyph, color(row.color) }, { " " .. row.text, row.dim and "Comment" or nil } }
    widest = math.max(widest, 2 + api.nvim_strwidth(row.text))
  end
  widest = math.max(widest, api.nvim_strwidth(ctx.title))
  local grid_width = math.max(#(ctx.grid[1] or {}) * 2 - 1, 0)
  local inner = (valid() and api.nvim_win_get_width(win.win) or WIDTH + 2) - 2
  local side = grid_width + 3 + widest <= inner
  for r = 1, side and math.max(#ctx.grid, #legend) or #ctx.grid do
    local chunks = {}
    for c, mark in ipairs(ctx.grid[r] or {}) do
      chunks[#chunks + 1] = { (c > 1 and " " or "") .. mark.glyph, color(mark.color) }
    end
    if side and legend[r] and #legend[r] > 0 then
      chunks[#chunks + 1] = { (" "):rep(ctx.grid[r] and 3 or grid_width + 3) }
      vim.list_extend(chunks, legend[r])
    end
    t:add(chunks)
  end
  t:add("")
  if not side then
    for _, row in ipairs(legend) do
      t:add(row)
    end
    t:add("")
  end
  for _, s in ipairs(ctx.sections) do
    section(t, s)
  end
end

-- Claude Code's answer may lack a row, such as the organization of an API
-- key. While it loads, its rows show dots.
local function render_status(t, info)
  local model = require("anvim.input").model_label(state.model or require("anvim.config").options.model)
  local rows = {
    { "Version", info and info.version },
    { "Session ID", state.session_id },
    { "cwd", state.cwd and vim.fn.fnamemodify(state.cwd, ":~") },
    -- Claude Code's own dir, which tells a work login from a personal one.
    { "Config dir", vim.fn.fnamemodify(vim.env.CLAUDE_CONFIG_DIR or "~/.claude", ":~") },
    { "Login method", info and info.login },
    { "Organization", info and info.organization },
    { "Email", info and info.email },
    { "Model", model .. (state.effort and (" · " .. state.effort) or "") },
    { "MCP servers", info and info.mcp },
  }
  for _, row in ipairs(rows) do
    local value = row[2] or (not info and "...")
    if value then
      t:add({ { ("%-14s"):format(row[1]), "AnvimResult" }, { value } })
    end
  end
end

local function render()
  local t = Text.new()
  local ev = answers[tab]
  if ev and ev.error then
    t:add({ { "Claude Code did not answer: " .. ev.error, "DiagnosticError" } })
  elseif tab == "status" then
    render_status(t, ev and ev.info)
  elseif ev and tab == "usage" then
    render_usage(t, ev.usage)
  elseif ev then
    render_context(t, ev.context)
  else
    t:add({ { "Loading...", "AnvimResult" } })
  end
  if t.lines[#t.lines] == "" then
    t.lines[#t.lines] = nil
  end
  return t
end

local function title()
  local chunks = {}
  for _, name in ipairs(TABS) do
    chunks[#chunks + 1] = { " " .. NAMES[name] .. " ", name == tab and "AnvimChipSelected" or "FloatTitle" }
  end
  return chunks
end

local function draw()
  if not valid() then
    return
  end
  local buf = win.buf
  local t = render()
  -- A margin of one cell on each side, as in Claude Code's dialogs.
  for i, line in ipairs(t.lines) do
    t.lines[i] = line == "" and line or " " .. line
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(t.marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2] + 1, { end_col = m[3] + 1, hl_group = m[4] })
  end
  win:set_title(title())
  local height = api.nvim_win_text_height(win.win, {}).all
  win.opts.height = math.max(math.min(height, vim.o.lines - 4), 1)
  win:update()
  api.nvim_win_set_cursor(win.win, { 1, 0 })
end

local function request()
  answers[tab] = nil
  sidecar.send({ type = REQUESTS[tab] })
end

---@param step integer 1 for the next tab, -1 for the one before.
function M.switch(step)
  local i = vim.fn.index(TABS, tab) + 1
  tab = TABS[(i + step - 1) % #TABS + 1]
  if answers[tab] == nil then
    request()
  end
  draw()
end

function M.close()
  if valid() then
    win:close()
  end
end

---@param name "status"|"usage"|"context"
function M.open(name)
  if not sidecar.running() then
    vim.notify("anvim: Claude is not running. :AnvimRestart starts it", vim.log.levels.WARN)
    return
  end
  tab, answers = name, {}
  if not valid() then
    win = Snacks.win({
      position = "float",
      border = "rounded",
      title = title(),
      footer = { { " <Tab> next tab · q close ", "FloatFooter" } },
      width = function()
        return math.min(WIDTH + 2, vim.o.columns - 4)
      end,
      height = 1,
      enter = true,
      backdrop = false,
      zindex = Snacks.win.zindex(20),
      bo = { filetype = "anvim_settings", modifiable = false },
      wo = { wrap = true, linebreak = true, breakindent = true, cursorline = false, winbar = "", list = false },
      keys = { q = false },
      on_close = function()
        win = nil
      end,
    })
    for _, key in ipairs({ "q", "<Esc>" }) do
      keys.set("settings", "n", key, M.close, { buffer = win.buf, nowait = true })
    end
    keys.set("settings", "n", "<Tab>", function()
      M.switch(1)
    end, { buffer = win.buf, nowait = true })
    keys.set("settings", "n", "<S-Tab>", function()
      M.switch(-1)
    end, { buffer = win.buf, nowait = true })
    -- A click or a window key elsewhere closes it, as it closes the key view.
    win:on("WinLeave", function(self)
      vim.schedule(function()
        if self:valid() and api.nvim_get_current_win() ~= self.win then
          self:close()
        end
      end)
    end, { buf = true })
  end
  win:focus()
  -- The prompt's <CR> sent the command from insert mode.
  vim.cmd.stopinsert()
  request()
  draw()
end

function M.attach()
  sidecar.on("account", function(ev)
    state.email = ev.email
    require("anvim.statusline").refresh()
  end)
  for name, type in pairs(REQUESTS) do
    sidecar.on(type, function(ev)
      answers[name] = ev
      if name == tab then
        draw()
      end
    end)
  end
end

return M
