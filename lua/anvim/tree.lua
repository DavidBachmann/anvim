-- The explorer's width. Without focus, it keeps the narrow width of its split.
-- With focus, its list widens over the code window to fit its rows, like a
-- drawer, and the code window keeps its place.
-- Each agent also puts a dot in its color on the files it writes to, and on
-- the closed folders above them, at the right edge as snacks shows git status.
local agents = require("anvim.agents")
local config = require("anvim.config")
local layout = require("anvim.layout")
local state = require("anvim.state")

local M = {}

local api = vim.api
-- Rows to measure at most, for a tree with large folders open.
local MAX_ROWS = 2000
-- Dots on a row at most, before a "+".
local MAX_DOTS = 3
-- Below snacks' marks, which have the default priority, so the dots draw
-- first and sit at the right edge.
local PRIORITY = 4095

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

-- The explorer names a file by its path under getcwd(), which has no
-- symlinks. Claude can write /tmp for /private/tmp. A file that does not
-- exist yet, such as a Write's, resolves through the nearest folder that
-- exists. The file gets the same path once it exists, so the cache holds.
---@type table<string, string>
local reals = {}

local function real(path)
  local given = path
  if reals[given] then
    return reals[given]
  end
  if vim.fn.isabsolutepath(path) == 0 then
    path = vim.fs.joinpath(state.cwd, path)
  end
  path = vim.fs.normalize(path)
  local rest = ""
  while true do
    local resolved = vim.uv.fs_realpath(path)
    local parent = vim.fs.dirname(path)
    if resolved or parent == path then
      reals[given] = vim.fs.joinpath(resolved or path, rest)
      return reals[given]
    end
    rest = vim.fs.joinpath(vim.fs.basename(path), rest)
    path = parent
  end
end

-- The slots that write to each file, and to each folder above it.
---@type { files: table<string, integer[]>, dirs: table<string, integer[]>, version: integer }
local marks = { files = {}, dirs = {}, version = 0 }
local stale = false
local drawn = 0

local function merge(map, path, slots)
  local list = map[path] or {}
  map[path] = list
  for _, slot in ipairs(slots) do
    if not vim.tbl_contains(list, slot) then
      list[#list + 1] = slot
    end
  end
  table.sort(list)
end

local function current()
  if not stale then
    return marks
  end
  stale = false
  local files, dirs = {}, {}
  local all = agents.marks()
  if next(all) == nil then
    reals = {}
  end
  for path, slots in pairs(all) do
    -- The explorer keeps symlinks below the cwd as their own rows, so a file
    -- gets its dots under both names.
    local given = vim.fs.normalize(vim.fn.isabsolutepath(path) == 1 and path or vim.fs.joinpath(state.cwd, path))
    local resolved = real(path)
    for _, name in ipairs(given == resolved and { given } or { given, resolved }) do
      merge(files, name, slots)
      for dir in vim.fs.parents(name) do
        merge(dirs, dir, slots)
      end
    end
  end
  if not vim.deep_equal(files, marks.files) then
    marks = { files = files, dirs = dirs, version = marks.version + 1 }
  end
  return marks
end

-- Like git status, a folder shows the slots below it only while it is closed.
---@param item snacks.picker.explorer.Item
---@return integer[]?
function M.slots(item)
  local all = current()
  if item.dir then
    return not item.open and all.dirs[item.file] or nil
  end
  return all.files[item.file]
end

---@type snacks.picker.format
function M.format(item, picker)
  local ret = Snacks.picker.format.file(item, picker)
  local slots = M.slots(item)
  if slots then
    local dots = {}
    for i, slot in ipairs(slots) do
      if i > MAX_DOTS then
        dots[#dots + 1] = { "+", "Comment" }
        break
      end
      dots[#dots + 1] = { "⏺", agents.group(slot) }
    end
    dots[#dots + 1] = { " " }
    -- First, so that snacks still trims the row's trailing space.
    table.insert(ret, 1, {
      col = 0,
      virt_text = dots,
      virt_text_pos = "right_align",
      hl_mode = "combine",
      priority = PRIORITY,
    })
  end
  return ret
end

-- The list draws only its visible rows, from the items it has, so this needs
-- no find and keeps the cursor, the view and the mode. Once per loop
-- iteration, and never from a window event, because it flushes a redraw.
local redraw_scheduled = false
local function files_changed()
  stale = true
  if redraw_scheduled then
    return
  end
  redraw_scheduled = true
  vim.schedule(function()
    redraw_scheduled = false
    local version = current().version
    local picker = version ~= drawn and M.explorer()
    drawn = version
    if picker then
      -- A focused tree widens to fit the dots in the same frame.
      M.update()
      picker.list:update({ force = true })
    end
  end)
end

-- The columns of a row: its text, and the git status and dots at its right
-- edge. The tree's guides lie over the indent.
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
-- gets new items, as snacks clears the list into a new table and adds to it,
-- or when the dots change.
---@type { items: table?, count: integer, marks: integer, width: integer }
local measured = { count = 0, marks = 0, width = 0 }

---@param picker snacks.Picker
function M.fit(picker)
  local list = picker.list
  local version = current().version
  if measured.items == list.items and measured.count == list:count() and measured.marks == version then
    return measured.width
  end
  local width = 0
  for i = 1, math.min(list:count(), MAX_ROWS) do
    width = math.max(width, row_width(list, list:get(i)))
  end
  measured = { items = list.items, count = list:count(), marks = version, width = width + 1 }
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
  api.nvim_create_autocmd("User", { group = group, pattern = "AnvimAgentFiles", callback = files_changed })
end

return M
