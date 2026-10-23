-- Paths and ranges of references, in the form @path#L12-30 (1-based,
-- inclusive). Claude Code reads the lines of a reference into the prompt.
local state = require("anvim.state")

local M = {}

local api = vim.api

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

return M
