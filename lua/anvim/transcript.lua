-- The conversation view, drawn like Claude Code: user prompts, streamed
-- assistant text, and one line per tool call with its result below it.
local agents = require("anvim.agents")
local paths = require("anvim.paths")
local state = require("anvim.state")
local todos = require("anvim.todos")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.transcript")
-- Where Claude's text blocks start and end.
local ns_text = api.nvim_create_namespace("anvim.transcript.text")
local ns_focus = api.nvim_create_namespace("anvim.transcript.focus")
local ns_time = api.nvim_create_namespace("anvim.time")

-- The clock of the times that items show. Specs replace it.
M.clock = os.time

-- Whether the tool pane is on. Then the main agent's tool lines go to the
-- main log, apart from the chat, and the chat shows one count line for each
-- run of tool calls.
M.pane_on = false

-- Claude Code's verbose mode: tool lines show their whole input, and results
-- every line of their text, instead of the first line and a count.
M.verbose = false

---@class anvim.Run The tool calls between two other chat items.
---@field buf integer The chat buffer of the count line.
---@field mark integer? The mark of the count line.
---@field count integer
---@field failed integer
---@field time integer? When the first call started.
---@field stamp integer?

---@class anvim.Tool
---@field id string
---@field name string
---@field buf integer? The chat or the main log, where the tool's line is.
---@field run anvim.Run? The run that counts the call, for a call in the main log.
---@field failed boolean? The call failed, and its run counts it.
---@field mark integer?
---@field time integer? When the call started, as the clock or a saved session tells it.
---@field stamp integer? The mark that shows the time.
---@field input table?
---@field done boolean?
---@field outcome string[]?
---@field children string[]? Labels of a subagent's tool calls.
---@field head integer? Rows of the tool line, which a verbose label can have several of.
---@field body integer? Rows under the tool line: a subagent's calls, or the result.
---@field result { is_error: boolean, summary: string|string[], group: string?, label: string? }? As drawn, for a redraw.
---@field full string? The text whose first line the result shows.
---@field todo boolean? One of anvim's todo tools, which have no line. The todo list shows what they do.
---@field held boolean? A background agent's line, which lives on after its result.
---@field live boolean? Held for an agent of this sidecar, not of a resumed session's past.

---@type integer?
local bufnr
-- The main log, the buffer of the main agent's tool lines while they go apart.
---@type integer?
local logbuf
-- The open run, which the next tool call joins.
---@type anvim.Run?
local run
---@type table<string, anvim.Tool>
local tools = {}
-- The lines of background agents. Their tool call returns once the agent
-- starts, and the line lives on after the turn, until the agent ends.
---@type table<string, anvim.Tool>
local held = {}
-- The calls with a result, also of past turns, for a redraw in or out of
-- verbose mode.
---@type anvim.Tool[]
local drawn = {}
-- The guard's reason of each main agent's call that anvim sent back. The
-- event can come before the call's tool_start.
---@type table<string, string>
local sent_back = {}
local text_open = false
-- The blocks that other modules own, by the id of the extmark on their first
-- line. The buffer tells a block from a mark of a rebuilt transcript.
---@type table<integer, { buf: integer, count: integer }>
local blocks = {}
-- The todo list, while it is pinned. While it has open items it stays the
-- last item, as Claude Code keeps it under the spinner. New items go above it.
---@type { id: integer, lines: string[], marks: table[] }?
local todo
-- Claude's questions and the user's answers stay in the chat, also with the
-- tool pane on, as in Claude Code.
local chat_tools = { AskUserQuestion = true }
-- The text blocks since the last prompt or tool call: Claude's last reply.
local reply = {} ---@type string[]
local reply_done = true
-- Claude's text blocks, as pairs of extmarks in ns_text.
---@type { first: integer, last: integer }[]
local texts = {}
local regions_pending = false
-- Set while M.batch() draws many items at once.
local batch = false

local primary_arg = {
  Read = "file_path",
  Write = "file_path",
  Edit = "file_path",
  NotebookEdit = "notebook_path",
  Bash = "command",
  Grep = "pattern",
  Glob = "pattern",
  WebFetch = "url",
  WebSearch = "query",
  Task = "description",
  Agent = "description",
  Codex = "description",
  Skill = "skill",
}

-- With breakindentopt=list:-1, wrapped lines align after the bullet.
M.list_pat = [[^\s*\%(⏺\|❯\|⎿\|⚠\|✻\)\?\s*]]

function M.buf()
  if bufnr and api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].anvim_transcript then
    return bufnr
  end
  -- :bdelete keeps the buffer and its name, but clears its options and maps.
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr = api.nvim_create_buf(false, true)
  texts = {}
  vim.b[bufnr].anvim_transcript = true
  require("anvim.windows").stop_at_end(bufnr)
  api.nvim_buf_set_name(bufnr, "anvim://transcript")
  -- snacks.image would show the images of markdown links inline.
  vim.b[bufnr].snacks_image_attached = true
  vim.treesitter.language.register("markdown", "anvim_transcript")
  vim.bo[bufnr].filetype = "anvim_transcript"
  pcall(vim.treesitter.start, bufnr, "markdown")
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].formatlistpat = M.list_pat
  -- The cursor is here only in read mode. Insert commands go back to typing.
  local layout = require("anvim.layout")
  local keys = require("anvim.keys")
  for _, key in ipairs({ "q", "<Esc>" }) do
    keys.set("transcript", "n", key, function()
      -- The Agent Overview shows the transcript as Claude's conversation.
      local overview = require("anvim.overview")
      if overview.owns(api.nvim_get_current_win()) then
        overview.close()
      else
        layout.focus_input({ insert = false })
      end
    end, { buffer = bufnr })
  end
  for _, key in ipairs(layout.insert_keys) do
    keys.set("transcript", "n", key, layout.focus_input, { buffer = bufnr })
  end
  keys.set("transcript", "x", "<LeftRelease>", function()
    return "<LeftRelease><Cmd>lua require('anvim.windows').copy()<CR>"
  end, { buffer = bufnr, expr = true })
  return bufnr
end

---@return integer? buf The main log, if it exists.
local function log_loaded()
  return logbuf and api.nvim_buf_is_loaded(logbuf) and vim.b[logbuf].anvim_tool_log and logbuf or nil
end

-- The main log: the main agent's tool calls while they go apart from the chat.
function M.log_buf()
  if log_loaded() then
    return logbuf
  end
  if logbuf and api.nvim_buf_is_valid(logbuf) then
    pcall(api.nvim_buf_delete, logbuf, { force = true })
  end
  logbuf = api.nvim_create_buf(false, true)
  vim.b[logbuf].anvim_tool_log = true
  require("anvim.windows").stop_at_end(logbuf)
  api.nvim_buf_set_name(logbuf, "anvim://tools")
  vim.bo[logbuf].modifiable = false
  vim.bo[logbuf].formatlistpat = M.list_pat
  return logbuf
