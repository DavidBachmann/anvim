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

-- The path, in at most `max` cells. From the left, each directory but the
-- last becomes its first letter until the path fits, as in /v/f/T/folder/file.
-- A path that still does not fit drops its leading parts behind an ellipsis.
-- Its last folder loses its end before it goes, and last the file name loses
-- its middle, so that its extension stays.
---@param path string
---@param max integer
---@return string
function M.shorten(path, max)
  local w = api.nvim_strwidth
  local len = w(path)
  if len <= max then
    return path
  end
  local parts = vim.split(path, "/", { plain = true })
  for i = 1, #parts - 2 do
    if len <= max then
      return table.concat(parts, "/")
    end
    local short = vim.fn.strcharpart(parts[i], 0, vim.startswith(parts[i], ".") and 2 or 1)
    len = len - (w(parts[i]) - w(short))
    parts[i] = short
  end
  if len <= max then
    return table.concat(parts, "/")
  end
  local text = require("anvim.text")
  local dots = "\226\128\166/"
  for i = 2, #parts - 1 do
    local rest = dots .. table.concat(parts, "/", i)
    if w(rest) <= max then
      return rest
    end
  end
  local name = parts[#parts]
  if #parts > 1 then
    -- The last folder loses its end before it goes.
    local room = max - w(dots .. "/" .. name)
    if room >= 2 then
      return dots .. text.truncate(parts[#parts - 1], room) .. "/" .. name
    elseif w(dots .. name) <= max then
      return dots .. name
    end
  end
  return text.middle(name, max)
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
