-- Away mode and the held list. While the user is away, the sidecar answers
-- each request for them (sidecar/src/away.ts): it holds the calls that would
-- ask, and Claude answers its own questions. A subagent's guarded calls are
-- held while the user is present too. The held list is a log of this anvim,
-- which nothing needs to clear: /held shows it, and the statusline counts
-- the entries that the user has not seen yet.
local agents = require("anvim.agents")
local config = require("anvim.config")
local keys = require("anvim.keys")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.held")
local TIMES = "\195\151"

---@type boolean The user is away.
M.on = false

---@class anvim.Held
---@field ev table The held event.
---@field who string The agent's name when the call came.
---@field task string? The agent's task.
---@field seen boolean?

---@type anvim.Held[]
local entries = {}
-- The entries before away mode last turned on.
local since = 0
---@type snacks.win?
local win
-- The entries that were new when the float opened, or came while it is open.
---@type table<anvim.Held, true>
local bright = {}
---@type { entries: anvim.Held[] }[] The float's rows, by line.
local rows = {}

local function refresh()
  require("anvim.statusline").refresh()
end

-- The minutes that a request may wait before away mode turns on. 0 is never.
---@return integer
function M.after()
  local after = config.options.away_after
  return type(after) == "number" and math.max(after, 0) or 0
end

