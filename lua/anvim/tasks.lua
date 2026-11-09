-- The background tasks other than agents, such as a shell from Bash with
-- run_in_background, and the session's scheduled prompts from CronCreate,
-- ScheduleWakeup and /loop. The prompt footer counts them, and /tasks lists
-- them. Both end with Claude Code's process, so a restart empties the lists.
local keys = require("anvim.keys")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.tasks")
local NONE = "No background task runs, and no prompt is scheduled."

---@class anvim.Task
---@field id string
---@field kind string Claude Code's short name for the task's type, such as "shell".
---@field description string
---@field since integer os.time() when the list first had the task.

---@class anvim.Cron
---@field id string
---@field schedule string A cron expression in local time.
---@field recurring boolean
---@field prompt string

---@type anvim.Task[]
local tasks = {}
---@type anvim.Cron[]
local crons = {}
---@type snacks.win?
local win
-- The line about what the last restart ended, until the new session's first
-- turn. A resumed session's history clears the transcript, which loses it.
---@type string?
local ended

---@return integer
function M.count()
  return #tasks + #crons
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local function fit(text, width)
  return vim.fn.strdisplaywidth(text) > width and vim.fn.strcharpart(text, 0, width - 1) .. "\226\128\166" or text
end

-- A prompt that fires once has a schedule such as "55 21 9 11 *". Its time,
-- with the day when it is not today.
---@param schedule string
---@return string
local function fires(schedule)
  local min, hour, day, month = schedule:match("^(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+%*$")
  if not min then
    return schedule
  end
  local t = os.time({
    year = tonumber(os.date("%Y")) --[[@as integer]],
    month = tonumber(month) --[[@as integer]],
    day = tonumber(day) --[[@as integer]],
    hour = tonumber(hour),
    min = tonumber(min),
  })
  local today = os.date("%Y-%m-%d", t) == os.date("%Y-%m-%d")
  return "at " .. os.date(today and "%H:%M" or "%d %b %H:%M", t)
end

-- One row for each task, then one for each scheduled prompt: its kind, what
-- it does, and when it started or fires.
---@return { kind: string, text: string, time: string }[]
local function rows()
  local out = {}
  for _, t in ipairs(tasks) do
    out[#out + 1] = { kind = t.kind, text = t.description, time = "since " .. os.date("%H:%M", t.since) }
  end
  for _, c in ipairs(crons) do
    out[#out + 1] = { kind = "prompt", text = c.prompt, time = c.recurring and c.schedule or fires(c.schedule) }
  end
  return out
end

local function draw()
  if not (win and win:valid()) then
    return
  end
  local width = api.nvim_win_get_width(win.win)
  local list = rows()
  local kind_width = 0
  for _, r in ipairs(list) do
    kind_width = math.max(kind_width, vim.fn.strdisplaywidth(r.kind))
  end
  local lines, marks = {}, {}
  for i, r in ipairs(list) do
    local kind = r.kind .. (" "):rep(kind_width - vim.fn.strdisplaywidth(r.kind)) .. "  "
    local time = "  " .. r.time
    local room = math.max(width - vim.fn.strdisplaywidth(kind .. time), 10)
    local text = fit((vim.trim(r.text):gsub("%s*\n.*", "...")), room)
    local pad = (" "):rep(room - vim.fn.strdisplaywidth(text))
    local line = kind .. text .. pad .. time
    lines[i] = line
    marks[#marks + 1] = { i - 1, 0, #kind, "AnvimChip" }
    marks[#marks + 1] = { i - 1, #line - #time, #line, "AnvimTime" }
  end
  if #lines == 0 then
    lines[1] = NONE
    marks[1] = { 0, 0, #lines[1], "Comment" }
  end
  local buf = win.buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  win.opts.title = (" Tasks · %d "):format(M.count())
  win.opts.height = math.max(math.min(#lines, math.floor(vim.o.lines * 0.6)), 1)
  win:update()
end

local function changed()
  draw()
  require("anvim.input").render()
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
  local open = M.get()
  if open then
    open:focus()
    return
  end
  if M.count() == 0 then
    transcript.notice("info", NONE)
    return
  end
  win = Snacks.win({
    position = "float",
    border = "rounded",
    footer = { { " q close ", "FloatFooter" } },
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
      win = nil
    end,
  })
  local buf = win.buf
  vim.bo[buf].filetype = "anvim_tasks"
  for _, key in ipairs({ "q", "<Esc>" }) do
    keys.set("tasks", "n", key, M.close, { buffer = buf, nowait = true })
  end
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
end

---@param ev { tasks: { id: string, kind: string, description: string }[] }
function M.set_tasks(ev)
  local since = {}
  for _, t in ipairs(tasks) do
    since[t.id] = t.since
  end
  tasks = {}
  for _, t in ipairs(ev.tasks or {}) do
    tasks[#tasks + 1] = { id = t.id, kind = t.kind, description = t.description, since = since[t.id] or os.time() }
  end
  changed()
end

---@param ev { crons: anvim.Cron[] }
function M.set_crons(ev)
  crons = ev.crons or {}
  changed()
end

-- sessions.history() calls it once it has drawn the history.
function M.after_history()
  if ended then
    transcript.notice("info", ended)
    ended = nil
  end
end

function M.attach()
  sidecar.on("tasks", M.set_tasks)
  sidecar.on("crons", M.set_crons)
  -- Claude Code's process ends its tasks and its scheduled prompts.
  sidecar.on("exit", function(ev)
    ended = nil
    if M.count() == 0 then
      return
    end
    if ev.restart then
      local parts = {}
      if #tasks > 0 then
        parts[#parts + 1] = plural(#tasks, "background task")
      end
      if #crons > 0 then
        parts[#parts + 1] = plural(#crons, "scheduled prompt")
      end
      ended = ("The restart ended %s."):format(table.concat(parts, " and "))
      transcript.notice("info", ended)
    end
    tasks, crons = {}, {}
    changed()
  end)
  sidecar.on("init", function()
    ended = nil
  end)
end

return M
