-- Past prompts, as in Claude Code: <Up> on the first line of the prompt goes
-- back, <Down> on the last line comes forward again. Each working directory
-- keeps its own list in anvim's state dir. While prompts are queued, <Up>
-- takes them back first.
local M = {}

local api = vim.api

M.max = 200
M.dir = vim.fn.stdpath("state") .. "/history"

---@type string[] Oldest first, as read when the user started to go back.
local entries = {}
-- How far back the prompt is, 1 for the newest entry. Nil while the user
-- types a prompt of their own.
---@type integer?
local index
---@type string[]? The prompt as the user left it before going back.
local draft

-- The directory's name for people, and a hash of its path, so that /a/b-c
-- and /a/b/c get files of their own.
function M.path()
  local cwd = require("anvim.state").cwd
  local name = vim.fs.basename(cwd):gsub("[^%w%-_.]", "-"):sub(1, 40)
  return ("%s/%s-%s.json"):format(M.dir, name, vim.fn.sha256(cwd):sub(1, 12))
end

---@return string[]
local function read()
  local f = io.open(M.path(), "r")
  if not f then
    return {}
  end
  local ok, list = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(list) == "table" and list or {}
end

-- Another anvim in the same directory may have added prompts since, so read
-- the file again before writing it.
function M.add(text)
  index, draft = nil, nil
  local list = read()
  if list[#list] ~= text then
    list[#list + 1] = text
  end
  while #list > M.max do
    table.remove(list, 1)
  end
  vim.fn.mkdir(M.dir, "p")
  local tmp = M.path() .. ".tmp"
  local f = io.open(tmp, "w")
  if f then
    f:write(vim.json.encode(list))
    f:close()
    os.rename(tmp, M.path())
  end
end

---@type string? The text that the prompt got from the history last.
local shown

local function prompt_lines()
  return api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false)
end

-- Puts text in the prompt, with the cursor at the end of its first or last line.
local function put(lines, at_top)
  shown = table.concat(lines, "\n")
  local buf, win = require("anvim.input").buf(), api.nvim_get_current_win()
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if api.nvim_win_get_buf(win) == buf then
    local row = at_top and 1 or #lines
    api.nvim_win_set_cursor(win, { row, #lines[row] })
  end
end

local function entry(at_top)
  put(vim.split(entries[#entries - index + 1], "\n", { plain = true }), at_top)
end

-- A recalled prompt that the user changed is their own text now. It becomes
-- the draft, and going back starts again at the newest prompt.
local function check_edit()
  if index and table.concat(prompt_lines(), "\n") ~= shown then
    index = nil
  end
end

function M.older()
  -- Queued prompts come back first, as in Claude Code.
  if require("anvim.input").unqueue() then
    index, draft = nil, nil
    return
  end
  check_edit()
  if not index then
    entries = read()
    if #entries == 0 then
      return
    end
    draft = prompt_lines()
  elseif index >= #entries then
    return
  end
  index = (index or 0) + 1
  entry(true)
end

function M.newer()
  check_edit()
  if not index then
    return
  end
  index = index - 1
  if index == 0 then
    index = nil
    put(draft or { "" }, false)
    draft = nil
  else
    entry(false)
  end
end

-- Insert mode <Up> and <Down>: a move in the completion menu while it shows,
-- history on the first or last line, else the usual move.
function M.up_keys()
  if vim.fn.pumvisible() == 0 and api.nvim_win_get_cursor(0)[1] == 1 then
    return "<Cmd>lua require('anvim.history').older()<CR>"
  end
  return "<Up>"
end

function M.down_keys()
  if vim.fn.pumvisible() == 0 and api.nvim_win_get_cursor(0)[1] == api.nvim_buf_line_count(0) then
    return "<Cmd>lua require('anvim.history').newer()<CR>"
  end
  return "<Down>"
end

function M.map(buf)
  local keys = require("anvim.keys")
  keys.set("prompt", "i", "<Up>", M.up_keys, { buffer = buf, expr = true })
  keys.set("prompt", "i", "<Down>", M.down_keys, { buffer = buf, expr = true })
  keys.set("prompt", "n", "<C-p>", M.older, { buffer = buf })
  keys.set("prompt", "n", "<C-n>", M.newer, { buffer = buf })
end

return M