---@return integer
function M.unseen()
  local n = 0
  for _, e in ipairs(entries) do
    n = n + (e.seen and 0 or 1)
  end
  return n
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- The transcript line when the user is back. The counts are what away held.
local function report()
  local calls, questions = 0, 0
  for i = since + 1, #entries do
    local ev = entries[i].ev
    if ev.away and ev.tool == "AskUserQuestion" then
      questions = questions + 1
    elseif ev.away then
      calls = calls + 1
    end
  end
  local parts = {}
  if calls > 0 then
    parts[#parts + 1] = "anvim held " .. plural(calls, "call")
  end
  if questions > 0 then
    parts[#parts + 1] = ("Claude answered %s itself"):format(plural(questions, "question"))
  end
  if #parts == 0 then
    transcript.notice("info", "Nothing waited for you while you were away.")
  else
    transcript.notice("info", ("While you were away, %s. /held shows them."):format(table.concat(parts, ", and ")))
  end
end

---@param on boolean
function M.set(on)
  if on == M.on then
    return
  end
  M.on = on
  sidecar.send({ type = "set_away", away = on })
  if on then
    since = #entries
  else
    report()
    for _, e in ipairs(entries) do
      e.seen = true
    end
  end
  refresh()
end

function M.toggle()
  M.set(not M.on)
end

-- The fields of the sidecar's start command, so that a restart keeps the state.
function M.start_fields()
  return { away = M.on, away_after = M.after() }
end

---@param e anvim.Held
local function text_of(e)
  local ev = e.ev
  local text = type(ev.description) == "string" and vim.trim(ev.description) ~= "" and ev.description or ev.target
  return (vim.trim(text or ""):gsub("%s*\n.*", "..."))
end

-- Repeats make one row: the same agent, tool and target. Newest first.
local function groups()
  local by, list = {}, {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    local key = table.concat({ e.ev.agent_id or "", e.ev.tool, e.ev.target or "" }, "\0")
    local g = by[key]
    if not g then
      g = { entries = {} }
      by[key] = g
      list[#list + 1] = g
    end
    table.insert(g.entries, e)
  end
  return list
end

local function fit(text, width)
  return vim.fn.strdisplaywidth(text) > width and vim.fn.strcharpart(text, 0, width - 1) .. "\226\128\166" or text
end

local function draw()
  if not (win and win:valid()) then
    return
  end
  local width = api.nvim_win_get_width(win.win)
  local lines, marks = {}, {}
  rows = groups()
  for i, g in ipairs(rows) do
    local e = g.entries[1]
    local dim = true
    for _, other in ipairs(g.entries) do
      dim = dim and not bright[other]
    end
    local head = ("%s  %-12s "):format(os.date("%H:%M", e.ev.time), fit(e.who, 12))
    local count = #g.entries > 1 and ("  %s%d"):format(TIMES, #g.entries) or ""
    local reason = "  " .. e.ev.reason
    local room = math.max(width - vim.fn.strdisplaywidth(head .. count .. reason), 10)
    local what = fit(text_of(e), room)
    local line = head .. what .. count .. reason
    lines[i] = line
    local row = i - 1
    if dim then
      marks[#marks + 1] = { row, 0, #line, "Comment" }
    else
      marks[#marks + 1] = { row, 0, 5, "AnvimTime" }
      marks[#marks + 1] = { row, #line - #reason, #line, "Comment" }
    end
  end
  local buf = win.buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  win.opts.title = (" Held · %d "):format(#entries)
  win.opts.height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.6)), 1)
  win:update()
end

-- The prompt text of a row: who, when, why and what, for Claude to run again.
local function prompt_text(g)
  local e = g.entries[1]
  local ev = e.ev
  local who = e.task and ("%s (%s)"):format(e.who, e.task) or e.who
  local times = #g.entries > 1 and (", %d times"):format(#g.entries) or ""
  local at = os.date("%H:%M", ev.time)
  local target = vim.trim(ev.target or "")
  local block = target:find("\n") and { "```", target, "```" } or { "`" .. target .. "`" }
  local first
  if ev.tool == "AskUserQuestion" then
    first = ("At %s, %s asked me this while I was away, so it chose the answer itself%s:"):format(at, who, times)
  else
    first = ("At %s, anvim held this %s call of %s (%s%s). Run it again if it is still needed:"):format(
      at,
      ev.tool,
      who,
      ev.reason,
      times
    )
  end
  return vim.list_extend({ first }, vim.split(table.concat(block, "\n"), "\n", { plain = true }))
end

-- Puts the rows from `first` to `last` in the prompt, after what it holds,
-- and leaves the cursor there in normal mode.
local function put(first, last)
  local chosen = {}
  for i = first, last do
    if rows[i] then
      chosen[#chosen + 1] = rows[i]
    end
  end
  if #chosen == 0 then
    return
  end
  local lines = {}
  for i, g in ipairs(chosen) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, prompt_text(g))
  end
  M.close()
  local buf = require("anvim.input").buf()
  local old = api.nvim_buf_get_lines(buf, 0, -1, false)
  local empty = vim.trim(table.concat(old, "\n")) == ""
  if empty then
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    api.nvim_buf_set_lines(buf, -1, -1, false, vim.list_extend({ "" }, lines))
  end
  local layout = require("anvim.layout")
  layout.focus_input({ insert = false })
  if layout.wins.input and api.nvim_win_is_valid(layout.wins.input) then
    api.nvim_win_set_cursor(layout.wins.input, { api.nvim_buf_line_count(buf), 0 })
  end
end

function M.put_line()
  if win and win:valid() then
    local row = api.nvim_win_get_cursor(win.win)[1]
    put(row, row)
  end
end

function M.put_visual()
  if win and win:valid() then
    local a, b = api.nvim_buf_get_mark(win.buf, "<")[1], api.nvim_buf_get_mark(win.buf, ">")[1]
    put(math.min(a, b), math.max(a, b))
  end
end

function M.close()
  if win and win:valid() then
    win:close()
  end
end

---@return snacks.win?
function M.get()
  return win and win:valid() and win or nil
end

function M.open()
  if M.get() then
    win:focus()
    return
  end
  if #entries == 0 then
    transcript.notice("info", "anvim has held nothing yet.")
    return
  end
  bright = {}
  for _, e in ipairs(entries) do
    if not e.seen then
      bright[e] = true
    end
    e.seen = true
  end
  win = Snacks.win({
    position = "float",
    border = "rounded",
    footer = { { " \226\143\142 put in the prompt \194\183 q close ", "FloatFooter" } },
    width = function()
      return math.min(100, vim.o.columns - 4)
    end,
    height = 1,
    enter = true,
    backdrop = false,
    zindex = Snacks.win.zindex(20),
    bo = { modifiable = false },
    wo = { wrap = false, cursorline = true, winbar = "", list = false },
    keys = { q = false },
    on_close = function()
      win, rows, bright = nil, {}, {}
    end,
  })
  local buf = win.buf
  vim.bo[buf].filetype = "anvim_held"
  for _, key in ipairs({ "q", "<Esc>" }) do
    keys.set("held", "n", key, M.close, { buffer = buf, nowait = true })
  end
  keys.set("held", "n", "<CR>", M.put_line, { buffer = buf, nowait = true })
  keys.set("held", "x", "<CR>", "<Esc><Cmd>lua require('anvim.away').put_visual()<CR>", { buffer = buf })
  -- A click or a window key elsewhere closes it, as it closes the key view.
  win:on("WinLeave", function(self)
    vim.schedule(function()
      if self:valid() and api.nvim_get_current_win() ~= self.win then
        self:close()
      end
    end)
  end, { buf = true })
  vim.cmd.stopinsert()
  draw()
  refresh()
end

function M.held(ev)
  local agent = ev.agent_id and agents.get(ev.agent_id)
  local who = agent and agents.name(agent) or ev.agent_id and "Subagent" or "Claude"
  local task = agent and agent.description ~= "" and agent.description or nil
  ---@type anvim.Held
  local e = { ev = ev, who = who, task = task }
  entries[#entries + 1] = e
  if M.get() then
    bright[e], e.seen = true, true
    draw()
  end
  refresh()
end

function M.attach()
  sidecar.on("held", M.held)
  -- The sidecar turned away mode on, because a request waited.
  sidecar.on("away", function(ev)
    if M.on then
      return
    end
    M.on, since = true, #entries
    local after = tonumber(ev.after) or M.after()
    transcript.notice(
      "info",
      ("anvim turned away on, because a request waited %s. /away turns it off."):format(plural(after, "minute"))
    )
    refresh()
  end)
end

return M
