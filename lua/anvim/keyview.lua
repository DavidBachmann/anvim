-- The key view: every key of anvim, by the place where it works, in a float
-- with the look of which-key's helix preset. which-key cannot show it: its
-- view lists the keys under one prefix, sorted by key, one group at a time.
local keys = require("anvim.keys")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.keyview")
local SEP = " ➜ "
-- Spaces between two columns of keys.
local GAP = 3
local MODES = { i = "insert", x = "visual", o = "operator" }

---@class anvim.KeyView
---@field win integer?
---@field buf integer?
---@field from integer The window that had the cursor.
---@field previous integer? Its previous window, for <C-w>p.
---@field cursor [integer, integer]
---@field insert boolean
---@field reading boolean The transcript was in read mode.
---@field saved vim.fn.winsaveview.ret? The transcript's view in read mode.

---@type anvim.KeyView?
local view

local function valid(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@return integer?
function M.win()
  return view and valid(view.win) and view.win or nil
end

---@alias anvim.KeyView.Row [string, string, string] The keys, the description and the mode tag.
---@alias anvim.KeyView.Line { header: string }|anvim.KeyView.Row|false

-- The modes of a key that does not work in normal mode.
---@param key anvim.Key
local function tag(key)
  if key.tag then
    return key.tag
  end
  local modes = keys.modes(key)
  if vim.tbl_contains(modes, "n") then
    return ""
  end
  return table.concat(
    vim.tbl_map(function(m)
      return MODES[m] or m
    end, modes),
    ", "
  )
end

-- Each place as its name and its rows. Keys next to each other with the same
-- row share one.
local function groups()
  local ret = {}
  for _, place in ipairs(keys.places) do
    if place.ctx ~= "view" then
      local rows = {} ---@type { row: string?, labels: string[], desc: string, tag: string }[]
      for _, key in ipairs(place.keys) do
        local last, label = rows[#rows], keys.label(key)
        if key.row and last and last.row == key.row then
          if not vim.tbl_contains(last.labels, label) then
            last.labels[#last.labels + 1] = label
          end
        else
          rows[#rows + 1] = { row = key.row, labels = { label }, desc = key.row or key[2], tag = tag(key) }
        end
      end
      ret[#ret + 1] = {
        name = place.name,
        rows = vim.tbl_map(function(r)
          return { table.concat(r.labels, " "), r.desc, r.tag }
        end, rows),
      }
    end
  end
  return ret
end

-- Fills columns of `height` lines with the groups, with a blank line between
-- two groups. Without `split`, a group that does not fit under another starts
-- a new column. With it, the group starts under the other one when its name
-- and two rows fit there. Either way, a group goes on in the next column when
-- the column is full.
---@return { lines: anvim.KeyView.Line[], key: integer, desc: integer, tag: integer, width: integer }[]
local function pack(list, height, split)
  local cols, col = {}, nil
  local function new()
    col = { lines = {}, key = 0, desc = 0, tag = 0, width = 0 }
    cols[#cols + 1] = col
  end
  new()
  for _, group in ipairs(list) do
    if #col.lines > 0 then
      local need = split and math.min(2, #group.rows) or #group.rows
      if #col.lines + 2 + need > height then
        new()
      else
        col.lines[#col.lines + 1] = false
      end
    end
    col.lines[#col.lines + 1] = { header = group.name }
    for _, row in ipairs(group.rows) do
      if #col.lines >= height then
        -- The group goes on under its name.
        new()
        col.lines[1] = { header = group.name }
      end
      col.lines[#col.lines + 1] = row
    end
  end
  local w = api.nvim_strwidth
  for _, c in ipairs(cols) do
    local header = 0
    for _, line in ipairs(c.lines) do
      if line and line.header then
        header = math.max(header, w(line.header))
      elseif line then
        c.key, c.desc, c.tag = math.max(c.key, w(line[1])), math.max(c.desc, w(line[2])), math.max(c.tag, w(line[3]))
      end
    end
    c.width = math.max(header, c.key + w(SEP) + c.desc + (c.tag > 0 and 1 + c.tag or 0))
  end
  return cols
end

local function total_width(cols)
  local width = 2 + GAP * (#cols - 1)
  for _, col in ipairs(cols) do
    width = width + col.width
  end
  return width
end

-- The fewest lines whose columns fit the screen's width. Groups stay whole
-- when that fits the screen's height too.
local function arrange(max_width, max_height)
  local list = groups()
  local total = 0
  for _, group in ipairs(list) do
    total = total + 2 + #group.rows
  end
  local function fit(split)
    local cols = {}
    for height = 1, total do
      cols = pack(list, height, split)
      if total_width(cols) <= max_width then
        return cols
      end
    end
    return cols
  end
  local cols = fit(false)
  local height = 0
  for _, col in ipairs(cols) do
    height = math.max(height, #col.lines)
  end
  if height > max_height then
    cols = fit(true)
  end
  height = 0
  for _, col in ipairs(cols) do
    height = math.max(height, #col.lines)
  end
  return cols, height
end

---@return string[] lines, { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] marks
local function render(cols, height)
  local w = api.nvim_strwidth
  local lines, marks = {}, {}
  for r = 1, height do
    local text = " "
    local function add(s, hl)
      if hl and s ~= "" then
        marks[#marks + 1] = { r - 1, #text, #text + #s, hl }
      end
      text = text .. s
    end
    for c, col in ipairs(cols) do
      if c > 1 then
        add((" "):rep(GAP))
      end
      local line, start = col.lines[r], w(text)
      if line and line.header then
        add(line.header, "WhichKeyGroup")
      elseif line then
        add((" "):rep(col.key - w(line[1])))
        add(line[1], "WhichKey")
        add(SEP, "WhichKeySeparator")
        add(line[2], "WhichKeyDesc")
        if line[3] ~= "" then
          add((" "):rep(col.desc - w(line[2]) + 1))
          add(line[3], "WhichKeyValue")
        end
      end
      add((" "):rep(col.width - (w(text) - start)))
    end
    lines[r] = text .. " "
  end
  return lines, marks
end

-- The view's own keys, as which-key's helix preset shows them.
local function footer(scrolls)
  local chunks = {}
  local function add(key, desc)
    vim.list_extend(chunks, { { " " .. key, "WhichKey" }, { " " .. desc .. " ", "WhichKeySeparator" } })
  end
  local seen = {}
  for _, key in ipairs(keys.place("view").keys) do
    local desc = key.row or key[2]
    if (scrolls or not key.scrolls) and not seen[desc] then
      seen[desc] = true
      add(keys.label(key), desc)
    end
  end
  add(":help index", "Vim's own keys")
  return chunks
end

-- Writes the view into its buffer, and returns the float's config.
---@return vim.api.keyset.win_config
local function draw(buf)
  local status = vim.o.laststatus > 0 and 1 or 0
  local bottom = vim.o.lines - vim.o.cmdheight - status
  local cols, height = arrange(vim.o.columns - 2, bottom - 2)
  local lines, marks = render(cols, height)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  local width = math.min(api.nvim_strwidth(lines[1] or ""), vim.o.columns - 2)
  local rows = math.max(1, math.min(height, bottom - 2))
  -- At the bottom right, as which-key's helix preset puts its view.
  return {
    relative = "editor",
    row = math.max(0, bottom - rows - 2),
    col = math.max(0, vim.o.columns - width - 2),
    width = width,
    height = rows,
    border = "rounded",
    title = { { " anvim keys · <leader> is Space · normal mode unless tagged ", "WhichKeyTitle" } },
    title_pos = "left",
    footer = footer(height > rows),
    footer_pos = "center",
    style = "minimal",
    zindex = 200,
  }
end

-- Puts the cursor in the window that opened the view, and read mode back.
---@param v anvim.KeyView
local function go_back(v)
  if not valid(v.from) then
    require("anvim.layout").focus_input({ insert = false })
  elseif v.reading then
    require("anvim.windows").read()
    api.nvim_win_call(v.from, function()
      vim.fn.winrestview(v.saved)
    end)
  elseif api.nvim_get_current_win() ~= v.from then
    api.nvim_set_current_win(v.from)
  end
end

-- Once the view is closed: <C-w>p and insert mode, as before the view.
---@param v anvim.KeyView
local function finish(v)
  if not valid(v.from) or api.nvim_get_current_win() ~= v.from then
    return
  end
  -- Neovim forgets a previous window that closed, so <C-w>p would go nowhere.
  if valid(v.previous) and v.previous ~= v.from then
    local hop = require("anvim.windows").hop
    hop(v.previous)
    hop(v.from)
  end
  if v.insert then
    require("anvim.input").resume({ at = v.cursor })
  end
end

-- Closes the view. With `back`, the cursor goes back where it was, in the
-- same mode.
---@param back boolean
local function close(back)
  local v = view
  view = nil
  if not v then
    return
  end
  pcall(api.nvim_del_augroup_by_name, "anvim.keyview")
  -- Going back first means that the close enters no other window.
  if back then
    go_back(v)
  end
  if valid(v.win) then
    pcall(api.nvim_win_close, v.win, true)
  end
  if back then
    finish(v)
    return
  end
  local compose = require("anvim.compose")
  if v.from == compose.win() and api.nvim_get_current_win() ~= v.from then
    -- Leaving the compose window puts its text in the prompt.
    compose.close()
  end
end

function M.close()
  close(true)
end

---@param opts? { insert: boolean? } The prompt was in insert mode.
function M.open(opts)
  if M.win() then
    api.nvim_set_current_win(view.win)
    return
  end
  local from = api.nvim_get_current_win()
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  local layout = require("anvim.layout")
  local reading = from == layout.wins.transcript and vim.w[from].anvim_read == true
  view = {
    from = from,
    previous = previous ~= 0 and previous or nil,
    cursor = api.nvim_win_get_cursor(from),
    insert = opts and opts.insert or false,
    reading = reading,
    saved = reading and api.nvim_win_call(from, vim.fn.winsaveview) or nil,
  }
  local buf = api.nvim_create_buf(false, true)
  view.buf = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "anvim_keys"
  local config = draw(buf)
  for _, key in ipairs({ "q", "<Esc>" }) do
    keys.set("view", "n", key, M.close, { buffer = buf, nowait = true })
  end
  -- The view has no cursor to show, so j and k scroll it at once.
  keys.set("view", "n", "j", "<C-e>", { buffer = buf, nowait = true })
  keys.set("view", "n", "k", "<C-y>", { buffer = buf, nowait = true })
  local win = api.nvim_open_win(buf, true, config)
  view.win = win
  -- A float copies the options of the window it opens from, such as the
  -- prompt's winbar.
  local wo = vim.wo[win]
  wo.winbar = ""
  wo.wrap = false
  wo.scrolloff = 0
  wo.winfixbuf = true
  wo.winhighlight =
    "Normal:WhichKeyNormal,FloatBorder:WhichKeyBorder,FloatTitle:WhichKeyTitle,FloatFooter:WhichKeyNormal"
  local group = api.nvim_create_augroup("anvim.keyview", { clear = true })
  -- A click or a window key elsewhere closes the view, and the cursor stays there.
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if view and view.buf == buf and api.nvim_get_current_win() ~= view.win then
          close(false)
        end
      end)
    end,
  })
  -- :q and <C-w>c close the window itself. Neovim then enters the previous
  -- window, after this event, so the cursor goes back from the event loop.
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      local v = view
      if v and v.win == win then
        view = nil
        vim.schedule(function()
          if not view then
            pcall(api.nvim_del_augroup_by_name, "anvim.keyview")
          end
          go_back(v)
          finish(v)
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if view and view.buf == buf and M.win() then
        api.nvim_win_set_config(win, draw(buf))
      end
    end,
  })
end

return M
