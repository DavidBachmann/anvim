-- References in the prompt: @path#L12-30 (1-based, inclusive), the format of
-- Claude Code's IDE integrations. In a file buffer, visual `c` and
-- `c{motion}` insert one. Read-only buffers leave `c` free, and "c" reads as
-- "change this, Claude".
local context = require("anvim.context")

local M = {}

local api = vim.api
local OPFUNC = "v:lua.require'anvim.refs'.operator"

---@param first integer? 1-based first line. Without it, the whole file.
---@param last integer?
function M.format(path, first, last)
  local ref = "@" .. context.relpath(path)
  return first and ref .. context.range(first, last) or ref
end

-- Puts text where typing stopped in the prompt, apart from its neighbors,
-- and goes on typing after it.
function M.insert(text)
  local input = require("anvim.input")
  local win = require("anvim.layout").wins.input
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local buf = input.buf()
  local row, col = input.insert_pos()
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if col > 0 and not line:sub(col, col):match("%s") then
    text = " " .. text
  end
  local after = #text + 1
  if not line:sub(col + 1, col + 1):match("%s") then
    text = text .. " "
  end
  api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { text })
  api.nvim_set_current_win(win)
  input.resume({ at = { row, col + after } })
end

-- Points Claude at lines of a file buffer. The reference replaces the pinned
-- selection.
function M.point(buf, first, last)
  local path = context.file(buf)
  if not path then
    vim.notify("anvim: this buffer has no file to point at", vim.log.levels.WARN)
    return
  end
  context.clear()
  M.insert(M.format(path, first, last))
end

function M.visual()
  local buf = api.nvim_get_current_buf()
  M.point(buf, api.nvim_buf_get_mark(buf, "<")[1], api.nvim_buf_get_mark(buf, ">")[1])
end

-- The 'operatorfunc' of `c`.
function M.operator()
  local buf = api.nvim_get_current_buf()
  M.point(buf, api.nvim_buf_get_mark(buf, "[")[1], api.nvim_buf_get_mark(buf, "]")[1])
end

-- Whole files and directories, as from the explorer.
---@param paths { path: string, dir: boolean? }[]
function M.files(paths)
  local refs = {}
  for _, p in ipairs(paths) do
    refs[#refs + 1] = M.format(p.path) .. (p.dir and not p.path:match("/$") and "/" or "")
  end
  if #refs > 0 then
    M.insert(table.concat(refs, " "))
  end
end

-- File buffer keys.
function M.map(buf)
  local function map(mode, lhs, rhs, desc, opts)
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", { buffer = buf, desc = desc }, opts or {}))
  end
  map("x", "c", "<Esc><Cmd>lua require('anvim.refs').visual()<CR>", "Point Claude at the selection")
  -- nowait: mini.surround's global `cs` would make `c` wait for 'timeoutlen'.
  map("n", "c", function()
    vim.o.operatorfunc = OPFUNC
    return "g@"
  end, "Point Claude at lines", { expr = true, nowait = true })
  -- `cc` takes the current line, and a count more lines. Other operators
  -- keep `c` as it is.
  map("o", "c", function()
    return vim.v.operator == "g@" and vim.o.operatorfunc == OPFUNC and "_" or "c"
  end, "Current line", { expr = true })
  -- LazyVim maps <C-l> in normal mode only.
  map("x", "<C-l>", "<C-w>l", "Go to the prompt with the selection")
end

return M
