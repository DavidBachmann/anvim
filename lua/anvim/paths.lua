-- Paths, and the ranges of references in the form @path#L12-30 (1-based,
-- inclusive). Claude Code reads the lines of a reference into the prompt.
local state = require("anvim.state")

local M = {}

local api = vim.api

-- Relative to the cwd, or absolute outside it, as Claude Code reads it.
function M.relpath(path)
  return vim.fs.relpath(state.cwd, path) or path
end

-- Relative to the cwd, or from ~ outside it, for the user to read.
function M.display(path)
  if type(path) ~= "string" then
    return ""
  end
  return vim.fs.relpath(state.cwd, path) or vim.fn.fnamemodify(path, ":~")
end

-- An absolute path. A relative path is relative to the cwd.
---@param path string
---@return string
function M.resolve(path)
  path = vim.fs.normalize(path)
  if vim.fn.isabsolutepath(path) == 0 then
    path = vim.fs.joinpath(state.cwd, path)
  end
  return vim.fs.normalize(path)
end

-- A file of the working directory in `dir`, such as its prompt history. The
-- name has the directory's name for people, and a hash of its path, so that
-- /a/b-c and /a/b/c get files of their own.
---@param dir string
---@return string
function M.project_file(dir)
  local name = vim.fs.basename(state.cwd):gsub("[^%w%-_.]", "-"):sub(1, 40)
  return ("%s/%s-%s.json"):format(dir, name, vim.fn.sha256(state.cwd):sub(1, 12))
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
