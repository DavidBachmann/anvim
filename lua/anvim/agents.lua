-- The session's subagents, by agent_id. Running agents get slots 1 to 4, the
-- lowest free slot first, and each slot has a color. The main agent is slot 0.
local M = {}

local api = vim.api

M.slots = 4

---@class anvim.Agent
---@field id string
---@field tool_use_id string The Agent tool call that started it.
---@field type string?
---@field description string
---@field slot integer? 1 to M.slots while it runs. A fifth agent at once waits for one.
---@field status 'running'|'completed'|'failed'|'stopped'
---@field background boolean
---@field depth integer
---@field parent string? The agent_id of the subagent that started it.
---@field files string[] The files it edited.
---@field tools integer Its tool calls.
---@field tokens integer?
---@field context { tokens: integer, max: integer?, percent: integer? }? How full its context window is.
---@field activity string? What it does now, such as "Editing alpha.js".
---@field summary string?
---@field usage { tool_uses: integer?, tokens: integer?, duration_ms: integer? }? Its totals, once it ended.
---@field order integer
---@field prompt string? The prompt of the Agent call that started it.
---@field model string? A Codex agent's model, as far as anvim knows it.
---@field effort string? A Codex agent's reasoning effort, as far as anvim knows it.
---@field last_slot integer? The slot it had when it ended.
---@field ended_order integer? When it ended, counted as `order` is.
---@field past boolean? It ended before the user's last prompt.
---@field started integer When its run started, as M.clock() tells it.

---@type table<string, anvim.Agent>
local agents = {}
---@type table<string, anvim.Agent>
local by_tool = {}
---@type table<integer, anvim.Agent>
local slots = {}
-- The input of an Agent tool call that came before its agent_start.
---@type table<string, table>
local starts = {}
-- The main agent has no record of its own. Its run is the turn.
local main = { slot = 0, files = {} }
-- The file of each edit that waits for its result.
---@type table<string, { agent: anvim.Agent, path: string }>
local edits = {}
local order = 0

-- An agent's prompt is kept whole up to this many characters.
M.prompt_max = 8000
-- The clock of each run's start, in ms. Specs replace it.
M.clock = vim.uv.now
-- The ended agents that are not past, at most.
M.ended_max = 8

-- The files that agents write to, or the files of their places, changed.
function M.files_changed()
  api.nvim_exec_autocmds("User", { pattern = "AnvimAgentFiles", modeline = false })
end
local files_changed = M.files_changed

---@alias anvim.Cleared 'exit'|'restart'|'reset'|'history'

-- Agents started, ended or changed slots, or the focus moved. The event's
-- `data.cleared` says why the session forgot every agent. A handler that
-- fires AnvimAgents during a clear, before follow.lua's handler, would make
-- that handler run without the reason, and the exit notice would be lost.
---@param cleared anvim.Cleared?
function M.changed(cleared)
  api.nvim_exec_autocmds("User", { pattern = "AnvimAgents", modeline = false, data = { cleared = cleared } })
  files_changed()
end

---@param slot integer?
---@return string group
function M.group(slot)
  if slot == 0 then
    return "AnvimClaude"
  end
  return slot and slot <= M.slots and "AnvimAgent" .. slot or "Comment"
end

---@return anvim.Agent?
function M.get(id)
  return agents[id]
end

---@return anvim.Agent?
function M.in_slot(slot)
  return slots[slot]
end

-- The tool calls that start an agent: Claude Code's Agent tool, and anvim's
-- codex tool (sidecar/src/codex.ts).
M.codex_tool = "mcp__anvim__codex"
local spawn_tools = { Agent = true, Task = true, [M.codex_tool] = true }

---@param name string?
---@return boolean
function M.spawns(name)
  return spawn_tools[name] == true
end

-- As its tool line names it, by its type, and then its slot: Explore 2.
---@param agent anvim.Agent
---@return string
function M.name(agent)
  local name = agent.type and agent.type ~= "" and agent.type ~= "general-purpose" and agent.type or "Agent"
  return agent.slot and ("%s %d"):format(name, agent.slot) or name
end

