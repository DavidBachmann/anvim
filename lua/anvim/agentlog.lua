-- One log buffer per subagent, keyed by its agent_id: its prompt, tool calls
-- with their results, and text, drawn like the transcript.
local agents = require("anvim.agents")
local keys = require("anvim.keys")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.agentlog")
local drop_group = api.nvim_create_augroup("anvim.agentlog.drop", {})

-- Beyond max_lines, the oldest drop_lines go.
M.max_lines = 3000
M.drop_lines = 500
M.dropped_text = "⋯ earlier lines dropped"
-- The logs kept at most. Past agents' logs go first, so that a SendMessage
-- restart after the next prompt still shows the earlier runs.
M.max_logs = 16

---@class anvim.Log
---@field buf integer
---@field order integer The agent's order at the start that the log drew.
---@field empty boolean The buffer has only its first, empty line.
---@field tools table<string, { mark: integer, name: string, input: table? }> Calls without a result.
---@field text boolean A text block came in this run.
---@field await { tool: string, after: integer? }? Where the prompt or message of a later tool call goes.
---@field ending { mark: integer, count: integer, key: string }? The end line of this run.
---@field dropped boolean

---@type table<string, anvim.Log>
local logs = {}
-- The message of each SendMessage call, which can come before its agent_start.
---@type table<string, string>
local messages = {}
-- The agents that had a log, so a log that starts again knows it continues.
---@type table<string, true>
local seen = {}
-- The guard's reason of each call that anvim sent back to the agent. The
-- event can come before the call's tool_use.
---@type table<string, string>
local sent_back = {}

local function mark_row(buf, id)
  return id and api.nvim_buf_get_extmark_by_id(buf, ns, id, {})[1]
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

