-- The conversation view, drawn like Claude Code: user prompts, streamed
-- assistant text, and one line per tool call with its result below it.
local agents = require("anvim.agents")
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.transcript")
-- Where Claude's text blocks start and end.
local ns_text = api.nvim_create_namespace("anvim.transcript.text")
local ns_focus = api.nvim_create_namespace("anvim.transcript.focus")

---@class anvim.Tool
---@field id string
---@field name string
---@field mark integer?
---@field input table?
---@field done boolean?
---@field outcome string[]?
---@field children string[]? Labels of a subagent's tool calls.
---@field child_rows integer? Rows that show them under the tool line.
---@field todo boolean? A TodoWrite or Task tool, which updates the todo list instead of a line.
---@field held boolean? A background agent's line, which lives on after its result.
---@field live boolean? Held for an agent of this sidecar, not of a resumed session's past.

---@type integer?
local bufnr
---@type table<string, anvim.Tool>
local tools = {}
-- The lines of background agents. Their tool call returns once the agent
-- starts, and the line lives on after the turn, until the agent ends.
---@type table<string, anvim.Tool>
local held = {}
-- The guard's reason of each main agent's call that anvim sent back. The
-- event can come before the call's tool_start.
---@type table<string, string>
local sent_back = {}
local text_open = false
-- The blocks that other modules own, by the id of the extmark on their first
-- line. The buffer tells a block from a mark of a rebuilt transcript.
---@type table<integer, { buf: integer, count: integer }>
local blocks = {}
-- Claude's todo list. While it has open items it stays the last item, as
-- Claude Code keeps it under the spinner. New items go above it.
---@type { id: integer, lines: string[], marks: table[], active: string? }?
local todo
-- The tasks that TaskCreate adds and TaskUpdate changes, Claude Code's other
-- todo list. Their ids are strings.
local tasks = { order = {}, by_id = {} } ---@type { order: string[], by_id: table<string, table> }
-- Claude Code draws no tool line for these. The todo list shows what they do.
local todo_tools = { TodoWrite = true, TaskCreate = true, TaskUpdate = true, TaskGet = true, TaskList = true }
M.todo_tools = todo_tools
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
  Skill = "skill",
}

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
  api.nvim_buf_set_name(bufnr, "anvim://transcript")
  vim.treesitter.language.register("markdown", "anvim_transcript")
  vim.bo[bufnr].filetype = "anvim_transcript"
  pcall(vim.treesitter.start, bufnr, "markdown")
  vim.bo[bufnr].modifiable = false
  -- With breakindentopt=list:-1, wrapped lines align after the bullet.
  vim.bo[bufnr].formatlistpat = [[^\s*\%(⏺\|❯\|⎿\|⚠\)\?\s*]]
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
  return bufnr
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

-- Markdown parses only Claude's text and the blocks, such as a plan. In tool
-- lines, results and prompts, markers like ** and __ stay as they are.
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
    local row = block.buf == buf and api.nvim_buf_get_extmark_by_id(buf, ns, id, {})[1]
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

local function with_modifiable(fn)
  local buf = M.buf()
  local tail = not batch and follow_wins(true)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = false
  if tail then
    scroll(tail)
  end
  if not regions_pending then
    regions_pending = true
    vim.schedule(set_regions)
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
      -- The todo list is the only item.
      row = 0
      api.nvim_buf_set_lines(buf, 0, 0, false, vim.list_extend(vim.list_slice(lines), { "" }))
    else
      row = stop + 1
      api.nvim_buf_set_lines(buf, stop, stop, false, { "", unpack(lines) })
    end
  end)
  return row
end

local function hl(row, col, end_col, group, opts)
  return api.nvim_buf_set_extmark(
    M.buf(),
    ns,
    row,
    col,
    vim.tbl_extend("force", { end_col = end_col, hl_group = group, priority = 200 }, opts or {})
  )
end