-- What the agent runs with, such as "gpt-5.1-codex · low", or nil.
---@param agent anvim.Agent
---@return string?
function M.settings(agent)
  local parts = {}
  parts[#parts + 1] = agent.model
  parts[#parts + 1] = agent.effort
  return #parts > 0 and table.concat(parts, " · ") or nil
end

---@param id string The id of the Agent tool call that started the agent.
---@return anvim.Agent?
function M.by_tool(id)
  return by_tool[id]
end

-- The agent that a tool event comes from, or nil for the main agent.
---@param ev { agent_id: string?, parent_id: string? }
---@return anvim.Agent?
function M.of(ev)
  return agents[ev.agent_id] or by_tool[ev.parent_id]
end

-- The running agents, by slot, then the ones without a slot as they started.
---@return anvim.Agent[]
function M.running()
  local list = {}
  for _, agent in pairs(agents) do
    if agent.status == "running" then
      list[#list + 1] = agent
    end
  end
  table.sort(list, function(a, b)
    local sa, sb = a.slot or math.huge, b.slot or math.huge
    if sa ~= sb then
      return sa < sb
    end
    return a.order < b.order
  end)
  return list
end

local function free_slot()
  for slot = 1, M.slots do
    if not slots[slot] then
      return slot
    end
  end
end

-- A freed slot goes to the agent that has waited longest for one.
local function stop(agent, status)
  if agent.status == "running" then
    order = order + 1
    agent.ended_order = order
  end
  agent.status = status
  local slot = agent.slot
  if not slot then
    return
  end
  slots[slot], agent.slot, agent.last_slot = nil, nil, slot
  local next_agent
  for _, other in pairs(agents) do
    if other.status == "running" and not other.slot and (not next_agent or other.order < next_agent.order) then
      next_agent = other
    end
  end
  if next_agent then
    slots[slot], next_agent.slot = next_agent, slot
  end
end

-- The tool call that started an agent can come before or after agent_start.
local function fill(agent, input)
  if type(input) ~= "table" then
    return
  end
  agent.type = agent.type or (type(input.subagent_type) == "string" and input.subagent_type or nil)
  if agent.description == "" and type(input.description) == "string" then
    agent.description = input.description
  end
  if not agent.prompt and type(input.prompt) == "string" then
    agent.prompt = vim.fn.strcharpart(input.prompt, 0, M.prompt_max)
  end
end

-- SendMessage can continue an agent that ended. It starts again with its old
-- agent_id, and a run of its own.
function M.start(ev)
  local agent = ev.agent_id and agents[ev.agent_id]
  if not (ev.agent_id and ev.tool_use_id) or (agent and agent.status == "running") then
    return
  end
  order = order + 1
  -- In place: other tables hold the agent.
  agent = agent or { id = ev.agent_id, description = "" }
  agent.tool_use_id = ev.tool_use_id
  agent.type = ev.subagent_type or agent.type
  agent.model = type(ev.model) == "string" and ev.model or nil
  agent.effort = type(ev.effort) == "string" and ev.effort or nil
  if ev.description and ev.description ~= "" then
    agent.description = ev.description
  end
  agent.status, agent.past = "running", nil
  -- A restart is a run of its own.
  agent.last_slot, agent.summary, agent.usage, agent.activity = nil, nil, nil, nil
  agent.started = M.clock()
  -- An agent that a background agent starts works on after the turn too.
  local parent = ev.parent_agent_id and agents[ev.parent_agent_id]
  agent.background = ev.background == true or (parent ~= nil and parent.background)
  agent.depth = tonumber(ev.depth) or 1
  agent.parent = ev.parent_agent_id
  agent.files, agent.tools, agent.order = {}, 0, order
  agent.slot = free_slot()
  if agent.slot then
    slots[agent.slot] = agent
  end
  agents[agent.id], by_tool[agent.tool_use_id] = agent, agent
  fill(agent, starts[agent.tool_use_id])
  starts[agent.tool_use_id] = nil
  M.changed()
end

function M.progress(ev)
  local agent = agents[ev.agent_id]
  if agent then
    agent.activity = ev.description
    agent.tokens = tonumber(ev.tokens) or agent.tokens
  end
end

-- With Ctrl+B, a foreground agent works on after the turn.
function M.background(ev)
  local agent = agents[ev.agent_id]
  if agent then
    agent.background = true
    M.changed()
  end
end

function M.context(ev)
  local agent = agents[ev.agent_id]
  if agent then
    agent.context = { tokens = tonumber(ev.tokens) or 0, max = tonumber(ev.max), percent = tonumber(ev.percent) }
  end
end

function M.finish(ev)
  local agent = agents[ev.agent_id]
  if not agent then
    return
  end
  agent.summary = ev.summary or agent.summary
  agent.usage =
    { tool_uses = tonumber(ev.tool_uses), tokens = tonumber(ev.tokens), duration_ms = tonumber(ev.duration_ms) }
  local was = agent.status
  stop(agent, ev.status or "completed")
  if was == "running" then
    M.changed()
  end
end

-- The line of an edit, from the file as it is before the edit or after it.
function M.edit_line(path, input)
  -- bufnr() also matches part of a name, such as a.lua in a.lua.orig.
  local buf = vim.fn.bufnr(path)
  local ok, lines
  if buf > 0 and api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) == path then
    ok, lines = true, api.nvim_buf_get_lines(buf, 0, -1, false)
  else
    ok, lines = pcall(vim.fn.readfile, path)
  end
  if not ok then
    return 1
  end
  local text = table.concat(lines, "\n")
  for _, s in ipairs({ input.old_string, input.new_string }) do
    local at = type(s) == "string" and s ~= "" and text:find(s, 1, true)
    if at then
      return select(2, text:sub(1, at - 1):gsub("\n", "")) + 1
    end
  end
  return 1
end

-- The path field of each edit tool.
M.edit_keys = { Edit = "file_path", Write = "file_path", NotebookEdit = "notebook_path" }
local edit_keys = M.edit_keys

local function start_edit(id, agent, path)
  if type(path) == "string" and not (edits[id] and edits[id].path == path) then
    edits[id] = { agent = agent, path = path }
    files_changed()
  end
end

-- Only the main agent's tool input streams. Its path comes before the rest
-- of the edit.
function M.tool_field(ev)
  if ev.phase == "end" and edit_keys[ev.name] == ev.key then
    start_edit(ev.id, main, ev.value)
  end
end

function M.tool_use(ev)
  if M.spawns(ev.name) then
    local agent = by_tool[ev.id]
    if agent then
      fill(agent, ev.input)
    else
      starts[ev.id] = ev.input
    end
  end
  local input = type(ev.input) == "table" and ev.input or {}
  local path = input.file_path or input.notebook_path
  local agent = M.of(ev)
  if not agent then
    if edit_keys[ev.name] and not (ev.agent_id or ev.parent_id) then
      start_edit(ev.id, main, path)
    end
    return
  end
  agent.tools = agent.tools + 1
  if edit_keys[ev.name] then
    start_edit(ev.id, agent, path)
  end
end

-- A file counts as edited once the edit worked.
function M.tool_result(ev)
  local edit = edits[ev.id]
  if not edit then
    return
  end
  edits[ev.id] = nil
  if not ev.is_error and not vim.tbl_contains(edit.agent.files, edit.path) then
    edit.agent.files[#edit.agent.files + 1] = edit.path
  end
  files_changed()
end

-- The files that each agent with a slot writes to in its run: the edits that
-- worked, and the ones on their way. Only running agents have slots. The
-- slots of each file are in order.
---@return table<string, integer[]>
function M.marks()
  local marks = {}
  local function add(path, slot)
    local list = marks[path] or {}
    marks[path] = list
    if not vim.tbl_contains(list, slot) then
      list[#list + 1] = slot
    end
  end
  for _, agent in ipairs(vim.list_extend({ main }, vim.tbl_values(agents))) do
    if agent.slot then
      for _, path in ipairs(agent.files) do
        add(path, agent.slot)
      end
    end
  end
  for _, edit in pairs(edits) do
    if edit.agent.slot then
      add(edit.path, edit.agent.slot)
    end
  end
  for _, list in pairs(marks) do
    table.sort(list)
  end
  return marks
end

-- The user sent a prompt. The agents that ended before it are past.
function M.prompt_sent()
  local any = false
  for _, agent in pairs(agents) do
    if agent.status ~= "running" and not agent.past then
      agent.past, any = true, true
    end
  end
  if any then
    M.changed()
  end
end

-- The agents that ended since the user's last prompt, newest first.
---@return anvim.Agent[]
function M.ended()
  local list = {}
  for _, agent in pairs(agents) do
    if agent.status ~= "running" and not agent.past then
      list[#list + 1] = agent
    end
  end
  table.sort(list, function(a, b)
    return (a.ended_order or a.order) > (b.ended_order or b.order)
  end)
  return vim.list_slice(list, 1, M.ended_max)
end

-- A foreground agent ends with the turn that started it, even when its end
-- never came, as after an interrupt.
function M.turn_end()
  local any = false
  for _, agent in pairs(agents) do
    if agent.status == "running" and not agent.background then
      stop(agent, "stopped")
      any = true
    end
  end
  starts = {}
  -- The main agent's run ends with the turn.
  local files = #main.files > 0
  main.files = {}
  for id, edit in pairs(edits) do
    if edit.agent == main then
      files = true
      edits[id] = nil
    elseif edit.agent.status ~= "running" then
      edits[id] = nil
    end
  end
  if any then
    M.changed()
  elseif files then
    files_changed()
  end
end

-- The sidecar exited or restarted, /clear started over, or a resumed session
-- took the place of this one.
---@param reason anvim.Cleared?
function M.clear(reason)
  local any = next(agents) ~= nil
  local files = next(edits) ~= nil or #main.files > 0
  agents, by_tool, slots, starts, edits = {}, {}, {}, {}, {}
  main.files = {}
  if any then
    M.changed(reason)
  elseif files then
    files_changed()
  end
end

function M.attach(sidecar)
  sidecar.on("agent_start", M.start)
  sidecar.on("agent_progress", M.progress)
  sidecar.on("agent_background", M.background)
  sidecar.on("agent_context", M.context)
  sidecar.on("agent_end", M.finish)
  sidecar.on("tool_field", M.tool_field)
  sidecar.on("tool_use", M.tool_use)
  sidecar.on("tool_result", M.tool_result)
  sidecar.on("turn_end", M.turn_end)
  sidecar.on("reset", function()
    M.clear("reset")
  end)
  sidecar.on("history", function()
    M.clear("history")
  end)
  sidecar.on("exit", function(ev)
    M.clear(ev.restart and "restart" or "exit")
  end)
end

return M
