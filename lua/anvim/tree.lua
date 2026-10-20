-- The explorer's width. Without focus, it keeps the narrow width of its split.
-- With focus, its list widens over the code window to fit its rows, like a
-- drawer, and the code window keeps its place.
local config = require("anvim.config")
local layout = require("anvim.layout")

local M = {}

local api = vim.api
-- Rows to measure at most, for a tree with large folders open.
local MAX_ROWS = 2000

local pending = false
local scheduled = false

---@return snacks.Picker?
function M.explorer()
  local ok, snacks = pcall(require, "snacks")
  local picker = ok and snacks.picker and snacks.picker.get({ source = "explorer" })[1]
  if picker and not picker.closed and picker.layout.root:win_valid() and picker.list.win:win_valid() then
    return picker
  end
end

-- The columns of a row: its text and the git status at its right edge. The
-- tree's guides lie over the indent.
local function row_width(list, item)
  local text, extmarks = list:format(item)
  local width = api.nvim_strwidth((text:gsub("%s+$", "")))
  for _, mark in ipairs(extmarks) do
    if mark.virt_text and mark.virt_text_pos ~= "overlay" then
      width = width + 1
      for _, chunk in ipairs(mark.virt_text) do
        width = width + api.nvim_strwidth(chunk[1])
      end
    end
  end
  return width
end

-- The list draws its rows again as it scrolls. Its rows change only when it
-- gets new items: snacks clears the list into a new table, and adds to it.
---@type { items: table?, count: integer, width: integer }
local measured = { count = 0, width = 0 }

---@param picker snacks.Picker
function M.fit(picker)
  local list = picker.list
  if measured.items == list.items and measured.count == list:count() then
    return measured.width
  end
  local width = 0
  for i = 1, math.min(list:count(), MAX_ROWS) do
    width = math.max(width, row_width(list, list:get(i)))
  end
  measured = { items = list.items, count = list:count(), width = width + 1 }
  return measured.width
end

-- Up to max_width, and never past the code window's right edge.
local function max_width(narrow)
  local max = config.options.layout.tree.max_width
  max = max < 1 and math.floor(vim.o.columns * max) or max
  local code = layout.wins.code
  if code and api.nvim_win_is_valid(code) then
    max = math.min(max, narrow + 1 + api.nvim_win_get_width(code))
  end
  return max
end

function M.update()
  local picker = M.explorer()
  if not picker then
    return
  end
  local list = picker.list.win
  local narrow = api.nvim_win_get_width(picker.layout.root.win)
  local width = narrow
  if picker:is_focused() then
    width = math.max(narrow, math.min(M.fit(picker), max_width(narrow)))
  end
  if api.nvim_win_get_width(list.win) ~= width then
    -- On WinResized, snacks gives the split the list's new width, unless the
    -- list has the width that snacks set.
    list.opts.width = width
    api.nvim_win_set_config(list.win, { width = width })
  end
end

-- At SafeState, which comes before the redraw, so no frame shows the old
-- width, or from the event loop for API calls. A plugin that enters the tree
-- for a moment in one command does not widen it.
local function check()
  if pending then
    pending = false
    M.update()
  end
end

local function mark()
  pending = true
  if not scheduled then
    scheduled = true
    vim.schedule(function()
      scheduled = false
      check()
    end)
  end
end

function M.setup()
  local group = api.nvim_create_augroup("anvim.tree", {})
  -- snacks sets the list's width again when it lays out the explorer, after
  -- a resize of the split or the terminal.
  api.nvim_create_autocmd({ "WinEnter", "WinResized", "VimResized" }, { group = group, callback = mark })
  -- Folders that open and close change the rows.
  api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function(ev)
      local picker = M.explorer()
      if picker and ev.buf == picker.list.win.buf then
        mark()
      end
    end,
  })
  api.nvim_create_autocmd("SafeState", { group = group, callback = check })
end

return M
