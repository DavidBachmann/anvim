-- Default statusline: the file path for file windows, a plain rule for the rest.
-- The code window also shows where Claude is.
local M = {}

function M.render()
  local win = vim.g.statusline_winid
  local buf = vim.api.nvim_win_get_buf(win)
  local relpath = require('anvim.transcript').relpath
  local preview = vim.b[buf].anvim_preview
  if vim.bo[buf].buftype ~= '' and not preview then
    return '%#WinSeparator#' .. ('─'):rep(vim.api.nvim_win_get_width(win))
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local path = preview and relpath(preview) .. ' (writing)' or name == '' and '[No Name]' or relpath(name)
  local follow = require('anvim.follow').status(win)
  return (' %s %%m%%=%s%%l:%%c  %%P '):format(path:gsub('%%', '%%%%'), follow)
end

return M
