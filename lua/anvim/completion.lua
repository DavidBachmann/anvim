-- Completion in the prompt and the compose window, in Neovim's own menu: as
-- the user types, files and directories after `@` and slash commands at the
-- start of the prompt. <C-Space> also gives words from the windows' buffers.
local state = require("anvim.state")

local M = {}

local api = vim.api

local MAX_ITEMS = 200
-- Entries, files and directories, that a walk of a project outside git visits.
local MAX_WALK = 20000
-- A list stays this long, even after files may have changed.
M.fresh_ms = 5000

---@class anvim.SlashCommand
---@field name string without the slash
---@field description string?
---@field argument_hint string?
---@field aliases string[]?
---@field builtin boolean? Claude Code's own command

---@type anvim.SlashCommand[]
M.commands = {}

-- The built-ins whose UX Claude Code binds to its terminal, from init's
-- terminal_slash_commands. Init comes with the first turn, so this build's
-- list stands in until then.
M.terminal = { "color", "doctor", "focus", "reload-plugins" }
-- Terminal-bound in Claude Code's list, but it works the same here: it loads
-- changed plugins into the session.
local works_here = { ["reload-plugins"] = true }
-- Built-ins that run only in a session that a server launched. Elsewhere they
-- print an error, and Claude Code's list does not say so.
local remote_only = { ["__remote-workflow"] = true, ["workflow-launch-exec"] = true }
-- Built-ins that start a billed review in the cloud. anvim starts none, so a
-- slip of Enter in the menu costs nothing.
local paid = { ultrareview = true }
local PAID = "anvim starts no paid cloud review. Run /ultrareview or /code-review ultra in Claude Code."
---@class anvim.FileList
---@field paths string[] relative to the cwd, shallow ones first
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
  return { paths = paths, at = vim.uv.now() }
end

-- Calls back with the project's files. The list is made again when files
-- may have changed, and not within fresh_ms.
local function with_files(cb)
  if files and not (stale and vim.uv.now() - files.at > M.fresh_ms) then
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

-- The candidates under one directory: each file's path below it, and the
-- directories on the way, which end in a slash. Shallow ones first.
---@type { list: anvim.FileList, dir: string, rests: string[] }?
local under