-- Drops the oldest lines. Calls whose lines went get no result line.
local function cap(log)
  local buf = log.buf
  while api.nvim_buf_line_count(buf) > M.max_lines do
    local first = log.dropped and 1 or 0
    local last = first + M.drop_lines
    for id, tool in pairs(log.tools) do
      local row = mark_row(buf, tool.mark)
      if not row or row < last then
        log.tools[id] = nil
      end
    end
    api.nvim_buf_clear_namespace(buf, ns, first, last)
    api.nvim_buf_set_lines(buf, first, last, false, log.dropped and {} or { M.dropped_text })
    if not log.dropped then
      log.dropped = true
      hl(buf, 0, 0, #M.dropped_text, "AnvimResult")
    end
  end
end

-- Runs fn with the buffer modifiable. Windows whose view reached the end
-- follow the new lines, except the current window.
local function write(log, fn)
  local buf = log.buf
  local wins = transcript.follow_wins(true, buf)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  if ok then
    ok, err = pcall(cap, log)
  end
  vim.bo[buf].modifiable = false
  transcript.scroll(wins, buf)
  if not ok then
    error(err, 0)
  end
end

-- Inserts lines before `row`, or at the end without it. Each mark is
-- { row, col, end_col, group } with rows counted from the first line,
-- { row, line = group }, or { row, anchor = true } for a mark without a
-- group. The cap can move the lines after that, so the marks are set first.
---@return integer[] ids The id of each mark.
local function put(log, lines, marks, row)
  local ids = {}
  write(log, function(buf)
    if log.empty then
      row = 0
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      log.empty = false
    else
      row = row or api.nvim_buf_line_count(buf)
      api.nvim_buf_set_lines(buf, row, row, false, lines)
    end
    for i, m in ipairs(marks) do
      if m.line then
        ids[i] = api.nvim_buf_set_extmark(buf, ns, row + m[1], 0, { line_hl_group = m.line })
      elseif m.anchor then
        ids[i] = api.nvim_buf_set_extmark(buf, ns, row + m[1], 0, {})
      else
        ids[i] = hl(buf, row + m[1], m[2], m[3], m[4])
      end
    end
  end)
  return ids
end

-- A prompt as the transcript shows the user's, and a blank line after it.
local function prompt_block(text)
  local lines = vim.split((text:gsub("%s+$", "")), "\n", { plain = true })
  local marks = { { 0, 0, #"❯", "AnvimPrompt" } }
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "❯ " or "  ") .. line
    marks[#marks + 1] = { i - 1, line = "AnvimUser" }
  end
  lines[#lines + 1] = ""
  return lines, marks
end

-- A prompt goes after the row of the mark `after`, or at the top.
local function place(log, after, text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return
  end
  local row = 0
  if after then
    row = mark_row(log.buf, after)
    row = row and row + 1 or api.nvim_buf_line_count(log.buf)
  end
  local lines, marks = prompt_block(text)
  put(log, lines, marks, row)
end

-- A SendMessage's message, under its rule, after a blank line. It goes after
-- the row of the mark `after`, at the top when `after` is false, or at the end.
---@param after integer|false|nil
local function message(log, after, text)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return
  end
  local row
  if after then
    row = mark_row(log.buf, after)
    row = row and row + 1
  elseif after == false then
    row = 0
  end
  row = row or api.nvim_buf_line_count(log.buf)
  local rule = "─── SendMessage ───"
  local prompt, prompt_marks = prompt_block(text)
  local before = row > 0 and not log.empty and api.nvim_buf_get_lines(log.buf, row - 1, row, false)[1] ~= ""
  local lines = before and { "", rule } or { rule }
  local marks = { { #lines - 1, 0, #rule, "AnvimRule" } }
  for _, m in ipairs(prompt_marks) do
    m[1] = m[1] + #lines
    marks[#marks + 1] = m
  end
  put(log, vim.list_extend(lines, prompt), marks, row)
end

local function fill(log, text)
  local await = log.await
  log.await = nil
  if await.message then
    message(log, await.after, text)
  else
    place(log, await.after, text)
  end
end

local trim

-- The buffer of each name, so that a new log can take the name of a deleted one.
---@type table<string, integer>
local named = {}

local function new_log(id)
  local buf = api.nvim_create_buf(false, true)
  vim.b[buf].anvim_agentlog = id
  require("anvim.windows").stop_at_end(buf)
  local name = "anvim://agent/" .. id
  local old = named[name]
  if old and api.nvim_buf_is_valid(old) and not api.nvim_buf_is_loaded(old) then
    api.nvim_buf_delete(old, { force = true })
  end
  if pcall(api.nvim_buf_set_name, buf, name) then
    named[name] = buf
  end
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  -- With breakindentopt=list:-1, wrapped lines align after the bullet.
  vim.bo[buf].formatlistpat = [[^\s*\%(⏺\|❯\|⎿\|⚠\)\?\s*]]
  -- The Agent Overview shows the log, and <a-w> goes into it.
  for _, key in ipairs({ "q", "<Esc>" }) do
    keys.set("overview", "n", key, function()
      require("anvim.overview").close()
    end, { buffer = buf, nowait = true })
  end
  local log = { buf = buf, order = 0, empty = true, tools = {}, text = false, dropped = false }
  logs[id], seen[id] = log, true
  -- The user can delete or wipe the buffer. The log is gone then, and the
  -- agent's next event starts a new one. The buffer goes, and its name with it.
  api.nvim_create_autocmd("BufUnload", {
    group = drop_group,
    buffer = buf,
    callback = function()
      if logs[id] and logs[id].buf == buf then
        logs[id] = nil
      end
      vim.schedule(function()
        if api.nvim_buf_is_valid(buf) and not api.nvim_buf_is_loaded(buf) then
          pcall(api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
  return log
end

-- The log of a known agent. An agent whose log the user deleted gets a new
-- one, with its first prompt.
local function log_of(agent)
  local log = logs[agent.id]
  if log or not agents.get(agent.id) then
    return log
  end
  log = new_log(agent.id)
  log.order = agent.order
  if agent.prompt then
    place(log, nil, agent.prompt)
  end
  trim()
  return logs[agent.id]
end

---@return integer? buf The log of the agent, while anvim keeps it.
function M.buf(id)
  local log = logs[id]
  return log and api.nvim_buf_is_loaded(log.buf) and log.buf or nil
end

-- A window may show the buffer. Deleting the buffer would close that window,
-- so it waits until no window shows it.
local function release(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  elseif #vim.fn.win_findbuf(buf) == 0 then
    api.nvim_buf_delete(buf, { force = true })
    return
  end
  api.nvim_create_autocmd("BufWinLeave", {
    group = drop_group,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        release(buf)
      end)
    end,
  })
end

local function drop(id)
  local log = logs[id]
  logs[id] = nil
  if log then
    release(log.buf)
  end
end

function M.start(ev)
  local agent = agents.get(ev.agent_id)
  if not (agent and agent.status == "running") then
    return
  end
  local log = logs[agent.id]
  if log and log.order == agent.order then
    return
  end
  local again = seen[agent.id]
  if not log then
    log = new_log(agent.id)
    trim()
  end
  log.order, log.text, log.ending, log.await = agent.order, false, nil, nil
  if again and log.empty and agent.prompt then
    -- The log of its earlier run went. Its first prompt still says what it does.
    place(log, nil, agent.prompt)
  end
  if again then
    local text = messages[ev.tool_use_id]
    if text then
      message(log, nil, text)
    else
      -- The SendMessage call comes later. Its message goes after the lines of
      -- the earlier run, before the lines of this one.
      local last = api.nvim_buf_line_count(log.buf) - 1
      local after = not log.empty and api.nvim_buf_set_extmark(log.buf, ns, last, 0, {})
      log.await = { tool = ev.tool_use_id, after = after, message = true }
    end
    return
  end
  local parent = agent.parent and agents.get(agent.parent)
  local after
  if parent then
    local header = "Started by " .. agents.name(parent)
    if parent.description ~= "" then
      header = ("%s (%s)"):format(header, parent.description)
    end
    after = put(log, { header }, { { 0, 0, #header, "AnvimResult" }, { 0, anchor = true } })[2]
  end
  log.await = { tool = agent.tool_use_id, after = after }
  if agent.prompt then
    fill(log, agent.prompt)
  end
end

local function tool_use(log, agent, ev)
  local label = transcript.label(ev.name, ev.input)
  local line = "⏺ " .. label
  local bullet = #"⏺"
  local name_end = label:find("(", 1, true)
  local ids = put(log, { line }, {
    { 0, 0, bullet, agents.group(agent.slot) },
    { 0, bullet + 1, bullet + 1 + (name_end and name_end - 1 or #label), "AnvimToolName" },
  })
  log.tools[ev.id] = {
    mark = ids[1],
    name = ev.name,
    input = type(ev.input) == "table" and ev.input or nil,
  }
end

local function finish(log, id, is_error, text, group)
  local tool = log.tools[id]
  log.tools[id] = nil
  local row = tool and mark_row(log.buf, tool.mark)
  if not row then
    return
  end
  hl(log.buf, row, 0, #"⏺", is_error and "AnvimToolError" or "AnvimToolOk", { id = tool.mark })
  local line = "  ⎿  " .. transcript.short(text)
  put(log, { line }, { { 0, 0, #line, group or "AnvimResult" } }, row + 1)
end

local starts = { Agent = true, Task = true, SendMessage = true }

function M.tool_use(ev)
  local agent = agents.of(ev)
  -- As in the transcript, the todo list shows what these do.
  if agent and not transcript.todo_tools[ev.name] then
    local log = agent.status == "running" and log_of(agent) or logs[agent.id]
    if log then
      tool_use(log, agent, ev)
    end
  end
  if not starts[ev.name] then
    return
  end
  -- A call that starts or continues an agent, which can come after its agent_start.
  local input = type(ev.input) == "table" and ev.input or {}
  if ev.name == "SendMessage" then
    local text = type(input.message) == "string" and input.message or input.content
    messages[ev.id] = type(text) == "string" and vim.trim(text) ~= "" and text or nil
  end
  local filled = false
  for _, other in pairs(logs) do
    if other.await and other.await.tool == ev.id then
      local started = agents.by_tool(ev.id)
      fill(other, ev.name == "SendMessage" and messages[ev.id] or started and started.prompt)
      filled = true
    end
  end
  -- A message to an agent that still runs starts no run. It reads the
  -- message at its next step.
  local to = ev.name == "SendMessage" and agents.get(input.to or input.recipient)
  local target = to and to.status == "running" and to.tool_use_id ~= ev.id and logs[to.id]
  if target and not filled and messages[ev.id] then
    message(target, nil, messages[ev.id])
  end
end

function M.tool_result(ev)
  local reason = sent_back[ev.id]
  sent_back[ev.id] = nil
  local agent = agents.of(ev)
  local log = agent and logs[agent.id]
  if not (log and log.tools[ev.id]) then
    return
  end
  local text, group = transcript.summary(log.tools[ev.id], ev)
  if reason and agent then
    text, group = ("Sent back to %s: %s"):format(agents.name(agent), reason), nil
  elseif agent and ev.is_error and transcript.held_back(ev) then
    text, group = "Sent back to " .. agents.name(agent), nil
  end
  finish(log, ev.id, ev.is_error, text, group)
end

function M.send_back(ev)
  if ev.agent_id and ev.tool_use_id then
    sent_back[ev.tool_use_id] = ev.reason
  end
end

function M.text(ev)
  local agent = agents.of(ev)
  local log = agent and (agent.status == "running" and log_of(agent) or logs[agent.id])
  local text = type(ev.text) == "string" and vim.trim(ev.text) or ""
  if not log or text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (i == 1 and "⏺ " or "  ") .. line
  end
  log.text = true
  put(log, lines, { { 0, 0, #"⏺", "AnvimBullet" } })
end

local ended = { failed = "Failed", stopped = "Stopped" }

-- The end line of an agent's run, as its tool line in the transcript reads.
-- A late end, such as the one after a turn's end stopped the agent, draws it
-- again at the end. Without any text, the summary is the last text.
local function settle(log, agent)
  if agent.status == "running" or log.order ~= agent.order then
    return
  end
  local usage = agent.usage or {}
  local key = table.concat({ agent.status, agent.summary or "", vim.inspect(usage) }, "\0")
  if log.ending and log.ending.key == key then
    return
  end
  for id in pairs(log.tools) do
    finish(log, id, true, "Interrupted", "AnvimToolError")
  end
  local ok = agent.status == "completed"
  local text = ok
      and transcript.agent_done(
        {},
        { totalToolUseCount = usage.tool_uses, totalTokens = usage.tokens, totalDurationMs = usage.duration_ms }
      )
    or ended[agent.status]
    or "Stopped"
  local lines, marks = {}, {}
  local summary = vim.trim(agent.summary or "")
  if not log.text and summary ~= "" then
    for i, line in ipairs(vim.split(summary, "\n", { plain = true })) do
      lines[i] = (i == 1 and "⏺ " or "  ") .. line
    end
    marks[1] = { 0, 0, #"⏺", "AnvimBullet" }
  end
  local line = "✻ " .. text
  lines[#lines + 1] = line
  vim.list_extend(marks, {
    { #lines - 1, 0, #"✻", ok and "AnvimToolOk" or "AnvimToolError" },
    { #lines - 1, #"✻", #line, "AnvimResult" },
  })
  marks[#marks + 1] = { 0, anchor = true }
  local row = log.ending and mark_row(log.buf, log.ending.mark)
  if row then
    local count = log.ending.count
    api.nvim_buf_clear_namespace(log.buf, ns, row, row + count)
    write(log, function(buf)
      api.nvim_buf_set_lines(buf, row, row + count, false, {})
    end)
  end
  local ids = put(log, lines, marks)
  log.ending = { mark = ids[#ids], count = #lines, key = key }
end

-- Beyond M.max_logs, the logs of agents that neither run nor are in
-- agents.ended() go, the oldest end first. A log that a window shows stays.
function trim()
  local keep = {}
  for _, agent in ipairs(vim.list_extend(agents.running(), agents.ended())) do
    keep[agent.id] = true
  end
  local count, spare = 0, {}
  for id, log in pairs(logs) do
    count = count + 1
    local agent = agents.get(id)
    if agent and not keep[id] and #vim.fn.win_findbuf(log.buf) == 0 then
      spare[#spare + 1] = agent
    end
  end
  -- Past agents ended before the others.
  table.sort(spare, function(a, b)
    return (a.ended_order or a.order) < (b.ended_order or b.order)
  end)
  for i = 1, math.min(count - M.max_logs, #spare) do
    drop(spare[i].id)
  end
end

-- The logs of agents that anvim forgot go. A call that waits takes its
-- agent's color, which can change.
local function refresh()
  for id, log in pairs(logs) do
    local agent = agents.get(id)
    if not agent then
      drop(id)
    else
      -- One broken log must not fail the event for every other handler.
      local ok, err = pcall(function()
        settle(log, agent)
        for _, tool in pairs(log.tools) do
          local row = mark_row(log.buf, tool.mark)
          if row then
            hl(log.buf, row, 0, #"⏺", agents.group(agent.slot), { id = tool.mark })
          end
        end
      end)
      if not ok then
        require("anvim.sidecar").log("agent log of " .. id .. " failed: " .. err)
      end
    end
  end
  trim()
end

function M.finish(ev)
  local agent = agents.get(ev.agent_id)
  local log = agent and logs[agent.id]
  if agent and not log and vim.tbl_contains(agents.ended(), agent) then
    log = log_of(agent)
  end
  if log then
    settle(log, agent)
  end
end

function M.clear()
  for id in pairs(logs) do
    drop(id)
  end
  messages, seen, sent_back = {}, {}, {}
end

-- After agents.lua, whose handlers make and end the agents first.
function M.attach(sidecar)
  sidecar.on("agent_start", M.start)
  sidecar.on("agent_end", M.finish)
  sidecar.on("agent_text", M.text)
  sidecar.on("tool_use", M.tool_use)
  sidecar.on("tool_result", M.tool_result)
  sidecar.on("send_back", M.send_back)
  sidecar.on("reset", M.clear)
  sidecar.on("history", M.clear)
  sidecar.on("exit", M.clear)
  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("anvim.agentlog", {}),
    pattern = "AnvimAgents",
    callback = refresh,
  })
end

return M
