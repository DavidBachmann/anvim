-- anvim's todo list. The sidecar keeps it in a file per project, Claude fills
-- it with the todo_ tools, and each change comes as a todos event.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.todos")
---@type integer?
local bufnr

---@class anvim.TodoItem
---@field id integer
---@field subject string
---@field description string?
---@field active_form string?
---@field status 'pending'|'in_progress'|'completed'
---@field owner string?
---@field blocked_by integer[]?

---@type anvim.TodoItem[] In id order.
M.items = {}

-- The transcript draws no tool line for these, and the tool pane does not count them.
M.tools = { mcp__anvim__todo_add = true, mcp__anvim__todo_update = true, mcp__anvim__todo_list = true }

M.dir = vim.fn.stdpath("state") .. "/todos"

function M.path()
  return require("anvim.paths").project_file(M.dir)
end

---@param item anvim.TodoItem
function M.is_open(item)
  return item.status ~= "completed"
end

-- The blockers that are not done yet.
local function blockers(item, items)
  local open = {}
  for _, id in ipairs(type(item.blocked_by) == "table" and item.blocked_by or {}) do
    for _, other in ipairs(items) do
      if other.id == id and M.is_open(other) then
        open[#open + 1] = "#" .. id
        break
      end
    end
  end
  return open
end

-- The rows of the list: a box, the id and the subject. Each mark is
-- { row, col, end_col, group }, with rows from 0.
---@param items anvim.TodoItem[]
---@param lead? fun(i: integer): string The text before the box of row i.
---@return string[] lines, table[] marks
function M.render(items, lead)
  local lines, marks = {}, {}
  for i, item in ipairs(items) do
    local row, done = i - 1, item.status == "completed"
    local before = (lead and lead(i) or "") .. (done and "☒ " or "☐ ")
    local id = "#" .. tostring(item.id)
    local line = before .. id .. " " .. tostring(item.subject or ""):gsub("\n", " ")
    marks[#marks + 1] = { row, #before, #before + #id, "AnvimResult" }
    local group = done and "AnvimTodoDone" or item.status == "in_progress" and "AnvimTodoActive" or nil
    if group then
      marks[#marks + 1] = { row, #before + #id + 1, #line, group }
    end
    local blocked = not done and blockers(item, items) or {}
    if #blocked > 0 then
      local tail = "  blocked by " .. table.concat(blocked, ", ")
      marks[#marks + 1] = { row, #line, #line + #tail, "AnvimResult" }
      line = line .. tail
    end
    lines[#lines + 1] = line
  end
  return lines, marks
end

-- What the main agent does: the item in progress that no agent owns.
---@return string?
function M.active()
  for _, item in ipairs(M.items) do
    if item.status == "in_progress" and not item.owner then
      local text = item.active_form or item.subject
      return text ~= "" and text or nil
    end
  end
end

-- The rows of the todo window. Its winbar is the header.
local function draw()
  local lines, marks = M.render(M.items, function()
    return "  "
  end)
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(bufnr, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

-- The todo window's buffer. It follows the list also while the window does
-- not show, so the window opens with its rows in place.
function M.buf()
  if bufnr and api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].anvim_todos then
    return bufnr
  end
  -- :bdelete keeps the buffer and its name, but clears its options.
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr = api.nvim_create_buf(false, true)
  vim.b[bufnr].anvim_todos = true
  require("anvim.windows").stop_at_end(bufnr)
  pcall(api.nvim_buf_set_name, bufnr, "anvim://todos")
  vim.bo[bufnr].filetype = "anvim_todos"
  draw()
  return bufnr
end

function M.winbar()
  local done = #vim.tbl_filter(function(item)
    return not M.is_open(item)
  end, M.items)
  return ("  %%#AnvimToolName#Todos%%#AnvimResult# · %d of %d done%%*"):format(done, #M.items)
end

-- The view starts at the first open item, so done items scroll out of
-- sight in a long list. Without one, it shows the end.
function M.view(win)
  local row = #M.items
  for i, item in ipairs(M.items) do
    if M.is_open(item) then
      row = i
      break
    end
  end
  row = math.max(row, 1)
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = row, topfill = 0, skipcol = 0, lnum = row, col = 0 })
  end)
  require("anvim.windows").clamp(win)
end

-- Draws the list in the todo window's buffer, then shows the window or the
-- list in the transcript, in one tick.
---@param items anvim.TodoItem[]
function M.set(items)
  M.items = type(items) == "table" and items or {}
  M.buf()
  draw()
  require("anvim.layout").sync_todos()
end

-- The items that the transcript shows: none while the todo window shows them.
---@return anvim.TodoItem[]
function M.inline()
  return require("anvim.layout").todos_shown() and {} or M.items
end

function M.attach(sidecar)
  sidecar.on("todos", function(ev)
    M.set(ev.items)
  end)
end

return M