end

-- Windows that show the transcript, or `buf`, except the one the user is in.
-- With `tail`, only those whose view reaches the end: new output keeps them
-- there, and leaves a window that the user scrolled up alone.
---@param buf integer?
local function follow_wins(tail, buf)
  buf = buf or M.buf()
  local last = api.nvim_buf_line_count(buf)
  local wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if
      win ~= api.nvim_get_current_win()
      and (not tail or api.nvim_win_get_cursor(win)[1] == last or vim.fn.line("w$", win) >= last)
    then
      wins[#wins + 1] = win
    end
  end
  return wins
end

---@param buf integer?
local function scroll(wins, buf)
  local last = api.nvim_buf_line_count(buf or M.buf())
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_set_cursor(win, { last, 0 })
    end
  end
end

M.follow_wins, M.scroll = follow_wins, scroll

local block_row

-- Markdown parses only Claude's text and the blocks that ask for it, such as
-- a plan. In tool lines, results, prompts and the choices of a request,
-- markers like ** and [x] stay as they are.
local function set_regions()
  regions_pending = false
  -- Not M.buf(), which would make a new buffer, as while Neovim quits.
  local buf = bufnr
  if not (buf and api.nvim_buf_is_loaded(buf)) then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not (ok and parser) then
    return
  end
  local regions = {}
  for _, t in ipairs(texts) do
    local first = api.nvim_buf_get_extmark_by_id(buf, ns_text, t.first, {})
    local last = api.nvim_buf_get_extmark_by_id(buf, ns_text, t.last, {})
    if first[1] and last[1] then
      regions[#regions + 1] = { { first[1], first[2], last[1], last[2] } }
    end
  end
  for id, block in pairs(blocks) do
    local row = block.markdown and block.buf == buf and api.nvim_buf_get_extmark_by_id(buf, ns, id, {})[1]
    if row then
      local last = row + block.count - 1
      local line = api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
      regions[#regions + 1] = { { row, 0, last, #line } }
    end
  end
  table.sort(regions, function(a, b)
    return a[1][1] < b[1][1]
  end)
  -- No regions at all would keep the old child trees.
  parser:set_included_regions(#regions > 0 and regions or { { { 0, 0, 0, 0 } } })
end

local function regions_later()
  if not regions_pending then
    regions_pending = true
    vim.schedule(set_regions)
  end
end

---@param buf integer? The chat by default.
local function with_modifiable(fn, buf)
  buf = buf or M.buf()
  local tail = not batch and follow_wins(true, buf)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = false
  if tail then
    scroll(tail, buf)
  end
  -- Lines that go from the end, such as an answered request's, do not scroll
  -- a window, so no WinScrolled fires.
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    require("anvim.windows").clamp(win)
  end
  if buf == bufnr then
    regions_later()
  end
  if not ok then
    error(err, 0)
  end
end

local function is_empty(buf)
  return api.nvim_buf_line_count(buf) == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

-- Where new output ends: before the pinned todo list and its blank line.
local function end_row(buf)
  local row = todo and block_row(todo.id)
  if not row then
    return api.nvim_buf_line_count(buf)
  end
  return math.max(row - 1, 0)
end

-- Appends lines as a new item, one blank line after the previous item. With
-- `last`, the item goes after the pinned todo list too.
---@return integer row 0-based row of the first appended line
local function append_item(lines, last)
  local row
  with_modifiable(function(buf)
    local stop = last and api.nvim_buf_line_count(buf) or end_row(buf)
    if is_empty(buf) then
      row = 0
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    elseif stop == 0 then
      -- The todo list is the first item.
      row = 0
      api.nvim_buf_set_lines(buf, 0, 0, false, vim.list_extend(vim.list_slice(lines), { "" }))
    else
      row = stop + 1
      api.nvim_buf_set_lines(buf, stop, stop, false, { "", unpack(lines) })
    end
  end)
  return row
end

local function hl(buf, row, col, end_col, group, opts)
  return api.nvim_buf_set_extmark(
    buf,
    ns,
    row,
    col,
    vim.tbl_extend("force", { end_col = end_col, hl_group = group, priority = 200 }, opts or {})
  )
end

-- The text of each time, by buffer and by the id of the mark on its row.
---@type table<integer, table<integer, string>>
local stamps = {}

-- Gives a row a time, which shows at the right edge of the row's last screen
-- line where it fits. The mark goes when its line goes, so a caller that
-- replaces the line stamps it again.
---@param time integer? As M.clock() gives it.
---@param id integer? The mark of the time to show again.
---@return integer? id
function M.stamp(buf, row, time, id)
  if not time then
    return nil
  end
  id = api.nvim_buf_set_extmark(buf, ns_time, row, 0, { id = id, invalidate = true, undo_restore = false })
  if not stamps[buf] then
    -- The buffers of agent logs that went.
    for b in pairs(stamps) do
      if not api.nvim_buf_is_loaded(b) then
        stamps[b] = nil
      end
    end
    stamps[buf] = {}
  end
  stamps[buf][id] = os.date("%H:%M:%S", time) --[[@as string]]
  return id
end

-- Drops the times of rows first to last - 1, of lines that go. A `last` of
-- -1 is the end.
function M.unstamp(buf, first, last)
  local times = stamps[buf] or {}
  local stop = last < 0 and -1 or { last - 1, -1 }
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns_time, { first, 0 }, stop, {})) do
    times[mark[1]] = nil
  end
  api.nvim_buf_clear_namespace(buf, ns_time, first, last)
end

---@return string? time The time of a row, as it shows where it fits.
function M.time_of(buf, row)
  local mark = api.nvim_buf_get_extmarks(buf, ns_time, { row, 0 }, { row, 0 }, { limit = 1 })[1]
  return mark and (stamps[buf] or {})[mark[1]]
end

-- Whether `cells` more cells fit on the last screen line of a row in `win`,
-- after the line's end and its other end of line marks. Neovim draws those
-- marks one cell apart, after the cell of the line's end. Concealed text only
-- makes a screen line shorter, so the check is too strict there, never too
-- loose. Only reads, as a decoration provider may.
local function fits(win, buf, row, cells)
  local size = api.nvim_win_text_height(win, { start_row = row, end_row = row })
  if size.all - size.fill < 1 then
    return false
  end
  -- end_vcol is the line's width in cells, wrap padding and indent included.
  local last = size.end_vcol + cells
  local opts = { details = true, type = "virt_text" }
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, opts)) do
    if mark[4].virt_text_pos == "eol" then
      for _, chunk in ipairs(mark[4].virt_text) do
        last = last + api.nvim_strwidth(chunk[1])
      end
      last = last + 1
    end
  end
  -- From the screen line of the time's last cell to the line's end: one
  -- screen line when that is the last one.
  return api.nvim_win_text_height(win, { start_row = row, end_row = row, start_vcol = last }).all == 1
