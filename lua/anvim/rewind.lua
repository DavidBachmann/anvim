-- /rewind: restores the code, the conversation or both to their state
-- before one of the user's earlier prompts.
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

---@class anvim.RewindPoint
---@field uuid string
---@field text string
---@field time integer? seconds since the epoch
---@field before string? the chain entry to resume at, absent for the first prompt

---@type fun(ev: table)?
local on_points
---@type fun(ev: table)?
local on_files
-- A notice that waits for the resumed session's history, which clears the transcript.
---@type string?
local after_history

local function first_line(text)
  return vim.trim(text):match("^[^\n]*")
end

-- The newest prompt comes first.
---@param points anvim.RewindPoint[]
function M.items(points)
  local items = {}
  for i = #points, 1, -1 do
    local p = points[i]
    items[#items + 1] = {
      idx = #items + 1,
      text = first_line(p.text),
      point = p,
      ago = p.time and require("anvim.sessions").ago(p.time * 1000) or "",
      preview = { text = p.text, ft = "markdown" },
    }
  end
  return items
end

local function format(item)
  return { { ("%-12s"):format(item.ago), "SnacksPickerComment" }, { " " }, { item.text } }
end

---@param items table[]
function M.show_picker(items)
  Snacks.picker.pick({
    source = "anvim_rewind",
    title = "Rewind to before a prompt",
    items = items,
    format = format,
    preview = "preview",
    layout = { preset = "select", hidden = {} },
    main = { current = true },
    confirm = function(picker, item)
      picker:close()
      if item then
        M.pick(item.point)
      end
    end,
  })
end

-- A restart ends running agents, and an agent can edit files while the code
-- goes back.
local function working()
  if state.busy or #require("anvim.agents").running() > 0 then
    transcript.notice("info", "Claude is working. Rewind once Claude and its agents are done, or stop Claude first.")
    return true
  end
  return false
end

function M.open()
  if working() then
    return
  elseif not sidecar.running() then
    vim.notify("anvim: Claude is not running. :AnvimRestart starts it", vim.log.levels.WARN)
    return
  elseif not state.session_id or (state.turns or 0) == 0 then
    transcript.notice("info", "There is nothing to rewind yet.")
    return
  end
  on_points = function(ev)
    if ev.error then
      transcript.notice("warn", "Could not read the session's prompts: " .. ev.error)
    elseif #(ev.points or {}) == 0 then
      transcript.notice("info", "There is nothing to rewind yet.")
    else
      M.show_picker(M.items(ev.points))
    end
  end
  sidecar.send({ type = "rewind_points", session_id = state.session_id, at = state.resume_at })
end

-- A dry run tells the menu what a code restore changes.
---@param point anvim.RewindPoint
function M.pick(point)
  on_files = function(ev)
    M.show_menu(point, ev)
  end
  sidecar.send({ type = "rewind_files", uuid = point.uuid, dry_run = true })
end

---@param dry table the dry run's rewind_files event
---@return { choice: string, label: string }[]
function M.choices(dry)
  local n = #(dry.files or {})
  local code = dry.can_rewind and n > 0
  local changes = code
      and ("  (+%d -%d in %d file%s)"):format(dry.insertions or 0, dry.deletions or 0, n, n == 1 and "" or "s")
    or ""
  local choices = {}
  if code then
    choices[#choices + 1] = { choice = "both", label = "Restore code and conversation" .. changes }
  end
  choices[#choices + 1] = { choice = "conversation", label = "Restore conversation" }
  if code then
    choices[#choices + 1] = { choice = "code", label = "Restore code" .. changes }
  end
  choices[#choices + 1] = { choice = "cancel", label = "Never mind" }
  return choices
end

---@param point anvim.RewindPoint
---@param dry table
function M.show_menu(point, dry)
  -- Snacks cuts a long title from the left, which would lose its start.
  local text = first_line(point.text)
  if vim.fn.strchars(text) > 50 then
    text = vim.fn.strcharpart(text, 0, 49) .. "..."
  end
  vim.ui.select(M.choices(dry), {
    prompt = "Rewind to before: " .. text,
    format_item = function(c)
      return c.label
    end,
  }, function(c)
    if c and c.choice ~= "cancel" then
      M.restore(point, c.choice, dry.files)
    end
  end)
end

-- A file that the restore deleted would keep its old text on screen, so its
-- buffer goes, and the code window shows a file of the tab bar.
---@param files string[]?
local function drop_gone(files)
  local real = require("anvim.files").real
  local gone = {}
  for _, path in ipairs(files or {}) do
    if not vim.uv.fs_stat(path) then
      gone[real(path)] = true
    end
  end
  if next(gone) == nil then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local file = require("anvim.paths").file(buf)
    if file and gone[real(file)] then
      Snacks.bufdelete({ buf = buf, force = true, wipe = true })
    end
  end
  require("anvim.tabs").show_first()
end

-- Puts the prompt's text back in the prompt window, so the user can change
-- it and send it again. Insert mode does not start.
local function put(text)
  local buf = require("anvim.input").buf()
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  end
end

---@param point anvim.RewindPoint
---@param notice string
local function conversation(point, notice)
  require("anvim.sessions").rewind(point.before)
  if point.before then
    after_history = notice
  else
    transcript.notice("info", notice)
  end
  put(point.text)
end

-- The code goes first, on the running session, which holds the checkpoints.
---@param point anvim.RewindPoint
---@param choice "both"|"conversation"|"code"
---@param files string[]? The files that the dry run named.
function M.restore(point, choice, files)
  -- An agent can start while the menu is open.
  if working() then
    return
  elseif choice == "conversation" then
    return conversation(point, "Rewound the conversation.")
  end
  on_files = function(ev)
    if not ev.can_rewind then
      transcript.notice("error", "Could not restore the code: " .. (ev.error or "no checkpoint for this prompt"))
      return
    end
    require("anvim.readonly").reload()
    drop_gone(files)
    local notice = choice == "both" and "Rewound the code and the conversation." or "Rewound the code."
    local skipped = ev.skipped or 0
    if skipped > 0 then
      local what = skipped == 1 and "1 file is" or (skipped .. " files are")
      notice = notice .. (" %s not restored, because a link is at its path."):format(what)
    end
    if choice == "both" then
      conversation(point, notice)
    else
      transcript.notice("info", notice)
    end
  end
  sidecar.send({ type = "rewind_files", uuid = point.uuid })
end

function M.attach()
  sidecar.on("rewind_points", function(ev)
    local cb = on_points
    on_points = nil
    if cb and ev.session_id == state.session_id then
      cb(ev)
    end
  end)
  sidecar.on("rewind_files", function(ev)
    local cb = on_files
    on_files = nil
    if cb then
      cb(ev)
    end
  end)
  -- After sessions.lua's handler, which draws the transcript again.
  sidecar.on("history", function()
    if after_history then
      transcript.notice("info", after_history)
      after_history = nil
    end
  end)
  -- The history comes before the session's init. Without a history, such
  -- as when the session is missing, the notice would show after a later one.
  local function drop()
    after_history = nil
  end
  sidecar.on("init", drop)
  sidecar.on("exit", drop)
end

return M
