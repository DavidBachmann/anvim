-- A blink.cmp source for the prompt: files and directories after `@`, and
-- slash commands at the start of the prompt.
local state = require("anvim.state")

local M = {}

local MAX_ITEMS = 5000
-- Entries, files and directories, that a walk of a project outside git visits.
local MAX_WALK = 20000
-- A list stays this long, even after files may have changed.
local FRESH_MS = 5000
-- LSP CompletionItemKind values, as blink.cmp uses them.
local KIND = { file = 17, folder = 19, command = 14 }

---@type { name: string, description: string?, argument_hint: string? }[]
M.commands = {}
---@class anvim.FileList
---@field paths string[] relative to the cwd, shallow ones first
---@field lower string[] the same paths in lower case
---@field at integer vim.uv.now() when listed

---@type anvim.FileList?
local files
-- Files may have changed since the list was made: Claude's turn ended, or
-- Neovim got the focus back from another program.
local stale = false
---@type fun(files: anvim.FileList)[]
local waiting = {}

local function walk()
  local out, seen = {}, 0
  for name, type in
    vim.fs.dir(state.cwd, {
      depth = 8,
      skip = function(dir)
        local base = vim.fs.basename(dir)
        return base:sub(1, 1) ~= "." and base ~= "node_modules"
      end,
    })
  do
    seen = seen + 1
    if seen > MAX_WALK then
      break
    end
    if type == "file" and vim.fs.basename(name):sub(1, 1) ~= "." then
      out[#out + 1] = name
    end
  end
  return out
end

---@return anvim.FileList
local function file_list(paths)
  local depth = {}
  for _, path in ipairs(paths) do
    depth[path] = select(2, path:gsub("/", ""))
  end
  table.sort(paths, function(a, b)
    if depth[a] ~= depth[b] then
      return depth[a] < depth[b]
    end
    return a < b
  end)
  return { paths = paths, lower = vim.tbl_map(string.lower, paths), at = vim.uv.now() }
end

-- Calls back with the project's files. The list is made again when files
-- may have changed, and not within FRESH_MS.
local function with_files(cb)
  if files and not (stale and vim.uv.now() - files.at > FRESH_MS) then
    return cb(files)
  end
  waiting[#waiting + 1] = cb
  if #waiting > 1 then
    return
  end
  local function done(paths)
    files, stale = file_list(paths), false
    local cbs = waiting
    waiting = {}
    for _, fn in ipairs(cbs) do
      fn(files)
    end
  end
  local cmd = { "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" }
  -- vim.system() throws when git is missing.
  local ok = pcall(vim.system, cmd, { cwd = state.cwd, text = true }, function(obj)
    vim.schedule(function()
      done(obj.code == 0 and vim.split(obj.stdout, "\0", { trimempty = true }) or walk())
    end)
  end)
  if not ok then
    done(walk())
  end
end

local function edit(row, from, to, text)
  return {
    newText = text,
    range = { start = { line = row, character = from }, ["end"] = { line = row, character = to } },
  }
end

-- Whether the characters of query appear in s in that order. blink.cmp
-- matches fuzzily too, so this only drops what it would never show.
local function has_chars(s, query)
  local at = 0
  for i = 1, #query do
    at = s:find(query:sub(i, i), at + 1, true)
    if not at then
      return false
    end
  end
  return true
end

---@param list anvim.FileList
---@param token string what follows the `@`, such as lua/anvim/st
---@param row integer 0-based
---@param at integer 0-based column of the `@`
---@param cursor integer 0-based cursor column
function M.file_items(list, token, row, at, cursor)
  local dir = token:match("^(.*/)") or ""
  local query = token:sub(#dir + 1):lower()
  local items, dirs = {}, {}
  local function item(path, kind)
    local rest = path:sub(#dir + 1)
    items[#items + 1] = {
      label = path,
      filterText = rest,
      kind = kind,
      -- Shallow paths first while the query is empty.
      sortText = ("%02d%s"):format(select(2, rest:gsub("/", "")), rest),
      textEdit = edit(row, at, cursor, "@" .. path .. (kind == KIND.folder and "" or " ")),
    }
  end
  -- Filter first, so that a file past the cap still comes up by name. A
  -- directory that matches has only matching files under it.
  for i, path in ipairs(list.paths) do
    if #items >= MAX_ITEMS then
      break
    end
    local lower = list.lower[i]
    if path:sub(1, #dir) == dir and has_chars(lower:sub(#dir + 1), query) then
      item(path, KIND.file)
      local sub = lower:sub(#dir + 1)
      local slash = sub:find("/", 1, true)
      while slash do
        local d = dir .. path:sub(#dir + 1, #dir + slash)
        if not dirs[d] and has_chars(sub:sub(1, slash), query) then
          dirs[d] = true
          item(d, KIND.folder)
        end
        slash = sub:find("/", slash + 1, true)
      end
    end
  end
  return items
end

function M.command_items(row, cursor)
  local items = {}
  for _, c in ipairs(M.commands) do
    local desc = c.description ~= "" and c.description or nil
    items[#items + 1] = {
      label = "/" .. c.name,
      filterText = c.name,
      kind = KIND.command,
      labelDetails = desc and { description = vim.fn.strcharpart(desc, 0, 48) } or nil,
      documentation = desc and {
        kind = "plaintext",
        value = desc .. (c.argument_hint and ("\n\n/" .. c.name .. " " .. c.argument_hint) or ""),
      } or nil,
      textEdit = edit(row, 0, cursor, "/" .. c.name .. " "),
    }
  end
  return items
end

---@return integer? at 1-based column of the `@`, string? token what follows it
local function at_token(before)
  local at, token = before:match("()@([^%s@]*)$")
  if at and (at == 1 or before:sub(at - 1, at - 1):match("%s")) then
    return at, token
  end
end

local function command_start(row, before)
  return row == 0 and before:match("^/[%w_:%-]*$") ~= nil
end

-- The prompt's blink.cmp providers. In a reference or a slash command, words
-- from the buffer are noise.
function M.providers()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local before = vim.api.nvim_get_current_line():sub(1, col)
  if at_token(before) or command_start(row - 1, before) then
    return { "anvim" }
  end
  return { "anvim", "path", "buffer" }
end

-- blink.cmp source

function M.new()
  return setmetatable({}, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "anvim_input"
end

function M:get_trigger_characters()
  return { "@", "/" }
end

function M:get_completions(ctx, callback)
  local row, cursor = ctx.cursor[1] - 1, ctx.cursor[2]
  local before = ctx.line:sub(1, cursor)
  local function done(items)
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  end
  if command_start(row, before) then
    return done(M.command_items(row, cursor))
  end
  local at, token = at_token(before)
  if at then
    return with_files(function(list)
      done(M.file_items(list, token, row, at - 1, cursor))
    end)
  end
  callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
end

function M.attach(sidecar)
  sidecar.on("init", function(ev)
    if #M.commands == 0 then
      M.commands = vim.tbl_map(function(name)
        return { name = name, description = "" }
      end, ev.slash_commands or {})
    end
  end)
  sidecar.on("commands", function(ev)
    M.commands = ev.commands or {}
  end)
  local function changed()
    stale = true
  end
  sidecar.on("turn_end", changed)
  vim.api.nvim_create_autocmd("FocusGained", {
    group = vim.api.nvim_create_augroup("anvim.completion", { clear = true }),
    callback = changed,
  })
end

return M
