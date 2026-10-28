-- anvim's todo list. The sidecar keeps it in a file per project, Claude fills
-- it with the todo_ tools, and each change comes as a todos event.
local M = {}

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

---@param items anvim.TodoItem[]
function M.set(items)
  M.items = type(items) == "table" and items or {}
  require("anvim.transcript").todos(M.items)
end

function M.attach(sidecar)
  sidecar.on("todos", function(ev)
    M.set(ev.items)
  end)
end

return M
