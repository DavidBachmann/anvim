-- The conversation view, drawn like Claude Code: user prompts, streamed
-- assistant text, and one line per tool call with its result below it.
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.transcript")

---@type integer?
local bufnr
---@type table<string, { name: string, mark: integer, input: table?, done: boolean }>
local tools = {}
local text_open = false

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
  vim.b[bufnr].anvim_transcript = true
  api.nvim_buf_set_name(bufnr, "anvim://transcript")
  vim.treesitter.language.register("markdown", "anvim_transcript")
  vim.bo[bufnr].filetype = "anvim_transcript"
  pcall(vim.treesitter.start, bufnr, "markdown")
  vim.bo[bufnr].modifiable = false
  -- With breakindentopt=list:-1, wrapped lines align after the bullet.
  vim.bo[bufnr].formatlistpat = [[^\s*\%(⏺\|❯\|⎿\|⚠\)\?\s*]]
  -- The cursor is here only in read mode.
  for _, key in ipairs({ "q", "<Esc>", "i" }) do
    vim.keymap.set("n", key, function()
      require("anvim.layout").focus_input()
    end, { buffer = bufnr, desc = "Back to the prompt" })
  end
  return bufnr
end

-- Windows that show the transcript, except the one the user is in. With
-- `tail`, only those whose view reaches the end: new output keeps them there,
-- and leaves a window that the user scrolled up alone.
local function follow_wins(tail)
  local buf = M.buf()
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

local function scroll(wins)
  local last = api.nvim_buf_line_count(M.buf())
  for _, win in ipairs(wins) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_set_cursor(win, { last, 0 })
    end
  end
end

local function with_modifiable(fn)
  local buf = M.buf()
  local tail = follow_wins(true)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = false
  scroll(tail)
  if not ok then
    error(err)
  end
end

local function is_empty(buf)
  return api.nvim_buf_line_count(buf) == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

-- Appends lines as a new item, one blank line after the previous item.
---@return integer row 0-based row of the first appended line
local function append_item(lines)
  local row
  with_modifiable(function(buf)
    if is_empty(buf) then
      row = 0
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    else
      row = api.nvim_buf_line_count(buf) + 1
      api.nvim_buf_set_lines(buf, -1, -1, false, { "", unpack(lines) })
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
  end
  arg = arg:gsub("\n.*", "...")
  if #arg > 80 then
    arg = arg:sub(1, 79) .. "..."
  end
  return ("%s(%s)"):format(name, arg)
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

local function summarize(tool, ev)
  if ev.is_error then
    return first_line(ev.text), "AnvimToolError"
  end
  local r = type(ev.result) == "table" and ev.result or {}
  local name = tool.name
  local editor_tool = name:match("^mcp__anvim__(.+)$")
  if editor_tool then
    return require("anvim.tools").summary(editor_tool, tool.input or {}, ev.text)
  elseif name == "Read" and r.file and r.file.numLines then
    return "Read " .. plural(r.file.numLines, "line")
  elseif name == "Write" and r.type == "create" then
    local content = tool.input and tool.input.content or ""
    return "Wrote " .. plural(select(2, content:gsub("\n", "")) + (content:match("[^\n]$") and 1 or 0), "line")
  elseif (name == "Edit" or name == "Write") and r.structuredPatch then
    local added, removed = patch_counts(r.structuredPatch)
    return ("Added %s, removed %s"):format(plural(added, "line"), plural(removed, "line"))
  end
  local text = ev.text
  if name == "Bash" and type(r.stdout) == "string" then
    text = r.stdout ~= "" and r.stdout or r.stderr or ""
  end
  local line = first_line(text)
  return line ~= "" and line or "Done"
end

local function tool_row(tool)
  return api.nvim_buf_get_extmark_by_id(M.buf(), ns, tool.mark, {})[1]
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

function M.user(text)
  text_open = false
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "❯ " or "  ") .. line
  end
  local row = append_item(lines)
  for i = 0, #lines - 1 do
    api.nvim_buf_set_extmark(M.buf(), ns, row + i, 0, { line_hl_group = "AnvimUser" })
  end
  hl(row, 0, #"❯", "AnvimPrompt")
  -- A new prompt brings every view back to the end.
  scroll(follow_wins(false))
end

function M.text_start()
  text_open = true
  local row = append_item({ "⏺ " })
  hl(row, 0, #"⏺", "AnvimBullet")
end

function M.text_delta(text)
  if not text_open then
    M.text_start()
  end
  local parts = vim.split(text, "\n", { plain = true })
  for i = 2, #parts do
    parts[i] = "  " .. parts[i]
  end
  with_modifiable(function(buf)
    local last = api.nvim_buf_line_count(buf) - 1
    local col = #api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
    api.nvim_buf_set_text(buf, last, col, last, col, parts)
  end)
end

function M.text_stop()
  text_open = false
end

function M.tool_start(id, name)
  text_open = false
  local label = tool_label(name)
  local row = append_item({ "⏺ " .. label })
  tools[id] = { name = name, mark = hl(row, 0, #"⏺", "AnvimToolPending") }
  hl(row, #"⏺" + 1, #"⏺" + 1 + #label, "AnvimToolName")
end

function M.tool_field(ev)
  local tool = tools[ev.id]
  if tool and ev.phase == "end" and ev.key == primary_arg[tool.name] then
    set_tool_line(tool, tool_label(tool.name, { [ev.key] = ev.value }), "AnvimToolPending")
  end
end

function M.tool_use(ev)
  if ev.parent_id then
    return
  end
  local tool = tools[ev.id]
  if not tool then
    M.tool_start(ev.id, ev.name)
    tool = tools[ev.id]
  end
  tool.input = ev.input
  set_tool_line(tool, tool_label(ev.name, ev.input), "AnvimToolPending")
end

local function finish_tool(tool, is_error, summary, group)
  tool.done = true
  set_tool_line(tool, tool_label(tool.name, tool.input), is_error and "AnvimToolError" or "AnvimToolOk")
  local row = tool_row(tool)
  if not row then
    return
  end
  local line = "  ⎿  " .. summary
  with_modifiable(function(buf)
    api.nvim_buf_set_lines(buf, row + 1, row + 1, false, { line })
  end)
  hl(row + 1, 0, #line, group or "AnvimResult")
end

function M.tool_result(ev)
  local tool = tools[ev.id]
  if tool and not tool.done then
    finish_tool(tool, ev.is_error, summarize(tool, ev))
  end
end

function M.notice(level, text)
  text_open = false
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "⚠ " or "  ") .. line
  end
  local row = append_item(lines)
  local group = level == "error" and "AnvimToolError" or "WarningMsg"
  for i = 0, #lines - 1 do
    hl(row + i, 0, #lines[i + 1], group)
  end
end

-- Tools that never got a result were cut off by an interrupt or an error.
function M.turn_end()
  text_open = false
  for _, tool in pairs(tools) do
    if not tool.done then
      finish_tool(tool, true, "Interrupted", "AnvimToolError")
    end
  end
  tools = {}
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
  sidecar.on("exit", function(ev)
    if bufnr and api.nvim_buf_is_loaded(bufnr) then
      M.notice(
        ev.code == 0 and "warn" or "error",
        ("Sidecar exited (code %d). See %s"):format(ev.code, sidecar.log_path)
      )
    end
  end)
end

return M