end

-- Each window draws a time only where it fits whole. A cut time would read
-- as another time, and a buffer can show at several widths at once.
api.nvim_set_decoration_provider(ns_time, {
  on_win = function(_, _, buf)
    return stamps[buf] ~= nil and next(stamps[buf]) ~= nil
  end,
  -- A range holds the line ends of rows from_row to to_row - 1, because its
  -- end is exclusive. It can start in the middle of its first row, after the
  -- row's mark.
  on_range = function(_, win, buf, from_row, from_col, to_row)
    if to_row <= from_row then
      return
    end
    local times = stamps[buf] or {}
    -- The tool pane has a margin on both sides, against its own background.
    local margin = win == require("anvim.layout").wins.pane and " " or ""
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns_time, { from_row, 0 }, { to_row - 1, 0 }, {})) do
      local row, time = mark[2], times[mark[1]]
      time = time and time .. margin
      if time and fits(win, buf, row, api.nvim_strwidth(time)) then
        api.nvim_buf_set_extmark(buf, ns_time, row, row == from_row and from_col or 0, {
          ephemeral = true,
          virt_text = { { time, "AnvimTime" } },
          virt_text_pos = "eol_right_align",
          hl_mode = "combine",
          -- Neovim draws end of line marks from low to high priority, and a
          -- mark after this one finds no room. "◉ focused" has the default, 4096.
          priority = 4097,
        })
      end
    end
  end,
})

-- The time of the history event that M.batch() draws, as Claude Code saved it.
---@type integer?
local past_time

-- Sets the time of the items that M.batch() draws next.
---@param time integer?
function M.batch_time(time)
  past_time = type(time) == "number" and time or nil
end

-- Live items get the clock's time, and a resumed session's items the time
-- that Claude Code saved with them.
local function now()
  if batch then
    return past_time
  end
  return M.clock()
end

