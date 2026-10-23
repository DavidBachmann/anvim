-- Claude Code's Settings dialog in a float, with Status, Usage, Context and
-- MCP tabs. /status, /usage, /context and /mcp open it. Claude Code's /usage,
-- /context and /mcp in the SDK print text, which would go into Claude's
-- context, and its /status does not run there.
local keys = require("anvim.keys")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.settings")
-- Room for the context grid and its legend side by side.
local WIDTH = 88
local BAR = 50
local TABS = { "status", "usage", "context", "mcp" }
local NAMES = { status = "Status", usage = "Usage", context = "Context", mcp = "MCP" }
-- The request that answers each tab.
local REQUESTS = { status = "session_info", usage = "usage", context = "context_usage", mcp = "mcp_servers" }
local STATUS = {
  connected = { "✔", "DiagnosticOk", "connected" },
  failed = { "✗", "DiagnosticError", "failed" },
  ["needs-auth"] = { "△", "DiagnosticWarn", "needs sign-in" },
  pending = { "◌", "Comment", "connecting" },
  disabled = { "○", "Comment", "off" },
}
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
---@type "status"|"usage"|"context"|"mcp"
local tab = "status"
-- The tab that the window showed last.
local drawn
-- The answers since the window opened, by tab: the event, or nil while it loads.
---@type table<string, table>
local answers = {}
-- The MCP servers that show their tools, the server of each line (0-based),
-- and what the tab says over its list.
local expanded = {} ---@type table<string, true>
local server_rows = {} ---@type table<integer, string>
local note ---@type [string, string]?

local function valid()
  return win ~= nil and win:valid()
end

---@class anvim.SettingsText
---@field lines string[]
---@field marks table[] { row, col, end_col, group }
local Text = {}
Text.__index = Text

function Text.new()
  return setmetatable({ lines = {}, marks = {}, servers = {}, heads = {} }, Text)
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

-- One line for each server, as in Claude Code's /mcp. <CR> shows what a
-- server runs and its tools under it.
local function render_mcp(t, ev)
  if note or ev.error then
    t:add({ note or { ev.error, "DiagnosticError" } })
    t:add("")
  end
  local wide = 0
  for _, s in ipairs(ev.servers) do
    wide = math.max(wide, math.min(api.nvim_strwidth(s.name), 32))
  end
  for _, s in ipairs(ev.servers) do
    local st = STATUS[s.status] or { "?", "Comment", s.status }
    local words = st[3]
    if s.status == "connected" then
      words = ("%s · %d tool%s"):format(words, #s.tools, #s.tools == 1 and "" or "s")
    end
    t.heads[s.name] = #t.lines
    t.servers[#t.lines] = s.name
    t:add({
      { st[1], st[2] },
      { " " .. s.name .. (" "):rep(math.max(wide - api.nvim_strwidth(s.name), 0) + 2) },
      { words, st[2] },
      { s.scope and ("  " .. s.scope) or "", "Comment" },
    })
    if expanded[s.name] then
      local function more(text, group)
        t.servers[#t.lines] = s.name
        t:add({ { "    " .. text, group or "AnvimResult" } })
      end
      if s.own then
        more("anvim's editor tools, which always run")
      end
      if s.where then
        more(s.where)
      end
      if s.error then
        more(s.error, "DiagnosticError")
      end
      if s.status == "needs-auth" then
        more("Sign in with /mcp in Claude Code's terminal.", "DiagnosticWarn")
      end
      for _, tool in ipairs(s.tools) do
        more(tool)
      end
    end
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
  if ev and ev.error and not ev.servers then
    t:add({ { "Claude Code did not answer: " .. ev.error, "DiagnosticError" } })
  elseif tab == "status" then
    render_status(t, ev and ev.info)
  elseif ev and tab == "usage" then
    render_usage(t, ev.usage)
  elseif ev and tab == "context" then
    render_context(t, ev.context)
  elseif ev then
    render_mcp(t, ev)
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

-- The server of the line under the cursor, in the MCP tab.
local function server_at_cursor()
  if tab ~= "mcp" or not valid() or drawn ~= "mcp" then
    return
  end
  local name = server_rows[api.nvim_win_get_cursor(win.win)[1] - 1]
  for _, s in ipairs(answers.mcp and answers.mcp.servers or {}) do
    if s.name == name then
      return s
    end
  end
end

local function draw()
  if not valid() then
    return
  end
  local buf = win.buf
  -- The cursor stays on its server when the list changes.
  local keep = server_at_cursor()
  local t = render()
  server_rows = t.servers
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
  win.opts.title = title()
  local keys_hint = tab == "mcp" and "<CR> tools · r reconnect · t on or off · " or ""
  win.opts.footer = { { " " .. keys_hint .. "<Tab> next tab · q close ", "FloatFooter" } }
  win.opts.wo.cursorline = tab == "mcp"
  local height = api.nvim_win_text_height(win.win, {}).all
  win.opts.height = math.max(math.min(height, vim.o.lines - 4), 1)
  win:update()
  local row = keep and t.heads[keep.name]
  if not row and drawn == tab then
    row = math.min(api.nvim_win_get_cursor(win.win)[1], #t.lines) - 1
  end
  if not row then
    row = next(t.heads) and math.huge or 0
    for _, head in pairs(t.heads) do
      row = math.min(row, head)
    end
  end
  api.nvim_win_set_cursor(win.win, { row + 1, 0 })
  drawn = tab
end

local function request()
  answers[tab] = nil
  sidecar.send({ type = REQUESTS[tab] })
end

-- <CR> in the MCP tab: shows or hides the server's tools.
function M.tools()
  local s = server_at_cursor()
  if s then
    expanded[s.name] = not expanded[s.name] or nil
    draw()
  end
end

---@param action "reconnect"|"enable"|"disable"
local function act(action, s)
  if s.own then
    note = { "anvim's own server always runs.", "DiagnosticWarn" }
  else
    local verb = ({ reconnect = "Reconnecting", enable = "Turning on", disable = "Turning off" })[action]
    note = { ("%s %s..."):format(verb, s.name), "AnvimResult" }
    sidecar.send({ type = "mcp_action", action = action, server = s.name })
  end
  draw()
end

function M.reconnect()
  local s = server_at_cursor()
  if s then
    act("reconnect", s)
  end
end

function M.toggle()
  local s = server_at_cursor()
  if s then
    act(s.status == "disabled" and "enable" or "disable", s)
  end
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

---@param name "status"|"usage"|"context"|"mcp"
function M.open(name)
  if not sidecar.running() then
    vim.notify("anvim: Claude is not running. :AnvimRestart starts it", vim.log.levels.WARN)
    return
  end
  tab, answers, drawn, note = name, {}, nil, nil
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
    keys.set("settings", "n", "<CR>", M.tools, { buffer = win.buf, nowait = true })
    keys.set("settings", "n", "r", M.reconnect, { buffer = win.buf, nowait = true })
    keys.set("settings", "n", "t", M.toggle, { buffer = win.buf, nowait = true })
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
      if name == "mcp" then
        note = nil
      end
      if name == tab then
        draw()
      end
    end)
  end
end

return M
