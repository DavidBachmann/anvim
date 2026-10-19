-- Default statusline: the file path for file windows, a plain rule for the rest.
local M = {}

function M.render()
  local win = vim.g.statusline_winid
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' then
    return '%#WinSeparator#' .. ('─'):rep(vim.api.nvim_win_get_width(win))
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name == '' and '[No Name]' or require('anvim.transcript').relpath(name)
  return (' %s %%m%%=%%l:%%c  %%P '):format(path:gsub('%%', '%%%%'))
end

return M