local function first_line(text)
  local lines = vim.split(vim.trim(text or ""), "\n", { plain = true })
  local line = lines[1] or ""
  if #lines > 1 then
    line = ("%s ... +%d lines"):format(line, #lines - 1)
  end
  return line
end

---@type { cwd: string, forms: string[] }?
local forms_of

-- The cwd as Claude may write it, the longer form first: on macOS, /tmp and
-- /var are links into /private.
local function cwd_forms()
  if forms_of and forms_of.cwd == state.cwd then
    return forms_of.forms
  end
  local real = vim.uv.fs_realpath(state.cwd) or state.cwd
  local forms = { real }
  for _, form in ipairs({ state.cwd, real:match("^/private(/.+)") }) do
    if not vim.tbl_contains(forms, form) then
      forms[#forms + 1] = form
    end
  end
  table.sort(forms, function(a, b)
    return #a > #b
  end)
  forms_of = { cwd = state.cwd, forms = forms }
  return forms
end

local path_char = "[%w_%.%-/~]"

-- Writes paths under the cwd short, as in a command run from there: files
-- relative to it, and the cwd itself as ".".
---@param text string
---@return string
function M.short(text)
  for _, dir in ipairs(cwd_forms()) do
    -- In /, every path would match.
    if dir == "/" then
      break
    end
    local out, i = {}, 1
    while true do
      local s, e = text:find(dir, i, true)
      if not s then
        break
      end
      local after = text:sub(e + 1, e + 1)
      -- Part of a longer path, such as /x/<cwd>, stays as it is.
      local inside = s > 1 and text:sub(s - 1, s - 1):match(path_char)
      if not inside and after == "/" and text:sub(e + 2, e + 2):match("[^%s'\"]") then
        out[#out + 1] = text:sub(i, s - 1)
        e = e + 1
      elseif not inside and not after:match(path_char) then
        out[#out + 1] = text:sub(i, s - 1) .. "."
      else
        out[#out + 1] = text:sub(i, e)
      end
      i = e + 1
    end
    out[#out + 1] = text:sub(i)
    text = table.concat(out)
  end
  return text
end

-- With `full`, the argument keeps all of its lines and length.
---@param full boolean?
local function tool_label(name, input, full)
  if name == agents.codex_tool then
    name = "Codex"
  end
  local mcp_server, mcp_tool = name:match("^mcp__(.-)__(.+)$")
  if mcp_server == "anvim" then
    return require("anvim.tools").label(mcp_tool, input)
  elseif mcp_server == "claude-in-chrome" then
    return require("anvim.chrome").label(mcp_tool, input)
  elseif mcp_server then
    name = ("%s:%s"):format(mcp_server, mcp_tool)
  end
  if not input then
    return name
  end
  local key = primary_arg[name]
  local arg = key and input[key]
  -- Claude Code names a subagent by its type, such as Explore.
  local agent = (name == "Agent" or name == "Task") and input.subagent_type
  if type(agent) == "string" and agent ~= "" and agent ~= "general-purpose" then
    name = agent
  end
  if arg == nil then
    for _, v in pairs(input) do
      if type(v) == "string" then
        arg = v
        break
      end
    end
  end
  if type(arg) ~= "string" then
    return name
  end
  if key == "file_path" or key == "notebook_path" then
    arg = paths.display(arg)
  else
    arg = M.short(arg)
  end
  if not full then
    arg = arg:gsub("\n.*", "...")
    if #arg > 80 then
      arg = arg:sub(1, 79) .. "..."
    end
  end
  return ("%s(%s)"):format(name, arg)
end

M.label = tool_label

-- The rows of a tool line. A verbose label can have several lines.
---@param label string
---@return string[]
function M.head_rows(label)
  local lines = vim.split(label, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "⏺ " or "  ") .. line
  end
  return lines
end

-- The rows of a result: its summary, or in verbose mode every line of the
-- text that the summary is the first line of.
---@param summary string|string[]
---@param full string?
---@return string[]
function M.result_rows(summary, full)
  local rows = type(summary) == "table" and summary or { summary }
  if M.verbose and full then
    rows = vim.split((full:gsub("^%s*\n", ""):gsub("%s+$", "")), "\n", { plain = true })
  end
  local lines = {}
  for i, text in ipairs(rows) do
    lines[i] = (i == 1 and "  ⎿  " or "     ") .. M.short(text)
  end
  return lines
end

local function patch_counts(patch)
  local added, removed = 0, 0
  for _, hunk in ipairs(patch or {}) do
    for _, line in ipairs(hunk.lines or {}) do
      local c = line:sub(1, 1)
      if c == "+" then
        added = added + 1
      elseif c == "-" then
        removed = removed + 1
      end
    end
  end
  return added, removed
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- Line counts of an edit from its input. Saved sessions keep no patch.
local function diff_counts(old, new)
  local added, removed = 0, 0
  local ok, hunks = pcall(vim.text.diff, old .. "\n", new .. "\n", { result_type = "indices" })
  for _, h in ipairs(ok and hunks or {}) do
    removed, added = removed + h[2], added + h[4]
  end
  return added, removed
end

local function line_count(text)
  return select(2, text:gsub("\n", "")) + (text:match("[^\n]$") and 1 or 0)
end

-- As Claude Code writes them: 24.1k tokens, 2.8s, 1m 12s.
local function tokens(n)
  return n < 1000 and tostring(n) or ("%.1fk"):format(n / 1000)
end

-- 2.8s, 1m 12s, 1h 5m 3s. A time that counts up each second, such as the
-- spinner's, is `whole`: 12s.
---@param whole boolean?
local function duration(ms, whole)
  local s = ms / 1000
  -- 59.96 s would round to "60.0s".
  if s < (whole and 60 or 59.95) then
    return whole and ("%ds"):format(math.floor(s)) or ("%.1fs"):format(s)
  end
  s = math.max(math.floor(s), 60)
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  if h > 0 then
    return ("%dh %dm %ds"):format(h, m, s % 60)
  end
  return ("%dm %ds"):format(m, s % 60)
end

local function agent_done(tool, r)
  local count = tonumber(r.totalToolUseCount) or (tool.children and #tool.children)
  if not count then
    return "Done"
  end
  local parts = { count == 1 and "1 tool use" or ("%d tool uses"):format(count) }
  if tonumber(r.totalTokens) then
    parts[#parts + 1] = tokens(r.totalTokens) .. " tokens"
  end
  if tonumber(r.totalDurationMs) then
    parts[#parts + 1] = duration(r.totalDurationMs)
  end
  return ("Done (%s)"):format(table.concat(parts, " · "))
end

M.agent_done, M.tokens, M.duration = agent_done, tokens, duration

-- Whether a failed call's text is a send-back's hint, as a resumed session
-- keeps it. In bypass mode Claude Code puts the hook's words before it.
local function held_back(ev)
  local text = type(ev.text) == "string" and ev.text or ""
  return text:find("^anvim held this ") ~= nil or text:find("^PreToolUse:%w+ hook error: anvim held this ") ~= nil
end

M.held_back = held_back

local function summarize(tool, ev)
  if tool.outcome then
    return tool.outcome[1], tool.outcome[2]
  elseif ev.is_error and held_back(ev) then
    return "Sent back to Claude"
  elseif ev.is_error then
    return first_line(ev.text), "AnvimToolError", ev.text
  end
  local r = type(ev.result) == "table" and ev.result or {}
  local name, input = tool.name, tool.input or {}
  local editor_tool = name:match("^mcp__anvim__(.+)$")
  if agents.spawns(name) then
    return agent_done(tool, r)
  elseif editor_tool then
    return require("anvim.tools").summary(editor_tool, input, ev.text)
  elseif name == "Read" and r.file and r.file.numLines then
    return "Read " .. plural(r.file.numLines, "line")
  elseif name == "Write" and (r.type == "create" or (not r.structuredPatch and type(input.content) == "string")) then
    return "Wrote " .. plural(line_count(input.content or ""), "line")
  elseif (name == "Edit" or name == "Write") and r.structuredPatch then
    local added, removed = patch_counts(r.structuredPatch)
    return ("Added %s, removed %s"):format(plural(added, "line"), plural(removed, "line"))
  elseif name == "Edit" and type(input.old_string) == "string" and type(input.new_string) == "string" then
    local added, removed = diff_counts(input.old_string, input.new_string)
    return ("Added %s, removed %s"):format(plural(added, "line"), plural(removed, "line"))
  end
  local text = ev.text
  if name == "Bash" and type(r.stdout) == "string" then
    text = r.stdout ~= "" and r.stdout or r.stderr or ""
  end
  local line = first_line(text)
  -- Verbose mode shows what Claude got, stderr too.
  local full = type(ev.text) == "string" and ev.text:find("%S") and ev.text or text
  return line ~= "" and line or "Done", nil, line ~= "" and full or nil
end

-- The result line of a tool call, its group when it is not AnvimResult, and
-- the text that verbose mode shows in full.
---@param tool { name: string, input: table?, outcome: string[]?, children: string[]? }
---@return string text, string? group, string? full
M.summary = summarize

-- The row of a mark, unless its buffer or the mark went.
local function mark_row(buf, id)
  if id and api.nvim_buf_is_loaded(buf) then
    return api.nvim_buf_get_extmark_by_id(buf, ns, id, {})[1]
  end
end

local function tool_row(tool)
  return mark_row(tool.buf, tool.mark)
end

-- Appends a tool line to the main log. The calls of a run follow each other,
-- and a blank line starts a run. The prompts stay in the chat.
---@return integer row
local function log_append(line, starts_run)
  local buf, row = M.log_buf(), 0
  local lines = { line }
  with_modifiable(function()
    if is_empty(buf) then
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return
    elseif starts_run then
      table.insert(lines, 1, "")
    end
    row = api.nvim_buf_line_count(buf)
    api.nvim_buf_set_lines(buf, row, row, false, lines)
  end, buf)
  return row + #lines - 1
end

-- The count line of a run, such as "⎿  7 tool calls · 1 failed". The first
-- call of a run appends it to the chat, and later calls set it again.
---@param r anvim.Run
local function set_count(r)
  local line = "  ⎿  " .. plural(r.count, "tool call")
  local failed = r.failed > 0 and (" · %d failed"):format(r.failed) or ""
  local row = mark_row(r.buf, r.mark)
  if r.mark and not row then
    return
  elseif row then
    with_modifiable(function(buf)
      api.nvim_buf_set_lines(buf, row, row + 1, false, { line .. failed })
    end, r.buf)
    api.nvim_buf_clear_namespace(r.buf, ns, row, row + 1)
  else
    row = append_item({ line .. failed })
  end
  r.mark = hl(r.buf, row, 0, #line, "AnvimResult")
  if failed ~= "" then
    hl(r.buf, row, #line, #line + #failed, "AnvimToolError")
  end
  r.stamp = M.stamp(r.buf, row, r.time, r.stamp)
end

-- A call of the main agent joins the open run, or starts one.
local function join_run(tool)
  if not run then
    run = { buf = M.buf(), count = 0, failed = 0, time = tool.time }
  end
  run.count = run.count + 1
  tool.run = run
  set_count(run)
end

-- The bullet of a tool call that has no result yet. An Agent call's bullet
-- takes its agent's color while the agent runs.
local function pending(tool)
  local agent = agents.spawns(tool.name) and agents.by_tool(tool.id)
  return agent and agent.status == "running" and agents.group(agent.slot) or "AnvimToolPending"
end

---@param label string? The call's label by default.
local function set_tool_line(tool, label, bullet_hl)
  local row = tool_row(tool)
  if not row then
    return
  end
  label = label or tool_label(tool.name, tool.input, M.verbose)
  local lines = M.head_rows(label)
  local buf = tool.buf
  with_modifiable(function()
    api.nvim_buf_set_lines(buf, row, row + (tool.head or 1), false, lines)
  end, buf)
  tool.head = #lines
  local bullet = #"⏺"
  api.nvim_buf_clear_namespace(buf, ns, row, row + #lines)
  tool.mark = hl(buf, row, 0, bullet, bullet_hl)
  local name_end = label:find("(", 1, true)
  hl(buf, row, bullet + 1, bullet + 1 + (name_end and name_end - 1 or #label), "AnvimToolName")
  tool.stamp = M.stamp(buf, row, tool.time, tool.stamp)
end

function M.user(text)
  -- A turn without text has no reply, rather than the last turn's.
  text_open, reply_done, reply, run = false, true, {}, nil
  -- A message that anvim sends Claude names the tool that it comes from. The
  -- user did not write it, so it is a notice.
  local meta = text:match("^%[[^%]]*%]%(mcp__anvim__[%w_]+%): (.*)")
  if meta then
    M.notice("info", meta)
  else
    local lines = vim.split(text, "\n", { plain = true })
    for i, line in ipairs(lines) do
      lines[i] = (i == 1 and "❯ " or "  ") .. line
    end
    local row = append_item(lines)
    local buf = M.buf()
    for i = 0, #lines - 1 do
      api.nvim_buf_set_extmark(buf, ns, row + i, 0, { line_hl_group = "AnvimUser" })
    end
    hl(buf, row, 0, #"❯", "AnvimPrompt")
    M.stamp(buf, row, now())
  end
  -- A new prompt brings every view back to the end.
  if not batch then
    scroll(follow_wins(false))
    local log = log_loaded()
    if log then
      scroll(follow_wins(false, log), log)
    end
  end
end

function M.text_start()
  text_open, run = true, nil
  if reply_done then
    reply, reply_done = {}, false
  end
  reply[#reply + 1] = ""
  local row = append_item({ "⏺ " })
  hl(M.buf(), row, 0, #"⏺", "AnvimBullet")
  M.stamp(M.buf(), row, now())
  -- The end mark moves with the text that streams in after it.
  local col = #"⏺ "
  texts[#texts + 1] = {
    first = api.nvim_buf_set_extmark(M.buf(), ns_text, row, col, { right_gravity = false }),
    last = api.nvim_buf_set_extmark(M.buf(), ns_text, row, col, { right_gravity = true }),
  }
end

function M.text_delta(text)
  if not text_open then
    M.text_start()
  end
  reply[#reply] = reply[#reply] .. text
  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = "  " .. parts[i]
  end
  with_modifiable(function(buf)
    local last = end_row(buf) - 1
    local col = #api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
    api.nvim_buf_set_text(buf, last, col, last, col, parts)
  end)
end

function M.text_stop()
  text_open = false
end

---@return string
function M.last_reply()
  return vim.trim(table.concat(reply, "\n\n"))
end

function M.tool_start(id, name)
  text_open, reply_done = false, true
  if todos.tools[name] then
    tools[id] = { id = id, name = name, todo = true }
    return
  end
  local label = tool_label(name)
  local tool = { id = id, name = name, time = now() }
  local row
  if M.pane_on and not chat_tools[name] then
    -- A run whose chat buffer went, as after :bwipeout, ends with it.
    if run and not api.nvim_buf_is_loaded(run.buf) then
      run = nil
    end
    tool.buf = M.log_buf()
    row = log_append("⏺ " .. label, run == nil)
    join_run(tool)
  else
    -- A call in the chat ends the run, so that calls after it count anew.
    tool.buf, run = M.buf(), nil
    row = append_item({ "⏺ " .. label })
  end
  tool.mark = hl(tool.buf, row, 0, #"⏺", pending(tool))
  tools[id] = tool
  hl(tool.buf, row, #"⏺" + 1, #"⏺" + 1 + #label, "AnvimToolName")
  tool.stamp = M.stamp(tool.buf, row, tool.time)
end

function M.tool_field(ev)
  local tool = tools[ev.id]
  if tool and not tool.todo and ev.phase == "end" and ev.key == primary_arg[tool.name] then
    set_tool_line(tool, tool_label(tool.name, { [ev.key] = ev.value }, M.verbose), pending(tool))
  end
end

-- A subagent's tool calls, under its tool line: the last three, and a count of
-- the others, as in Claude Code. A background agent's line says so first.
local function set_children(tool)
  local row = tool_row(tool)
  if not row then
    return
  end
  local children = tool.children or {}
  local n = #children
  local items = tool.held and { "Backgrounded agent" } or {}
  for i = math.max(1, n - 2), n do
    items[#items + 1] = children[i]
  end
  if n > 3 then
    items[#items + 1] = ("+%d more tool use%s"):format(n - 3, n - 3 == 1 and "" or "s")
  end
  local lines = {}
  for i, item in ipairs(items) do
    lines[i] = (i == 1 and "  ⎿  " or "     ") .. item
  end
  local first, old = row + (tool.head or 1), tool.body or 0
  api.nvim_buf_clear_namespace(tool.buf, ns, first, first + old)
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, first, first + old, false, lines)
  end, tool.buf)
  tool.body = #lines
  for i, line in ipairs(lines) do
    hl(tool.buf, first + i - 1, 0, #line, "AnvimResult")
  end
end

local function child(ev)
  local parent = tools[ev.parent_id] or held[ev.parent_id]
  if parent and parent.mark and not parent.done then
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = tool_label(ev.name, ev.input)
    set_children(parent)
  end
end

function M.tool_use(ev)
  if ev.parent_id then
    child(ev)
    return
  end
  local tool = tools[ev.id]
  if not tool then
    M.tool_start(ev.id, ev.name)
    tool = tools[ev.id]
  end
  tool.input = ev.input
  if tool.todo then
    return
  end
  set_tool_line(tool, nil, pending(tool))
end

-- Draws a call's result, also again for a redraw.
---@param summary string|string[] The result line, or its lines.
---@param label string? The tool line's text, when it is not the call.
local function finish_tool(tool, is_error, summary, group, label)
  tool.done = true
  if not tool.result then
    drawn[#drawn + 1] = tool
  end
  tool.result = { is_error = is_error, summary = summary, group = group, label = label }
  if is_error and tool.run and not tool.failed then
    tool.failed = true
    tool.run.failed = tool.run.failed + 1
    set_count(tool.run)
  end
  set_tool_line(tool, label, is_error and "AnvimToolError" or "AnvimToolOk")
  local row = tool_row(tool)
  if not row then
    return
  end
  local lines = M.result_rows(summary, tool.full)
  local first, old = row + tool.head, tool.body or 0
  api.nvim_buf_clear_namespace(tool.buf, ns, first, first + old)
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, first, first + old, false, lines)
  end, tool.buf)
  tool.body = #lines
  for i, line in ipairs(lines) do
    hl(tool.buf, first + i - 1, 0, #line, group or "AnvimResult")
  end
end

-- Each question with its answer, as Claude Code shows them. A saved session
-- keeps only the text that Claude got, so its result line is that text.
local function finish_question(tool, ev)
  local r = type(ev.result) == "table" and ev.result or {}
  local input = type(tool.input) == "table" and tool.input or {}
  local answers = type(r.answers) == "table" and r.answers or {}
  local rows = {}
  for _, q in ipairs(type(r.questions) == "table" and r.questions or input.questions or {}) do
    local question = q.question:gsub("\n", " ")
    if ev.is_error then
      local labels = vim.tbl_map(function(opt)
        return opt.label
      end, q.options or {})
      rows[#rows + 1] = ("· %s (%s)"):format(question, table.concat(labels, " / "))
    elseif type(answers[q.question]) == "string" then
      local parts = vim.split(answers[q.question], "\n", { plain = true })
      rows[#rows + 1] = ("· %s → %s"):format(question, parts[1])
      for i = 2, #parts do
        rows[#rows + 1] = "  " .. parts[i]
      end
    end
  end
  if ev.is_error then
    finish_tool(tool, true, rows, nil, "User declined to answer questions")
  elseif #rows > 0 then
    finish_tool(tool, false, rows, nil, "User answered Claude's questions:")
  else
    local text, group, full = summarize(tool, ev)
    tool.full = full
    finish_tool(tool, false, text, group)
  end
end

-- A background agent's tool call returns as the agent starts. A saved
-- session keeps no result, but the text says so. A Codex agent always runs
-- in the background.
local function launched(tool, ev)
  local r = type(ev.result) == "table" and ev.result or {}
  return agents.spawns(tool.name)
    and not ev.is_error
    and (
      tool.name == agents.codex_tool
      or r.status == "async_launched"
      or (ev.result == nil and (ev.text or ""):find("^Async agent launched") ~= nil)
    )
end

function M.tool_result(ev)
  local tool = tools[ev.id]
  local reason = sent_back[ev.id]
  sent_back[ev.id] = nil
  if tool and reason then
    tool.outcome = { "Sent back to Claude: " .. reason }
  end
  if tool and tool.todo then
    tool.done = true
  elseif tool and not (tool.done or tool.held) then
    if tool.name == "AskUserQuestion" then
      finish_question(tool, ev)
    elseif launched(tool, ev) then
      tool.held, tool.live = true, agents.by_tool(tool.id) ~= nil
      held[tool.id] = tool
      set_children(tool)
    else
      local text, group, full = summarize(tool, ev)
      tool.full = full
      finish_tool(tool, ev.is_error, text, group)
    end
  end
end

local ended = { completed = "finished", failed = "failed", stopped = "was stopped" }

-- A background agent ended. Its line gets its result, and a row at the end
-- says so where the user reads, as Claude Code shows the notification.
---@param tool anvim.Tool? Its line, unless the transcript lacks it.
---@param ev { status: string?, summary: string?, description: string?, tool_uses: integer?, tokens: integer?, duration_ms: integer? }
local function end_agent(tool, ev)
  local ok = ev.status == "completed"
  local description = ev.description
  if tool then
    held[tool.id] = nil
    local input = type(tool.input) == "table" and tool.input or {}
    description = type(input.description) == "string" and input.description or description
    local usage = { totalToolUseCount = ev.tool_uses, totalTokens = ev.tokens, totalDurationMs = ev.duration_ms }
    finish_tool(tool, not ok, ok and agent_done(tool, usage) or ev.status == "stopped" and "Stopped" or "Failed")
  end
  text_open, run = false, nil
  local name = description and description ~= "" and ('Agent "%s"'):format(description) or "Agent"
  local lines = { ("⏺ %s %s"):format(name, ended[ev.status] or "ended") }
  local summary = M.short(first_line(ev.summary))
  if summary ~= "" then
    lines[2] = "  ⎿  " .. summary
  end
  local row = append_item(lines)
  local buf = M.buf()
  hl(buf, row, 0, #"⏺", ok and "AnvimToolOk" or "AnvimToolError")
  for i, line in ipairs(lines) do
    hl(buf, row + i - 1, i == 1 and #"⏺" or 0, #line, "AnvimResult")
  end
  M.stamp(buf, row, now())
end

-- A background agent's end in a resumed session's past.
function M.agent_end(ev)
  end_agent(ev.tool_use_id and held[ev.tool_use_id], ev)
end

-- After a resumed session draws, a background agent of its past whose end was
-- not saved stops looking busy. Its line keeps "Backgrounded agent".
function M.settle_past()
  for id, tool in pairs(held) do
    if not tool.live then
      held[id], tool.done = nil, true
      set_tool_line(tool, nil, "AnvimResult")
    end
  end
end

-- Agents started, ended or changed slots, or the focus moved. A background
-- agent's line ends with its agent. The focused agent's line says so at its
-- end. Its mark keeps its row when the line is set again, because it stays
-- left of inserted text.
local function paint_agents()
  for id, tool in pairs(held) do
    local agent = agents.by_tool(id)
    if agent and agent.status ~= "running" then
      end_agent(tool, vim.tbl_extend("force", agent.usage or {}, { status = agent.status, summary = agent.summary }))
    end
  end
  for _, list in ipairs({ tools, held }) do
    for _, tool in pairs(list) do
      local row = agents.spawns(tool.name) and tool.mark and not tool.done and tool_row(tool)
      if row then
        tool.mark = hl(tool.buf, row, 0, #"⏺", pending(tool), { id = tool.mark })
      end
    end
  end
  api.nvim_buf_clear_namespace(M.buf(), ns_focus, 0, -1)
  local log = log_loaded()
  if log then
    api.nvim_buf_clear_namespace(log, ns_focus, 0, -1)
  end
  local agent = require("anvim.follow").focused()
  local tool = agent and (tools[agent.tool_use_id] or held[agent.tool_use_id])
  local row = tool and tool.mark and tool_row(tool)
  if row then
    api.nvim_buf_set_extmark(tool.buf, ns_focus, row, 0, {
      virt_text = { { "◉ focused", agents.group(agent.slot) } },
      virt_text_pos = "eol",
      right_gravity = false,
    })
  end
end

-- Info notices, such as a compaction, read like Claude Code's ✻ lines.
function M.notice(level, text)
  text_open, run = false, nil
  local info = level == "info"
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and (info and "✻ " or "⚠ ") or "  ") .. line
  end
  local row = append_item(lines)
  local buf = M.buf()
  local group = info and "AnvimResult" or level == "error" and "AnvimToolError" or "WarningMsg"
  for i = 0, #lines - 1 do
    hl(buf, row + i, 0, #lines[i + 1], group)
  end
  if info then
    hl(buf, row, 0, #"✻", "AnvimClaude")
  end
  M.stamp(buf, row, now())
end

-- A slash command's output, as result lines under the prompt that ran it.
function M.output(text)
  text_open, run = false, nil
  local lines = vim.split(M.short(vim.trim(text)), "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "  ⎿  " or "     ") .. line
  end
  local row
  with_modifiable(function(buf)
    row = end_row(buf)
    api.nvim_buf_set_lines(buf, row, row, false, lines)
  end)
  for i, line in ipairs(lines) do
    hl(M.buf(), row + i - 1, 0, #line, "AnvimResult")
  end
end

function M.compact(ev)
  local text = "Conversation compacted"
  if tonumber(ev.pre_tokens) and tonumber(ev.post_tokens) then
    text = ("%s · %s → %s tokens"):format(text, tokens(ev.pre_tokens), tokens(ev.post_tokens))
  end
  M.notice("info", text .. (ev.trigger == "auto" and " (auto)" or ""))
end

-- Sets the result line of a tool before its result arrives, such as the
-- user's answer to a permission prompt.
function M.outcome(id, text, group)
  if tools[id] then
    tools[id].outcome = { text, group }
  end
end

-- A block waits for the user, so it brings every view of the transcript and
-- of the main log to the end, even one that the user scrolled up. The window
-- with the cursor, in read mode, follows only with `all`.
function M.reveal(all)
  if not batch then
    scroll(all and vim.fn.win_findbuf(M.buf()) or follow_wins(false))
    local log = log_loaded()
    if log then
      scroll(follow_wins(false, log), log)
    end
  end
end

---@return integer? row 0-based row of the block's first line
function block_row(id)
  local block = blocks[id]
  if block and block.buf == M.buf() then
    return api.nvim_buf_get_extmark_by_id(block.buf, ns, id, {})[1]
  end
end

local function clear_block(id, row)
  for _, mark in ipairs(api.nvim_buf_get_extmarks(M.buf(), ns, { row, 0 }, { row + blocks[id].count - 1, -1 }, {})) do
    if mark[1] ~= id then
      api.nvim_buf_del_extmark(M.buf(), ns, mark[1])
    end
  end
end

-- Appends lines as an item that the caller redraws or removes later, such as
-- a permission prompt. Each mark is { row, col, end_col, group }, with rows
-- counted from the block's first line. A block that waits for the user goes
-- last, after the todo list too, as in Claude Code, and brings every view to
-- it. A `quiet` one does neither. A `markdown` one renders its markdown.
---@param opts? { quiet: boolean?, markdown: boolean? }
---@return integer id
function M.block(lines, marks, opts)
  text_open = false
  local quiet = opts and opts.quiet
  local row = append_item(lines, not quiet)
  -- Lines that go in on the mark's row push it down, as when an item goes
  -- above a todo list that came first.
  local id = api.nvim_buf_set_extmark(M.buf(), ns, row, 0, {})
  blocks[id] = { buf = M.buf(), count = #lines, markdown = opts and opts.markdown }
  for _, m in ipairs(marks or {}) do
    hl(M.buf(), row + m[1], m[2], m[3], m[4])
  end
  if not quiet then
    M.reveal()
  end
  return id
end

-- Returns false when the block is gone, as after the transcript buffer was
-- made again.
---@param opts? { quiet: boolean? }
---@return boolean
function M.set_block(id, lines, marks, opts)
  local row = block_row(id)
  if not row then
    return false
  end
  clear_block(id, row)
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, row, row + blocks[id].count, false, lines)
  end)
  -- The new lines push the mark down too, so it goes back to the block's
  -- first row.
  api.nvim_buf_set_extmark(M.buf(), ns, row, 0, { id = id })
  blocks[id].count = #lines
  for _, m in ipairs(marks or {}) do
    hl(M.buf(), row + m[1], m[2], m[3], m[4])
  end
  if not (opts and opts.quiet) then
    M.reveal()
  end
  return true
end

-- Whether a window shows the last line of the block, where its choices end.
function M.block_visible(id)
  local row = block_row(id)
  if not row then
    return false
  end
  local last = row + blocks[id].count
  for _, win in ipairs(vim.fn.win_findbuf(M.buf())) do
    if vim.fn.line("w0", win) <= last and last <= vim.fn.line("w$", win) then
      return true
    end
  end
  return false
end

-- Leaves a block's lines in the transcript as a plain item. A kept block
-- after the pinned todo list, such as an approved plan, moves the list under
-- it, so the list stays last.
function M.keep_block(id)
  run = nil
  local row = block_row(id)
  if row then
    api.nvim_buf_del_extmark(M.buf(), ns, id)
    -- Its markdown stays, as Claude's text does.
    if blocks[id].markdown then
      local last = row + blocks[id].count - 1
      local line = api.nvim_buf_get_lines(M.buf(), last, last + 1, false)[1] or ""
      texts[#texts + 1] = {
        first = api.nvim_buf_set_extmark(M.buf(), ns_text, row, 0, { right_gravity = false }),
        last = api.nvim_buf_set_extmark(M.buf(), ns_text, last, #line, { right_gravity = false }),
      }
      regions_later()
    end
  end
  blocks[id] = nil
  local list_row = todo and todo.id ~= id and block_row(todo.id)
  if row and list_row and list_row < row then
    M.remove_block(todo.id)
    todo.id = M.block(todo.lines, todo.marks, { quiet = true })
  end
end

-- Removes a block and the blank line that separates it from its neighbor.
function M.remove_block(id)
  local row = block_row(id)
  if row then
    clear_block(id, row)
    with_modifiable(function(buf)
      local first, last = row - 1, row + blocks[id].count
      if row == 0 then
        first, last = 0, math.min(last + 1, api.nvim_buf_line_count(buf))
      end
      api.nvim_buf_set_lines(buf, first, last, false, {})
    end)
    api.nvim_buf_del_extmark(M.buf(), ns, id)
  end
  blocks[id] = nil
end

-- The todo list as Claude Code shows it: ☒ for done, and the item in
-- progress in bold.
local function todo_lines(items)
  local done = 0
  for _, item in ipairs(items) do
    done = done + (todos.is_open(item) and 0 or 1)
  end
  local head = "⏺ Todos"
  local lines = { head .. (" · %d of %d done"):format(done, #items) }
  local marks = {
    { 0, 0, #"⏺", done == #items and "AnvimToolOk" or "AnvimClaude" },
    { 0, #"⏺ ", #head, "AnvimToolName" },
    { 0, #head, #lines[1], "AnvimResult" },
  }
  local rows, row_marks = todos.render(items, function(i)
    return i == 1 and "  ⎿  " or "     "
  end)
  vim.list_extend(lines, rows)
  for _, m in ipairs(row_marks) do
    marks[#marks + 1] = { m[1] + 1, m[2], m[3], m[4] }
  end
  return lines, marks
end

-- Draws the todo list in place. Once every item is done, the list stays where
-- it is as a plain item. A list that has open items again pins anew at the
-- end, and a list with none draws nothing unless it is pinned.
---@param items anvim.TodoItem[]
function M.todos(items)
  local open = vim.iter(items):any(todos.is_open)
  if #items == 0 or not (open or todo) then
    if todo then
      M.remove_block(todo.id)
      todo = nil
    end
    return
  end
  local lines, marks = todo_lines(items)
  local quiet = { quiet = true }
  if not (todo and M.set_block(todo.id, lines, marks, quiet)) then
    if not open then
      todo = nil
      return
    end
    todo = { id = M.block(lines, marks, quiet) }
  end
  todo.lines, todo.marks = lines, marks
  if not open then
    M.keep_block(todo.id)
    todo = nil
  end
end

-- Tools that never got a result were cut off by an interrupt or an error.
-- The next text starts a new reply, such as the reply to a background
-- agent's end, which no prompt comes before.
function M.turn_end()
  text_open, reply_done = false, true
  for _, tool in pairs(tools) do
    if not (tool.done or tool.todo or tool.held) then
      finish_tool(tool, true, "Interrupted", "AnvimToolError")
    end
  end
  tools = {}
end

-- Draws many items at once, as for a resumed session. Each line height check
-- with concealed lines parses the buffer again after every edit, so the view
-- work waits until the end, and conceal is off meanwhile.
function M.batch(fn)
  local levels = {}
  for _, win in ipairs(vim.fn.win_findbuf(M.buf())) do
    levels[win] = vim.wo[win].conceallevel
    vim.wo[win].conceallevel = 0
  end
  batch = true
  local ok, err = pcall(fn)
  batch, past_time = false, nil
  for win, level in pairs(levels) do
    if api.nvim_win_is_valid(win) then
      vim.wo[win].conceallevel = level
    end
  end
  if not ok then
    error(err, 0)
  end
end

-- Turns verbose mode on or off, and draws every tool call again. A view at
-- the end stays there.
---@param on boolean
function M.set_verbose(on)
  M.verbose = on
  local tails = {}
  for _, buf in ipairs({ M.buf(), log_loaded() }) do
    tails[buf] = follow_wins(true, buf)
  end
  M.batch(function()
    for _, tool in ipairs(drawn) do
      local r = tool.result
      finish_tool(tool, r.is_error, r.summary, r.group, r.label)
    end
    for _, list in ipairs({ tools, held }) do
      for _, tool in pairs(list) do
        if not tool.done then
          set_tool_line(tool, nil, pending(tool))
        end
      end
    end
  end)
  for buf, wins in pairs(tails) do
    scroll(wins, buf)
  end
end

-- Empties the transcript and the main log, for /clear and before a resumed
-- session draws. A todo list with open items pins again.
function M.clear()
  local buf = M.buf()
  for id, block in pairs(blocks) do
    if block.buf == buf then
      blocks[id] = nil
    end
  end
  tools, held, drawn, todo, reply, reply_done, text_open, texts = {}, {}, {}, nil, {}, true, false, {}
  sent_back, run = {}, nil
  for _, b in ipairs({ buf, log_loaded() }) do
    api.nvim_buf_clear_namespace(b, ns, 0, -1)
    api.nvim_buf_clear_namespace(b, ns_text, 0, -1)
    api.nvim_buf_clear_namespace(b, ns_focus, 0, -1)
    M.unstamp(b, 0, -1)
    with_modifiable(function()
      api.nvim_buf_set_lines(b, 0, -1, false, {})
    end, b)
  end
  -- The todo list outlives the conversation.
  M.todos(todos.items)
end

function M.attach(sidecar)
  sidecar.on("text_start", M.text_start)
  sidecar.on("text_delta", function(ev)
    M.text_delta(ev.text)
  end)
  sidecar.on("text_stop", M.text_stop)
  sidecar.on("tool_start", function(ev)
    M.tool_start(ev.id, ev.name)
  end)
  sidecar.on("tool_field", M.tool_field)
  sidecar.on("tool_use", M.tool_use)
  sidecar.on("tool_result", M.tool_result)
  sidecar.on("turn_end", M.turn_end)
  sidecar.on("notice", function(ev)
    M.notice(ev.level, ev.text)
  end)
  sidecar.on("output", function(ev)
    M.output(ev.text)
  end)
  sidecar.on("compact", M.compact)
  -- A subagent's call has no line here. Its log shows the send-back.
  sidecar.on("send_back", function(ev)
    if not ev.agent_id and ev.tool_use_id then
      sent_back[ev.tool_use_id] = ev.reason
    end
  end)
  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("anvim.transcript", {}),
    pattern = "AnvimAgents",
    callback = paint_agents,
  })
  sidecar.on("exit", function(ev)
    sent_back = {}
    if not (bufnr and api.nvim_buf_is_loaded(bufnr)) then
      return
    end
    -- The turn and the background agents end with the sidecar. A tool line
    -- without a result would otherwise wait for the next turn's end.
    M.turn_end()
    for id, tool in pairs(held) do
      if tool.live then
        held[id] = nil
        finish_tool(tool, true, "Interrupted", "AnvimToolError")
      end
    end
    if not ev.restart then
      M.notice(
        ev.code == 0 and "warn" or "error",
        ("Sidecar exited (code %d). :AnvimRestart starts it again. See %s"):format(ev.code, sidecar.log_path)
      )
    end
  end)
end

return M
