-- Editor context for prompts. Each prompt tells Claude what the code window
-- shows: the file, the cursor line and the visible lines. A visual selection
-- in the code window stays pinned and highlighted after visual mode ends,
-- until the user moves on, and the prompts carry it too. The footer shows
-- what the next prompt carries.
local layout = require("anvim.layout")
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.context")
local esc = vim.keycode("<Esc>")
local kinds = { v = "char", V = "line", ["\22"] = "block" }
-- The sidecar gives Claude the first 2000 characters of a selection.
local MAX_TEXT = 2048
-- A block gets one highlight per line, for this many lines.
local MAX_BLOCK = 500
-- After these keys the cursor follows the view, but the user did not move it.
-- <C-e> is left out: it opens the harpoon menu.
local scroll_keys = {}
for _, key in ipairs({
  "<ScrollWheelUp>",
  "<ScrollWheelDown>",
  "<ScrollWheelLeft>",
  "<ScrollWheelRight>",
  "<C-y>",
  "<C-d>",
  "<C-u>",
  "<C-f>",
  "<C-b>",
}) do
  scroll_keys[vim.keycode(key)] = true
end

---@class anvim.Selection
---@field buf integer
---@field start_line integer 1-based
---@field end_line integer 1-based, inclusive
---@field text string
---@field mode 'char'|'line'|'block'
---@field cursor [integer, integer] the code window's cursor that keeps the selection

---@type anvim.Selection?
local sel
---@type string? The last key that the user typed.
local last_typed

local function set_highlights()
  api.nvim_set_hl(0, "AnvimSelection", { link = "Visual", default = true })
  api.nvim_set_hl(0, "AnvimChip", { link = "Comment", default = true })
  api.nvim_set_hl(0, "AnvimChipSelection", { link = "AnvimClaude", default = true })
end

-- Relative to the cwd, or absolute outside it.
function M.relpath(path)
  return vim.fs.relpath(state.cwd, path) or path
end

-- #L12-30, or #L12 for one line.
function M.range(first, last)
  return ("#L%d"):format(first) .. (last and last > first and ("-%d"):format(last) or "")
end

-- The file that a buffer shows: its own, or the one that a Write preview writes.
---@return string?
function M.file(buf)
  local name = vim.b[buf].anvim_preview or (vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf))
  return name and name ~= "" and name or nil
end

---@return integer? win, integer? buf, string? path
local function code()
  local win = layout.wins.code
  if win and api.nvim_win_is_valid(win) then
    local buf = api.nvim_win_get_buf(win)
    local path = M.file(buf)
    if path then
      return win, buf, path
    end
  end
end

-- The footer shows the change at once. The statusline says whether follow
-- mode waits for the pin, and a :redrawstatus inside a window command would
-- show a frame too early, so it waits for the event loop.
local function changed()
  require("anvim.input").render()
  vim.schedule(function()
    require("anvim.follow").resume()
  end)
end

local function drop()
  if sel and api.nvim_buf_is_valid(sel.buf) then
    api.nvim_buf_clear_namespace(sel.buf, ns, 0, -1)
  end
  sel = nil
end

function M.clear()
  if sel then
    drop()
    changed()
  end
end

---@return anvim.Selection?
function M.selection()
  return sel
end

local function mark(buf, row, col, end_row, end_col)
  api.nvim_buf_set_extmark(buf, ns, row, col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = "AnvimSelection",
    hl_eol = true,
    priority = 200,
  })
end