---@param list anvim.FileList
---@return string[]
local function rests(list, dir)
  if under and under.list == list and under.dir == dir then
    return under.rests
  end
  local out, depth, seen = {}, {}, {}
  local function add(rest)
    out[#out + 1] = rest
    depth[rest] = select(2, rest:gsub("/", ""))
  end
  for _, path in ipairs(list.paths) do
    if path:sub(1, #dir) == dir then
      local rest = path:sub(#dir + 1)
      add(rest)
      local slash = rest:find("/", 1, true)
      while slash do
        local d = rest:sub(1, slash)
        if not seen[d] then
          seen[d] = true
          add(d)
        end
        slash = rest:find("/", slash + 1, true)
      end
    end
  end
  table.sort(out, function(a, b)
    if depth[a] ~= depth[b] then
      return depth[a] < depth[b]
    end
    return a < b
  end)
  under = { list = list, dir = dir, rests = out }
  return out
end

-- mini.icons gives each row the icon that the explorer shows.
local function icon(path, is_dir)
  local ok, icons = pcall(require, "mini.icons")
  if ok then
    return icons.get(is_dir and "directory" or "file", path)
  end
end

-- The items for what follows an `@`. Neovim filters none of them (`equal`),
-- because they match fuzzily, which its prefix match would undo.
---@param list anvim.FileList
---@param token string what follows the `@`, such as lua/anvim/st
---@return table[] complete-items
function M.file_items(list, token)
  local dir = token:match("^(.*/)") or ""
  local query = token:sub(#dir + 1)
  local all = rests(list, dir)
  -- Match every path, so that a file past the cap still comes up by name:
  -- the limit of matchfuzzy() stops at the first matches. A lower case query
  -- matches either case. The menu gets the best matches only, because each
  -- item makes complete() slower.
  local picked = query == "" and vim.list_slice(all, 1, MAX_ITEMS)
    or vim.list_slice(vim.fn.matchfuzzy(all, query:lower()), 1, MAX_ITEMS)
  local items = {}
  for _, rest in ipairs(picked) do
    local path = dir .. rest
    local is_dir = rest:sub(-1) == "/"
    local glyph, hl = icon(path, is_dir)
    items[#items + 1] = {
      -- A directory goes on to its files, so it ends without a space.
      word = "@" .. path .. (is_dir and "" or " "),
      abbr = path,
      kind = glyph,
      kind_hlgroup = hl,
      equal = 1,
      user_data = { anvim = is_dir and "dir" or "file" },
    }
  end
  return items
end

-- Whether a command's hint names an argument that it needs, such as
-- `<instruction>`. Hints like `[name]` or `<optional ...>` need none.
local function needs_argument(hint)
  return type(hint) == "string" and hint ~= "" and not hint:match("^%[") and not hint:lower():find("optional")
end

-- The command that /name runs, as Claude Code picks it: Claude Code's own row
-- of that name, another row of that name, or the row that has it as an alias.
---@param name string without the slash
---@return anvim.SlashCommand?
local function resolve(name)
  local named, aliased
  for _, c in ipairs(M.commands) do
    if c.name == name and c.builtin then
      return c
    elseif c.name == name then
      named = named or c
    elseif vim.tbl_contains(c.aliases or {}, name) then
      aliased = aliased or c
    end
  end
  return named or aliased
end

-- Why the built-in `builtin` does nothing in anvim, or nil when it works
-- here. `typed` is the name or alias that the user typed.
---@return string?
local function refused(builtin, typed)
  if remote_only[builtin] then
    return ("/%s works only in sessions that a server launched."):format(typed)
  elseif vim.tbl_contains(M.terminal, builtin) and not works_here[builtin] then
    return ("/%s works only in Claude Code's terminal. Run `claude` for it."):format(typed)
  end
end

-- Why /name does nothing in anvim, or nil when it works here. Commands of
-- users, projects, plugins and skills always work. A paid review is refused
-- by its name, also before Claude Code's list came.
---@param name string without the slash
---@param arg string? the text after the name
---@return string?
function M.unusable(name, arg)
  local c = resolve(name)
  local first = (arg or ""):match("^%s*(%S*)"):lower()
  if paid[name] or c and paid[c.name] or (c and c.name or name) == "code-review" and first == "ultra" then
    return PAID
  end
  return c and c.builtin and refused(c.name, name) or nil
end

-- The items for a slash command, `query` being the typed name. They show the
-- description in the menu and, with the argument hint, in the info popup.
---@return table[] complete-items
function M.command_items(query)
  -- A row's own name runs Claude Code's row of that name, when it has one.
  local hidden = {}
  for _, c in ipairs(M.commands) do
    if paid[c.name] or c.builtin and refused(c.name, c.name) then
      hidden[c.name] = true
    end
  end
  local shown = vim.tbl_filter(function(c)
    return not hidden[c.name]
  end, M.commands)
  if query ~= "" then
    shown = vim.fn.matchfuzzy(shown, query:lower(), { key = "name" })
  end
  shown = vim.list_slice(shown, 1, MAX_ITEMS)
  local items = {}
  for _, c in ipairs(shown) do
    local desc = c.description ~= "" and c.description or nil
    items[#items + 1] = {
      word = "/" .. c.name .. " ",
      abbr = "/" .. c.name,
      menu = desc and vim.fn.strcharpart(desc, 0, 48) or nil,
      info = desc and desc .. (c.argument_hint and ("\n\n/" .. c.name .. " " .. c.argument_hint) or "") or nil,
      equal = 1,
      dup = 1,
      -- Enter sends it, as in Claude Code, unless it needs an argument.
      user_data = { anvim = "command", send = not needs_argument(c.argument_hint) },
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

-- What the text before the cursor completes: a file after `@` or a slash
-- command at the start of the prompt, from its 0-based start column. Nil for
-- words.
---@param row integer 0-based
---@return "file"|"command"|nil, integer? start, string? token
function M.context(row, before)
  local name = row == 0 and before:match("^/([%w_:%-]*)$")
  if name then
    return "command", 0, name
  end
  local at, token = at_token(before)
  if at then
    return "file", at - 1, token
  end
end

-- The characters of a word. Bytes from 128 on are the parts of UTF-8
-- characters, so words with letters such as ð stay whole.
local WORD_CHAR = "[%w_\128-\255]"
-- A buffer with more lines gives no words.
local MAX_LINES = 20000
---@type table<integer, { tick: integer, words: string[] }>
local word_cache = {}

-- The words of a buffer with at least two characters, in their order.
---@return string[]
local function buffer_words(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local cached = word_cache[buf]
  if cached and cached.tick == tick then
    return cached.words
  end
  local words, seen = {}, {}
  if api.nvim_buf_line_count(buf) <= MAX_LINES then
    for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      for word in line:gmatch(WORD_CHAR .. WORD_CHAR .. "+") do
        if not seen[word] then
          seen[word] = true
          words[#words + 1] = word
        end
      end
    end
  end
  word_cache[buf] = { tick = tick, words = words }
  return words
end

-- The words that start with the token, from the file buffers in the windows,
-- such as the code window. The prompt and the transcript give none: their
-- words would turn Enter after prose into a word. A lower case token matches
-- either case.
---@param token string the part of a word before the cursor
---@return table[] complete-items
function M.word_items(token)
  local bufs = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "" and not vim.tbl_contains(bufs, buf) then
      bufs[#bufs + 1] = buf
    end
  end
  for buf in pairs(word_cache) do
    if not api.nvim_buf_is_valid(buf) then
      word_cache[buf] = nil
    end
  end
  local lower = token == token:lower()
  local items, seen = {}, { [token] = true }
  for _, buf in ipairs(bufs) do
    for _, word in ipairs(buffer_words(buf)) do
      local head = word:sub(1, #token)
      if not seen[word] and (lower and head:lower() or head) == token then
        seen[word] = true
        items[#items + 1] = { word = word, equal = 1 }
        if #items >= MAX_ITEMS then
          return items
        end
      end
    end
  end
  return items
end

-- The text before the cursor in the current window, with row 0-based.
local function before_cursor()
  local row, col = unpack(api.nvim_win_get_cursor(0))
  return row - 1, api.nvim_get_current_line():sub(1, col)
end

-- Whether the user typed a character since the last update. Other changes,
-- such as a past prompt that <Up> brings back, open no menu.
local typed = false
-- The text before the cursor at the last update.
---@type string?
local updated_for
-- Whether the last update showed the menu.
local shown = false
-- Whether the menu shows words. Only <C-Space> opens it, and it then follows
-- the typed word.
local words = false

-- The kind of the menu, its 0-based start column and its items for the text
-- before the cursor.
---@param row integer 0-based
---@param manual? boolean From <C-Space>: words also without a typed part of one.
---@param more? boolean A word menu shows: words for a typed part of one.
---@return "file"|"command"|nil kind, integer start, table[] items
function M.items(row, before, manual, more)
  local kind, start, token = M.context(row, before)
  if kind == "command" then
    return kind, start, M.command_items(token)
  elseif kind == "file" then
    -- A stale list shows until the new one comes. Without a list, the menu
    -- opens once the first one comes.
    local buf, listed = api.nvim_get_current_buf(), files ~= nil
    with_files(function()
      if not listed then
        M.show(buf)
      end
    end)
    return kind, start, files and M.file_items(files, token) or {}
  end
  token = before:match(WORD_CHAR .. "*$")
  return nil, #before - #token, (manual or more and token ~= "") and M.word_items(token) or {}
end

-- Shows the menu for the text before the cursor, or closes it when nothing
-- matches. Neovim's 'autocomplete' always highlights no item ("noselect"),
-- and mixes the items of its sources. complete() with "noinsert" highlights
-- the first item, so that Enter takes it, as in Claude Code.
---@param manual? boolean
function M.update(manual)
  local row, before = before_cursor()
  local now = row .. ":" .. before
  -- Neovim ends the completion on each backspace, so a deletion while the
  -- menu showed opens it again.
  local deleted = shown and updated_for ~= nil and #now < #updated_for and updated_for:sub(1, #now) == now
  -- complete() fires TextChangedP, and so does <C-n>, which inserts its item.
  -- Neither is typing.
  if not (manual or typed or deleted) then
    return
  end
  typed, updated_for = false, now
  local kind, start, items = M.items(row, before, manual, words)
  shown = #items > 0
  words = shown and not kind
  if shown then
    vim.fn.complete(start + 1, items)
  elseif vim.fn.pumvisible() == 1 then
    vim.fn.complete(#before + 1, {})
  end
end

-- Opens the menu from the event loop, when the buffer is still in insert mode.
function M.show(buf)
  vim.schedule(function()
    if api.nvim_get_current_buf() == buf and api.nvim_get_mode().mode:sub(1, 1) == "i" then
      M.update(true)
    end
  end)
end

-- Whether <CR> takes the menu's highlighted item, and whether the prompt goes
-- out after it: a slash command that needs no argument does.
---@return boolean accept, boolean send
function M.enter()
  if vim.fn.pumvisible() == 0 then
    return false, false
  end
  local info = vim.fn.complete_info({ "selected", "completed" })
  if info.selected < 0 then
    return false, false
  end
  local data = info.completed and info.completed.user_data
  return true, type(data) == "table" and data.send == true
end

-- Completion for a buffer of the prompt's filetype.
function M.setup(buf)
  vim.bo[buf].completeopt = "menuone,noinsert,popup"
  local group = api.nvim_create_augroup("anvim.completion." .. buf, { clear = true })
  local function on(event, callback)
    api.nvim_create_autocmd(event, { group = group, buffer = buf, callback = callback })
  end
  on({ "TextChangedI", "TextChangedP" }, function()
    M.update()
  end)
  on("InsertCharPre", function()
    typed = true
  end)
  on("InsertEnter", function()
    typed, shown, words = false, false, false
    with_files(function() end)
  end)
  -- Insert mode goes on in a window that a key or a click enters, such as the
  -- compose window, and so would the completion. What the user typed here
  -- opens no menu there.
  on("WinLeave", function()
    typed, shown, words = false, false, false
    if api.nvim_get_mode().mode:sub(1, 1) == "i" and vim.fn.complete_info({ "mode" }).mode ~= "" then
      vim.fn.complete(vim.fn.col("."), {})
    end
  end)
  -- A taken or closed menu stays closed on a backspace. A directory goes on
  -- with its contents.
  on("CompleteDone", function()
    local reason = vim.v.event.reason
    shown = shown and reason ~= "accept" and reason ~= "cancel"
    words = words and shown
    local data = vim.v.completed_item.user_data
    if reason == "accept" and type(data) == "table" and data.anvim == "dir" then
      M.show(buf)
    end
  end)
  require("anvim.keys").set("prompt", "i", "<C-Space>", function()
    M.update(true)
  end, { buffer = buf })
end

function M.attach(sidecar)
  sidecar.on("init", function(ev)
    -- Claude Code leaves the list out when it is empty.
    M.terminal = ev.terminal_slash_commands or {}
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
  local group = api.nvim_create_augroup("anvim.completion", { clear = true })
  api.nvim_create_autocmd("FocusGained", { group = group, callback = changed })
  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "anvim_input",
    callback = function(ev)
      M.setup(ev.buf)
    end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "anvim_input" then
      M.setup(buf)
    end
  end
end

return M
