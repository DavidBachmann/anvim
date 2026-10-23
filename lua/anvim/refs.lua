-- References in the prompt: @path#L12-30 (1-based, inclusive), the format of
-- Claude Code's IDE integrations. In a file buffer, visual `c` and
-- `c{motion}` insert one and go on typing. Read-only buffers leave `c` free,
-- and "c" reads as "change this, Claude". <leader>cb inserts the selection or
-- the whole file, and leaves the cursor in the prompt in normal mode.
local paths = require("anvim.paths")

local M = {}

local api = vim.api
local OPFUNC = "v:lua.require'anvim.refs'.operator"

---@param first integer? 1-based first line. Without it, the whole file.
---@param last integer?
function M.format(path, first, last)
  local ref = "@" .. paths.relpath(path)
  return first and ref .. paths.range(first, last) or ref
end

-- Puts text where typing stopped in the prompt, apart from its neighbors.
-- With typing, typing goes on after it. Otherwise the cursor is on the space
-- after it, in normal mode.
---@param typing boolean?
function M.insert(text, typing)
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
  if typing then
    api.nvim_set_current_win(win)
    input.resume({ at = { row, col + after } })
  else
    require("anvim.layout").focus_input({ insert = false })
    api.nvim_win_set_cursor(win, { row, col + after - 1 })
  end
end

-- Points Claude at lines of a file buffer, or at the whole file.
---@param typing boolean?
function M.point(buf, first, last, typing)
  local path = paths.file(buf)
  if not path then
    vim.notify("anvim: this buffer has no file to point at", vim.log.levels.WARN)
    return
  end
  M.insert(M.format(path, first, last), typing)
end

---@param typing boolean?
function M.visual(typing)
  local buf = api.nvim_get_current_buf()
  M.point(buf, api.nvim_buf_get_mark(buf, "<")[1], api.nvim_buf_get_mark(buf, ">")[1], typing)
end

-- The 'operatorfunc' of `c`.
function M.operator()
  local buf = api.nvim_get_current_buf()
  M.point(buf, api.nvim_buf_get_mark(buf, "[")[1], api.nvim_buf_get_mark(buf, "]")[1], true)
end

-- Whole files and directories, as from the explorer.
---@param items { path: string, dir: boolean? }[]
function M.files(items)
  local refs = {}
  for _, p in ipairs(items) do
    refs[#refs + 1] = M.format(p.path) .. (p.dir and not p.path:match("/$") and "/" or "")
  end
  if #refs > 0 then
    M.insert(table.concat(refs, " "))
  end
end

-- File buffer keys.
function M.map(buf)
  local function map(mode, lhs, rhs, opts)
    require("anvim.keys").set("code", mode, lhs, rhs, vim.tbl_extend("force", { buffer = buf }, opts or {}))
  end
  map("x", "c", "<Esc><Cmd>lua require('anvim.refs').visual(true)<CR>")
  map("x", "<leader>cb", "<Esc><Cmd>lua require('anvim.refs').visual()<CR>")
  map("n", "<leader>cb", function()
    M.point(buf)
  end)
  -- nowait: a global map such as a personal spec's `cs` would make `c` wait
  -- for 'timeoutlen'.
  map("n", "c", function()
    vim.o.operatorfunc = OPFUNC
    return "g@"
  end, { expr = true, nowait = true })
  -- `cc` takes the current line, and a count more lines. Other operators
  -- keep `c` as it is.
  map("o", "c", function()
    return vim.v.operator == "g@" and vim.o.operatorfunc == OPFUNC and "_" or "c"
  end, { expr = true })
end

function M.unmap(buf)
  for _, k in ipairs({ { "x", "c" }, { "n", "c" }, { "o", "c" }, { "x", "<leader>cb" }, { "n", "<leader>cb" } }) do
    pcall(vim.keymap.del, k[1], k[2], { buffer = buf })
  end
end

return M