local function first_line(text)
  local lines = vim.split(vim.trim(text or ""), "\n", { plain = true })
  local line = lines[1] or ""
  if #lines > 1 then
    line = ("%s ... +%d lines"):format(line, #lines - 1)
  end
  return line
end

function M.relpath(path)
  if type(path) ~= "string" then
    return ""
  end
  return vim.fs.relpath(state.cwd, path) or vim.fn.fnamemodify(path, ":~")
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

local function tool_label(name, input)
  local mcp_server, mcp_tool = name:match("^mcp__(.-)__(.+)$")
  if mcp_server == "anvim" then
    return require("anvim.tools").label(mcp_tool, input)
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
    arg = M.relpath(arg)
  else
    arg = M.short(arg)
  end
  arg = arg:gsub("\n.*", "...")
  if #arg > 80 then
    arg = arg:sub(1, 79) .. "..."
  end
  return ("%s(%s)"):format(name, arg)
end

M.label = tool_label

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

local function duration(ms)
  local s = ms / 1000
  return s < 60 and ("%.1fs"):format(s) or ("%dm %ds"):format(math.floor(s / 60), math.floor(s % 60))
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
    return first_line(ev.text), "AnvimToolError"
  end
  local r = type(ev.result) == "table" and ev.result or {}
  local name, input = tool.name, tool.input or {}
  local editor_tool = name:match("^mcp__anvim__(.+)$")
  if editor_tool then
    return require("anvim.tools").summary(editor_tool, input, ev.text)
  elseif name == "Agent" or name == "Task" then
    return agent_done(tool, r)
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
  return line ~= "" and line or "Done"
end

-- The result line of a tool call, and its group when it is not AnvimResult.
---@param tool { name: string, input: table?, outcome: string[]?, children: string[]? }
---@return string text, string? group
M.summary = summarize

local function tool_row(tool)
  return api.nvim_buf_get_extmark_by_id(M.buf(), ns, tool.mark, {})[1]
end

-- The bullet of a tool call that has no result yet. An Agent call's bullet
-- takes its agent's color while the agent runs.
local function pending(tool)
  local agent = (tool.name == "Agent" or tool.name == "Task") and agents.by_tool(tool.id)
  return agent and agent.status == "running" and agents.group(agent.slot) or "AnvimToolPending"
end

local function set_tool_line(tool, label, bullet_hl)
  local row = tool_row(tool)
  if not row then
    return
  end
  local line = "⏺ " .. label
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, row, row + 1, false, { line })
  end)
  local bullet = #"⏺"
  api.nvim_buf_clear_namespace(M.buf(), ns, row, row + 1)
  tool.mark = hl(row, 0, bullet, bullet_hl)
  local name_end = label:find("(", 1, true)
  hl(row, bullet + 1, bullet + 1 + (name_end and name_end - 1 or #label), "AnvimToolName")
end

---@param context string? The editor context that went with the prompt, such as a.lua#L12-30.
function M.user(text, context)
  -- A turn without text has no reply, rather than the last turn's.
  text_open, reply_done, reply = false, true, {}
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "❯ " or "  ") .. line
  end
  local row = append_item(lines)
  for i = 0, #lines - 1 do
    api.nvim_buf_set_extmark(M.buf(), ns, row + i, 0, { line_hl_group = "AnvimUser" })
  end
  hl(row, 0, #"❯", "AnvimPrompt")
  if context then
    local line = "  ⎿  ⧉ " .. context
    with_modifiable(function(buf)
      api.nvim_buf_set_lines(buf, row + #lines, row + #lines, false, { line })
    end)
    hl(row + #lines, 0, #line, "AnvimResult")
  end
  -- A new prompt brings every view back to the end.
  if not batch then
    scroll(follow_wins(false))
  end
end

function M.text_start()
  text_open = true
  if reply_done then
    reply, reply_done = {}, false
  end
  reply[#reply + 1] = ""
  local row = append_item({ "⏺ " })
  hl(row, 0, #"⏺", "AnvimBullet")
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
  if todo_tools[name] then
    tools[id] = { id = id, name = name, todo = true }
    return
  end
  local label = tool_label(name)
  local row = append_item({ "⏺ " .. label })
  local tool = { id = id, name = name }
  tool.mark = hl(row, 0, #"⏺", pending(tool))
  tools[id] = tool
  hl(row, #"⏺" + 1, #"⏺" + 1 + #label, "AnvimToolName")
end

function M.tool_field(ev)
  local tool = tools[ev.id]
  if tool and not tool.todo and ev.phase == "end" and ev.key == primary_arg[tool.name] then
    set_tool_line(tool, tool_label(tool.name, { [ev.key] = ev.value }), pending(tool))
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
  local old = tool.child_rows or 0
  api.nvim_buf_clear_namespace(M.buf(), ns, row + 1, row + 1 + old)
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, row + 1, row + 1 + old, false, lines)
  end)
  tool.child_rows = #lines
  for i, line in ipairs(lines) do
    hl(row + i, 0, #line, "AnvimResult")
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
    if ev.name == "TodoWrite" then
      M.todos(type(ev.input) == "table" and ev.input.todos or {})
    end
    return
  end
  set_tool_line(tool, tool_label(ev.name, ev.input), pending(tool))
end

local function finish_tool(tool, is_error, summary, group)
  tool.done = true
  set_tool_line(tool, tool_label(tool.name, tool.input), is_error and "AnvimToolError" or "AnvimToolOk")
  local row = tool_row(tool)
  if not row then
    return
  end
  local line = "  ⎿  " .. M.short(summary)
  local old = tool.child_rows or 0
  api.nvim_buf_clear_namespace(M.buf(), ns, row + 1, row + 1 + old)
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, row + 1, row + 1 + old, false, { line })
  end)
  tool.child_rows = nil
  hl(row + 1, 0, #line, group or "AnvimResult")
end

local task_result

-- A background agent's tool call returns as the agent starts. A saved
-- session keeps no result, but the text says so.
local function launched(tool, ev)
  local r = type(ev.result) == "table" and ev.result or {}
  return (tool.name == "Agent" or tool.name == "Task")
    and not ev.is_error
    and (r.status == "async_launched" or (ev.result == nil and (ev.text or ""):find("^Async agent launched") ~= nil))
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
    if not ev.is_error then
      task_result(tool, ev)
    end
  elseif tool and not (tool.done or tool.held) then
    if launched(tool, ev) then
      tool.held, tool.live = true, agents.by_tool(tool.id) ~= nil
      held[tool.id] = tool
      set_children(tool)
    else
      finish_tool(tool, ev.is_error, summarize(tool, ev))
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
  text_open = false
  local name = description and description ~= "" and ('Agent "%s"'):format(description) or "Agent"
  local lines = { ("⏺ %s %s"):format(name, ended[ev.status] or "ended") }
  local summary = M.short(first_line(ev.summary))
  if summary ~= "" then
    lines[2] = "  ⎿  " .. summary
  end
  local row = append_item(lines)
  hl(row, 0, #"⏺", ok and "AnvimToolOk" or "AnvimToolError")
  for i, line in ipairs(lines) do
    hl(row + i - 1, i == 1 and #"⏺" or 0, #line, "AnvimResult")
  end
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
      set_tool_line(tool, tool_label(tool.name, tool.input), "AnvimResult")
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
      local row = (tool.name == "Agent" or tool.name == "Task") and tool.mark and not tool.done and tool_row(tool)
      if row then
        tool.mark = hl(row, 0, #"⏺", pending(tool), { id = tool.mark })
      end
    end
  end
  api.nvim_buf_clear_namespace(M.buf(), ns_focus, 0, -1)
  local agent = require("anvim.follow").focused()
  local tool = agent and (tools[agent.tool_use_id] or held[agent.tool_use_id])
  local row = tool and tool.mark and tool_row(tool)
  if row then
    api.nvim_buf_set_extmark(M.buf(), ns_focus, row, 0, {
      virt_text = { { "◉ focused", agents.group(agent.slot) } },
      virt_text_pos = "eol",
      right_gravity = false,
    })
  end
end

-- Info notices, such as a compaction, read like Claude Code's ✻ lines.
function M.notice(level, text)
  text_open = false
  local info = level == "info"
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and (info and "✻ " or "⚠ ") or "  ") .. line
  end
  local row = append_item(lines)
  local group = info and "AnvimResult" or level == "error" and "AnvimToolError" or "WarningMsg"
  for i = 0, #lines - 1 do
    hl(row + i, 0, #lines[i + 1], group)
  end
  if info then
    hl(row, 0, #"✻", "AnvimClaude")
  end
end

-- A slash command's output, as result lines under the prompt that ran it.
function M.output(text)
  text_open = false
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
    hl(row + i - 1, 0, #line, "AnvimResult")
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

-- A block waits for the user, so it brings every view of the transcript to
-- the end, even one that the user scrolled up. The window with the cursor, in
-- read mode, follows only with `all`.
function M.reveal(all)
  if not batch then
    scroll(all and vim.fn.win_findbuf(M.buf()) or follow_wins(false))
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
-- it. A `quiet` one does neither.
---@param opts? { quiet: boolean? }
---@return integer id
function M.block(lines, marks, opts)
  text_open = false
  local quiet = opts and opts.quiet
  local row = append_item(lines, not quiet)
  local id = api.nvim_buf_set_extmark(M.buf(), ns, row, 0, { right_gravity = false })
  blocks[id] = { buf = M.buf(), count = #lines }
  for _, m in ipairs(marks or {}) do
    hl(row + m[1], m[2], m[3], m[4])
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
  blocks[id].count = #lines
  for _, m in ipairs(marks or {}) do
    hl(row + m[1], m[2], m[3], m[4])
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
  local row = block_row(id)
  if row then
    api.nvim_buf_del_extmark(M.buf(), ns, id)
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
local function todo_lines(list)
  local done = 0
  for _, item in ipairs(list) do
    done = done + (item.status == "completed" and 1 or 0)
  end
  local head, count = "⏺ Todos", (" · %d of %d done"):format(done, #list)
  local lines = { head .. count }
  local marks = {
    { 0, 0, #"⏺", done == #list and "AnvimToolOk" or "AnvimClaude" },
    { 0, #"⏺ ", #head, "AnvimToolName" },
    { 0, #head, #lines[1], "AnvimResult" },
  }
  local groups = { completed = "AnvimTodoDone", in_progress = "AnvimTodoActive" }
  for i, item in ipairs(list) do
    local prefix = (i == 1 and "  ⎿  " or "     ") .. (item.status == "completed" and "☒ " or "☐ ")
    lines[#lines + 1] = prefix .. tostring(item.content or ""):gsub("\n", " ")
    marks[#marks + 1] = { #lines - 1, #prefix, #lines[#lines], groups[item.status] or "Normal" }
  end
  return lines, marks, done == #list
end

---@return string? activeForm of the item in progress, for the activity line.
function M.todo_active()
  return todo and todo.active
end

-- Draws Claude's todo list in place. Once every item is done, the list stays
-- where it is as a plain item, and the next list starts at the end.
function M.todos(list)
  if type(list) ~= "table" or #list == 0 then
    if todo then
      M.remove_block(todo.id)
      todo = nil
    end
    return
  end
  local lines, marks, all_done = todo_lines(list)
  local quiet = { quiet = true }
  if not (todo and M.set_block(todo.id, lines, marks, quiet)) then
    todo = { id = M.block(lines, marks, quiet) }
  end
  todo.lines, todo.marks, todo.active = lines, marks, nil
  for _, item in ipairs(list) do
    if item.status == "in_progress" and type(item.activeForm) == "string" then
      todo.active = item.activeForm
    end
  end
  if all_done then
    M.keep_block(todo.id)
    todo = nil
  end
end

-- A task changes once its tool call worked. Saved sessions keep no result, so
-- there a new task's id comes from the result text.
function task_result(tool, ev)
  local input = type(tool.input) == "table" and tool.input or {}
  if tool.name == "TaskCreate" then
    local r = type(ev.result) == "table" and type(ev.result.task) == "table" and ev.result.task or {}
    local id = r.id or (ev.text or ""):match("Task #(%w+) created")
    if not id then
      return
    end
    id = tostring(id)
    if not tasks.by_id[id] then
      tasks.order[#tasks.order + 1] = id
    end
    tasks.by_id[id] = { content = input.subject or r.subject or "", activeForm = input.activeForm, status = "pending" }
  elseif tool.name == "TaskUpdate" and input.taskId then
    local id = tostring(input.taskId)
    local task = tasks.by_id[id]
    if not task then
      return
    elseif input.status == "deleted" then
      tasks.by_id[id] = nil
    else
      task.status = input.status or task.status
      task.content = input.subject or task.content
      task.activeForm = input.activeForm or task.activeForm
    end
  else
    return
  end
  local list = {}
  for _, id in ipairs(tasks.order) do
    list[#list + 1] = tasks.by_id[id]
  end
  M.todos(list)
  -- As with TodoWrite, a list that is all done is over, and the next one starts new.
  if not todo then
    tasks = { order = {}, by_id = {} }
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
  batch = false
  for win, level in pairs(levels) do
    if api.nvim_win_is_valid(win) then
      vim.wo[win].conceallevel = level
    end
  end
  if not ok then
    error(err, 0)
  end
end

-- Empties the transcript, for /clear and before a resumed session draws.
function M.clear()
  local buf = M.buf()
  for id, block in pairs(blocks) do
    if block.buf == buf then
      blocks[id] = nil
    end
  end
  tools, held, todo, reply, reply_done, text_open, texts = {}, {}, nil, {}, true, false, {}
  sent_back = {}
  tasks = { order = {}, by_id = {} }
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(buf, ns_text, 0, -1)
  api.nvim_buf_clear_namespace(buf, ns_focus, 0, -1)
  with_modifiable(function()
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
  end)
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
