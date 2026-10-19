-- Follow mode: while the cursor is in the prompt, the code window shows where
-- Claude reads and writes. Elsewhere the user is in control, and the
-- statusline says where Claude is.
local layout = require('anvim.layout')

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace('anvim.follow')

---@type { path: string, line: integer }?
M.agent = nil
M.behind = 0

function M.enabled()
  return layout.wins.input ~= nil and api.nvim_get_current_win() == layout.wins.input
end

---@return integer buf
function M.load(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

local function reveal_in_tree(path)
  local ok, snacks = pcall(require, 'snacks')
  if ok and snacks.picker and snacks.picker.get({ source = 'explorer' })[1] then
    pcall(snacks.explorer.reveal, { file = path })
  end
end

-- Shows buf in the code window with the cursor at line (1-based) and col (0-based).
function M.show(buf, line, col)
  local win = layout.code_win()
  if api.nvim_win_get_buf(win) ~= buf then
    vim.bo[buf].buflisted = vim.bo[buf].buftype == ''
    api.nvim_win_set_buf(win, buf)
    local name = vim.b[buf].anvim_preview or api.nvim_buf_get_name(buf)
    if name ~= '' then
      reveal_in_tree(name)
    end
  end
  line = math.max(1, math.min(line, api.nvim_buf_line_count(buf)))
  api.nvim_win_set_cursor(win, { line, col or 0 })
end

-- Records Claude's location and moves the code window there when following.
---@param buf integer? A buffer to show instead of the file itself, such as a Write preview.
function M.track(path, line, buf)
  M.agent = { path = path, line = line or 1 }
  if M.enabled() then
    M.behind = 0
    M.show(buf or M.load(path), M.agent.line)
  else
    M.behind = M.behind + 1
    vim.cmd('redrawstatus!')
  end
end

-- Moves the code window to Claude's latest location.
function M.jump()
  M.behind = 0
  if M.agent and vim.uv.fs_stat(M.agent.path) then
    M.show(M.load(M.agent.path), M.agent.line)
  end
  vim.cmd('redrawstatus!')
end

---@param rows integer[] 0-based rows
function M.flash(buf, rows, group, ms)
  local marks = {}
  for _, row in ipairs(rows) do
    if row < api.nvim_buf_line_count(buf) then
      marks[#marks + 1] = api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = group, priority = 150 })
    end
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      for _, mark in ipairs(marks) do
        api.nvim_buf_del_extmark(buf, ns, mark)
      end
    end
  end, ms or 1200)
end

local function on_read(ev)
  local path = ev.input.file_path
  if type(path) ~= 'string' or not vim.uv.fs_stat(path) then
    return
  end
  local first = tonumber(ev.input.offset) or 1
  M.track(path, first)
  if not M.enabled() then
    return
  end
  local win = layout.code_win()
  api.nvim_win_call(win, function()
    vim.cmd('normal! zt')
  end)
  local buf = api.nvim_win_get_buf(win)
  local last = math.min(first + (tonumber(ev.input.limit) or api.nvim_win_get_height(win)) - 1, vim.fn.line('w$', win))
  local rows = {}
  for row = first - 1, last - 1 do
    rows[#rows + 1] = row
  end
  M.flash(buf, rows, 'AnvimRead', 400)
end

-- The code window's statusline segment.
function M.status(win)
  if win ~= layout.wins.code then
    return ''
  end
  if M.enabled() then
    return '%#AnvimClaude#◉ following '
  end
  if not M.agent then
    return ''
  end
  local where = ('%s:%d'):format(require('anvim.transcript').relpath(M.agent.path), M.agent.line)
  local behind = M.behind > 0 and (' +%d'):format(M.behind) or ''
  return ('%%#AnvimClaude#⏺ Claude at %s%s %%#Comment#(<leader>j) '):format(where:gsub('%%', '%%%%'), behind)
end

function M.attach(sidecar)
  sidecar.on('tool_use', function(ev)
    if ev.name == 'Read' and not ev.parent_id then
      on_read(ev)
    end
  end)
  api.nvim_create_autocmd('WinEnter', {
    group = api.nvim_create_augroup('anvim.follow', {}),
    callback = function()
      if M.enabled() and M.behind > 0 then
        M.jump()
      end
      vim.cmd('redrawstatus!')
    end,
  })
  vim.keymap.set('n', '<leader>j', M.jump, { desc = 'Jump to where Claude is' })
end

return M