local function line_at(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

-- One line of a block per entry of getregionpos(), which gives the 1-based
-- columns of the first and the last byte, and 0 for a line that ends before
-- the block. After `$`, each line goes to its end, which getregion() ignores.
local function block(buf, region, to_eol)
  local lines = {}
  for i, r in ipairs(region) do
    local row, from = r[1][2] - 1, r[1][3]
    local line = line_at(buf, row)
    local to = to_eol and #line or math.min(r[2][3], #line)
    lines[i] = from > 0 and line:sub(from, to) or ""
    if from > 0 and to >= from and i <= MAX_BLOCK then
      mark(buf, row, from - 1, row, to)
    end
  end
  return lines
end

-- Pins the visual selection that just ended in the current buffer.
local function pin(vmode)
  local buf, kind = api.nvim_get_current_buf(), kinds[vmode]
  local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  if s[2] < 1 then
    return
  end
  drop()
  -- Claude gets the start of a long selection only, so read no more lines.
  local cut = { e[1], math.min(e[2], s[2] + MAX_TEXT), e[3], e[4] }
  local lines
  if kind == "block" then
    local to_eol = vim.fn.winsaveview().curswant == vim.v.maxcol
    lines = block(buf, vim.fn.getregionpos(s, cut, { type = vmode }), to_eol)
  else
    lines = vim.fn.getregion(s, cut, { type = vmode })
    local srow, erow = s[2] - 1, e[2] - 1
    if kind == "line" then
      mark(buf, srow, 0, erow + 1, 0)
    else
      local last = line_at(buf, erow)
      local col = math.min(e[3], #last)
      mark(buf, srow, math.min(s[3] - 1, #line_at(buf, srow)), erow, col > 0 and col + vim.str_utf_end(last, col) or 0)
    end
  end
  local text = table.concat(lines, "\n")
  if vim.fn.strchars(text) > MAX_TEXT then
    text = vim.fn.strcharpart(text, 0, MAX_TEXT)
  end
  sel = { buf = buf, start_line = s[2], end_line = e[2], text = text, mode = kind, cursor = api.nvim_win_get_cursor(0) }
  changed()
end

-- Window keys and clicks end visual mode before they leave the window.
local function on_mode_changed()
  local was, is = kinds[vim.v.event.old_mode:sub(1, 1)], kinds[vim.v.event.new_mode:sub(1, 1)]
  local win = code()
  if was == is or (was and is) or win ~= api.nvim_get_current_win() then
    return
  end
  if is then
    -- A new selection replaces the pinned one.
    M.clear()
  else
    pin(vim.v.event.old_mode:sub(1, 1))
  end
end

-- The context for a prompt that the user sends now, and its transcript label.
---@return table? context, string? label
function M.prompt(text)
  local win, buf, path = code()
  local ctx, label
  -- A slash command runs in Claude Code, which runs no hook for it.
  if text:sub(1, 1) == "/" then
    require("anvim.trail").prompt(text)
    return
  end
  if win and buf and path then
    ctx = {
      file = M.relpath(path),
      cursor_line = api.nvim_win_get_cursor(win)[1],
      visible = { vim.fn.line("w0", win), vim.fn.line("w$", win) },
    }
    label = require("anvim.transcript").relpath(path)
    if sel and sel.buf == buf then
      ctx.selection = { start_line = sel.start_line, end_line = sel.end_line, text = sel.text, mode = sel.mode }
      label = label .. M.range(sel.start_line, sel.end_line)
    end
  end
  require("anvim.trail").prompt(text, path, ctx and ctx.selection)
  -- The pin belongs to this prompt. Follow mode then catches up with Claude.
  M.clear()
  return ctx, label
end

-- The footer's chip: what the next prompt carries. With `room`, the file name
-- gets shorter to fit, and a chip that cannot fit is nil.
---@param room integer? columns
---@return [string, string]?
function M.chip(room)
  local _, buf, path = code()
  if not path then
    return
  end
  local text, group
  if sel and sel.buf == buf then
    local n = sel.end_line - sel.start_line + 1
    text, group = ("⧉ %d %s selected"):format(n, n == 1 and "line" or "lines"), "AnvimChipSelection"
  else
    text, group = "⧉ In " .. vim.fs.basename(path), "AnvimChip"
    if room and api.nvim_strwidth(text) > room then
      local keep = room - api.nvim_strwidth("⧉ In ...")
      text = keep >= 4 and "⧉ In " .. vim.fn.strcharpart(vim.fs.basename(path), 0, keep) .. "..." or text
    end
  end
  if not room or api.nvim_strwidth(text) <= room then
    return { text, group }
  end
end

function M.attach()
  set_highlights()
  local group = api.nvim_create_augroup("anvim.context", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  api.nvim_create_autocmd("ModeChanged", { group = group, callback = on_mode_changed })
  -- Follow mode moves the code window's cursor while the user is in the
  -- prompt. Coming back is not a move of the user's, so it sets a new place.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      if sel and win == layout.wins.code then
        sel.cursor = api.nvim_win_get_cursor(win)
      end
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      if not sel or win ~= layout.wins.code then
        return
      end
      local cursor = api.nvim_win_get_cursor(win)
      if scroll_keys[last_typed] then
        sel.cursor = cursor
      elseif cursor[1] ~= sel.cursor[1] or cursor[2] ~= sel.cursor[2] then
        M.clear()
      end
    end,
  })
  -- The code window shows another file, or Claude changed this one.
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      if sel and select(2, code()) ~= sel.buf then
        M.clear()
      end
      vim.schedule(require("anvim.input").render)
    end,
  })
  api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if sel and ev.buf == sel.buf then
        M.clear()
      end
    end,
  })
  -- No footer now: Neovim may be quitting, with its buffers unloaded. Follow
  -- mode resumes from the event loop, as for any other end of a pin.
  api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(ev)
      if sel and ev.buf == sel.buf then
        drop()
        vim.schedule(function()
          require("anvim.follow").resume()
        end)
      end
    end,
  })
  vim.on_key(function(_, typed)
    if typed == "" then
      return
    end
    last_typed = typed
    if typed == esc and sel and api.nvim_get_mode().mode == "n" and api.nvim_get_current_win() == layout.wins.code then
      vim.schedule(M.clear)
    end
  end, ns)
end

return M
