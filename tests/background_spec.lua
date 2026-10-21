---@module "luassert"

local agents = require("anvim.agents")
local follow = require("anvim.follow")
local helpers = require("helpers")
local permission = require("anvim.permission")
local sessions = require("anvim.sessions")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local api = vim.api

-- The events of the recorded session, with the paths in the temp project.
-- The events that need a real sidecar stay out.
local function recording()
  local skip = { commands = true, init = true, status = true, context = true, await_preview = true }
  local events = {}
  for _, frame in ipairs(vim.fn.readfile(helpers.root .. "/tests/fixtures/background-session.jsonl")) do
    local json = frame:match("^%d+ (.*)$"):gsub("/ANVIM_FIXTURE", helpers.tmp)
    local ev = vim.json.decode(json, { luanil = { object = true, array = true } })
    if not skip[ev.type] then
      events[#events + 1] = ev
    end
  end
  return events
end

local function lines()
  return helpers.buf_lines(transcript.buf())
end

-- The lines of the item that starts with `head`, up to the next blank line.
local function item(head)
  local all, out = lines(), nil
  for _, line in ipairs(all) do
    if out and line == "" then
      break
    elseif out then
      out[#out + 1] = line
    elseif line == head then
      out = { line }
    end
  end
  return out or error(("no item %q in:\n%s"):format(head, table.concat(all, "\n")))
end

-- The bullet's group on the line `head`.
local function bullet(head)
  local buf = transcript.buf()
  local ns = api.nvim_get_namespaces()["anvim.transcript"]
  for row, line in ipairs(lines()) do
    if line == head then
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, 0 }, { details = true })) do
        if mark[4].end_col == #"⏺" then
          return mark[4].hl_group
        end
      end
    end
  end
  error("no line " .. head)
end

local function slots()
  return vim.tbl_map(function(agent)
    return { agent.description, agent.slot or false }
  end, agents.running())
end

local function turn_end()
  sidecar.dispatch({
    type = "turn_end",
    subtype = "success",
    is_error = false,
    duration_ms = 1,
    cost_usd = 0,
    num_turns = 1,
  })
end

-- An Agent call that the main agent started in the background, as Claude Code
-- sends it: the call, agent_start, and the result at once.
local function launch(id, description)
  local tool_id = "tu_" .. id
  sidecar.dispatch({ type = "tool_start", id = tool_id, name = "Agent" })
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = "Agent",
    input = { description = description, subagent_type = "Explore", run_in_background = true },
  })
  sidecar.dispatch({
    type = "agent_start",
    agent_id = id,
    tool_use_id = tool_id,
    description = description,
    subagent_type = "Explore",
    depth = 1,
    background = true,
  })
  sidecar.dispatch({
    type = "tool_result",
    id = tool_id,
    is_error = false,
    text = "Async agent launched successfully.",
    result = { isAsync = true, status = "async_launched", agentId = id },
  })
  return tool_id
end

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  transcript.clear()
end

-- The tree's marks on alpha.js and beta.js, as "slot:kind".
local function tree_marks()
  local ret = {}
  for _, name in ipairs({ "alpha", "beta" }) do
    local list = require("anvim.tree").marks({ file = helpers.tmp .. "/" .. name .. ".js" }) or {}
    ret[name] = table.concat(
      vim.tbl_map(function(mark)
        return ("%d:%s"):format(mark.slot, mark.kind)
      end, list),
      " "
    )
  end
  return ret
end

describe("background agents", function()
  after_each(function()
    permission.cancel_all()
    agents.clear()
    follow.forget()
  end)

  it("replays two agents that work on after the turn, and whose ends start turns", function()
    fresh()
    for _, name in ipairs({ "alpha", "beta" }) do
      vim.fn.writefile(
        { ("export function %s() {"):format(name), ('  return "%s";'):format(name), "}" },
        helpers.tmp .. "/" .. name .. ".js"
      )
    end
    local events = recording()
    local fast_line, slow_line = "⏺ Agent(Add FAST marker to alpha.js)", "⏺ Agent(Add SLOW marker to beta.js)"
    local i = 1
    local function play_to(pred)
      while not pred(events[i]) do
        sidecar.dispatch(events[i])
        i = i + 1
      end
    end
    play_to(function(ev)
      return ev.type == "turn_end"
    end)
    sidecar.dispatch(events[i])
    i = i + 1
    assert.are.same({ fast_line, "  ⎿  Backgrounded agent", "     Read(alpha.js)" }, item(fast_line))
    assert.are.same({ slow_line, "  ⎿  Backgrounded agent" }, item(slow_line))
    assert.are.same({ { "Add FAST marker to alpha.js", 1 }, { "Add SLOW marker to beta.js", 2 } }, slots())
    assert.are.same("AnvimAgent1", bullet(fast_line))
    assert.are.same("AnvimAgent2", bullet(slow_line))
    assert.is_false(state.busy)
    assert.are.same({ alpha = "1:place", beta = "" }, tree_marks())

    -- Between turns only the agents work, and no turn starts.
    local fast_end = function(ev)
      return ev.type == "agent_end"
    end
    for j = i, #events do
      if fast_end(events[j]) then
        break
      end
      assert.are_not.same("turn_start", events[j].type)
    end
    play_to(fast_end)
    assert.are.same(
      { fast_line, "  ⎿  Backgrounded agent", "     Read(alpha.js)", "     Edit(alpha.js)" },
      item(fast_line)
    )
    assert.are.same(
      { slow_line, "  ⎿  Backgrounded agent", "     Bash(sleep 8)", "     Read(beta.js)" },
      item(slow_line)
    )
    assert.is_false(state.busy)
    assert.are.same({ alpha = "1:place", beta = "2:place" }, tree_marks())

    sidecar.dispatch(events[i])
    i = i + 1
    assert.are.same({ alpha = "", beta = "2:place" }, tree_marks())
    assert.are.same({ fast_line, "  ⎿  Done (2 tool uses · 35.8k tokens · 5.1s)" }, item(fast_line))
    assert.are.same("AnvimToolOk", bullet(fast_line))
    assert.are.same({ { "Add SLOW marker to beta.js", 2 } }, slots())
    local fast_row = '⏺ Agent "Add FAST marker to alpha.js" finished'
    assert.are.same(
      { fast_row, "  ⎿  The edit succeeded: `// FAST` is now the first line of alpha.js." },
      vim.list_slice(lines(), #lines() - 1)
    )
    assert.are.same("AnvimToolOk", bullet(fast_row))

    -- The notification turn's reply is Claude's last reply, without the turn's before.
    play_to(function(ev)
      return ev.type == "turn_end"
    end)
    sidecar.dispatch(events[i])
    i = i + 1
    local reply = "The FAST subagent finished and added `// FAST` as the first line of alpha.js. "
      .. "The SLOW subagent is still running."
    assert.are.same(reply, transcript.last_reply())

    play_to(function(ev)
      return ev == nil
    end)
    assert.are.same({}, slots())
    assert.are.same({ alpha = "", beta = "" }, tree_marks())
    assert.are.same({
      fast_line,
      "  ⎿  Done (2 tool uses · 35.8k tokens · 5.1s)",
      "",
      slow_line,
      "  ⎿  Done (3 tool uses · 36.0k tokens · 14.4s)",
      "",
      "⏺ launched",
      "",
      fast_row,
      "  ⎿  The edit succeeded: `// FAST` is now the first line of alpha.js.",
      "",
      "⏺ " .. reply,
      "",
      '⏺ Agent "Add SLOW marker to beta.js" finished',
      "  ⎿  The edit succeeded: `// SLOW` is now the first line of beta.js.",
      "",
      "⏺ Both subagents are done. The SLOW subagent added `// SLOW` as the first line of beta.js, "
        .. "and the FAST subagent added `// FAST` to alpha.js.",
    }, lines())
  end)

  it("takes init again, as each turn sends it", function()
    helpers.start()
    local before = { state.session_id, state.model, state.permission_mode, state.process }
    local completion = require("anvim.completion")
    local count = #completion.commands
    local init = {
      type = "init",
      session_id = state.session_id,
      model = state.model,
      cwd = state.cwd,
      permission_mode = state.permission_mode,
      version = "2.1.304",
      slash_commands = { "compact", "clear" },
    }
    sidecar.dispatch(init)
    sidecar.dispatch(init)
    assert.are.same(before, { state.session_id, state.model, state.permission_mode, state.process })
    assert.are.same(count, #completion.commands)
    local names = vim.tbl_map(function(c)
      return c.name
    end, completion.commands)
    assert.are.same(1, #vim.tbl_filter(function(name)
      return name == "resume"
    end, names))
  end)

  it("keeps the focus, the tracking and the agent's requests over the turn end", function()
    fresh()
    local tool_id = launch("b1", "Mark files")
    sidecar.dispatch({ type = "agent_start", agent_id = "f1", tool_use_id = "tu_f1", description = "Fore", depth = 1 })
    follow.set_focus("b1")
    -- A Write of a file that does not exist yet waits for its result.
    local path = helpers.tmp .. "/background_new.lua"
    vim.fn.delete(path)
    sidecar.dispatch({
      type = "tool_use",
      id = "bw1",
      name = "Write",
      input = { file_path = path, content = "return 1" },
      parent_id = tool_id,
      agent_id = "b1",
    })
    local function request(req, agent_id)
      sidecar.dispatch({
        type = "permission_request",
        req = req,
        tool = "Bash",
        input = { command = "ls" },
        agent_id = agent_id,
      })
    end
    request(921, "b1")
    request(922, "f1")
    turn_end()
    -- An agent that starts later paints the Agent lines again.
    sidecar.dispatch({ type = "agent_start", agent_id = "b2", tool_use_id = "tu_b2", description = "Later", depth = 1 })

    assert.are.same("b1", follow.focus)
    assert.are.same({ { "Mark files", 1 }, { "Later", 2 } }, slots())
    local head = "⏺ Explore(Mark files)"
    assert.are.same({ head, "  ⎿  Backgrounded agent", "     Write(background_new.lua)" }, item(head))
    local buf = transcript.buf()
    local ns = api.nvim_get_namespaces()["anvim.transcript.focus"]
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.are.same(1, #marks)
    assert.are.same(head, api.nvim_buf_get_lines(buf, marks[1][2], marks[1][2] + 1, false)[1])
    assert.are.same({ { "◉ focused", "AnvimAgent1" } }, marks[1][4].virt_text)

    vim.fn.writefile({ "return 1" }, path)
    sidecar.dispatch({
      type = "tool_result",
      id = "bw1",
      is_error = false,
      text = "ok",
      parent_id = tool_id,
      agent_id = "b1",
    })
    assert.are.same(path, follow.place().path)

    -- The foreground agent's request went with its turn, the background one's waits.
    assert.is_true(permission.waiting())
    permission.cancel(921)
    assert.is_false(permission.waiting())

    sidecar.dispatch({
      type = "agent_end",
      agent_id = "b1",
      tool_use_id = tool_id,
      status = "completed",
      summary = "Marked 2 files.\nBoth are done.",
      tool_uses = 2,
      tokens = 1500,
      duration_ms = 2300,
    })
    assert.are.same({ head, "  ⎿  Done (2 tool uses · 1.5k tokens · 2.3s)" }, item(head))
    assert.is_nil(follow.focus)
    assert.are.same({
      '⏺ Agent "Mark files" finished',
      "  ⎿  Marked 2 files. ... +1 lines",
      "",
      "✻ Explore 1 ended · focus is back on Claude",
    }, vim.list_slice(lines(), #lines() - 3))
  end)

  it("keeps an agent that a background agent started, and answers each request that a turn's end drops", function()
    fresh()
    launch("p1", "Parent")
    local function start(id, parent)
      sidecar.dispatch({
        type = "agent_start",
        agent_id = id,
        tool_use_id = "tu_" .. id,
        description = id,
        parent_agent_id = parent,
        depth = parent and 2 or 1,
        background = false,
      })
    end
    start("c1", "p1")
    start("f1")
    local function request(req, agent_id)
      sidecar.dispatch({
        type = "permission_request",
        req = req,
        tool = "Bash",
        input = { command = "ls" },
        agent_id = agent_id,
      })
    end
    helpers.capture_sends(function(sent)
      request(931, "c1")
      request(932, "f1")
      -- An agent that /clear forgot.
      request(933, "gone")
      turn_end()
      assert.are.same({ "running", "stopped" }, { agents.get("c1").status, agents.get("f1").status })
      local answers = {}
      for _, msg in ipairs(sent) do
        if msg.type == "permission_response" then
          answers[#answers + 1] = { msg.req, msg.behavior }
        end
      end
      assert.are.same({ { 932, "deny" } }, answers)
      assert.is_true(permission.waiting())
    end)
  end)

  it("ends Claude's reply at an agent's end in a resumed session, as live", function()
    helpers.start()
    local saved = { state.session_id, state.turns }
    sessions.history({
      session_id = "background-reply",
      events = {
        { type = "user", text = "Start one" },
        { type = "text_start" },
        { type = "text_delta", text = "launched" },
        { type = "text_stop" },
        { type = "agent_end", agent_id = "q1", status = "completed", description = "Quick", summary = "Done." },
        { type = "text_start" },
        { type = "text_delta", text = "Quick finished." },
        { type = "text_stop" },
        -- An agent whose end the session did not save.
        { type = "tool_use", id = "u1", name = "Agent", input = { description = "Unsaved", run_in_background = true } },
        { type = "tool_result", id = "u1", is_error = false, text = "Async agent launched successfully.\nagentId: u1" },
      },
    })
    state.session_id, state.turns = saved[1], saved[2]
    assert.are.same("Quick finished.", transcript.last_reply())
    local head = "⏺ Agent(Unsaved)"
    assert.are.same({ head, "  ⎿  Backgrounded agent" }, item(head))
    assert.are.same("AnvimResult", bullet(head), "the line no longer looks busy")
  end)

  it("ends a held line as interrupted when the sidecar exits", function()
    fresh()
    launch("x1", "Never ends")
    turn_end()
    sidecar.dispatch({ type = "exit", code = 0, restart = true })
    state.process = "ready"
    local head = "⏺ Explore(Never ends)"
    assert.are.same({ head, "  ⎿  Interrupted" }, item(head))
    assert.are.same("AnvimToolError", bullet(head))
  end)

  it("draws a resumed session's notification as the agent's end", function()
    helpers.start()
    local saved = { state.session_id, state.turns }
    sessions.history({
      session_id = "background-history",
      events = {
        { type = "user", text = "Start a background agent" },
        {
          type = "tool_use",
          id = "h1",
          name = "Agent",
          input = { description = "Add FAST line", run_in_background = true },
        },
        { type = "tool_result", id = "h1", is_error = false, text = "Async agent launched successfully.\nagentId: a1" },
        { type = "text_start" },
        { type = "text_delta", text = "launched" },
        { type = "text_stop" },
        { type = "user", text = "What next?" },
        {
          type = "agent_end",
          agent_id = "a1",
          tool_use_id = "h1",
          status = "completed",
          description = "Add FAST line",
          summary = "Added it.",
          tool_uses = 2,
          tokens = 16061,
          duration_ms = 7469,
        },
        { type = "agent_end", agent_id = "a2", status = "failed", description = "Lost", summary = "No such file" },
      },
    })
    state.session_id, state.turns = saved[1], saved[2]
    assert.are.same({
      "❯ Start a background agent",
      "",
      "⏺ Agent(Add FAST line)",
      "  ⎿  Done (2 tool uses · 16.1k tokens · 7.5s)",
      "",
      "⏺ launched",
      "",
      "❯ What next?",
      "",
      '⏺ Agent "Add FAST line" finished',
      "  ⎿  Added it.",
      "",
      '⏺ Agent "Lost" failed',
      "  ⎿  No such file",
    }, lines())
    assert.are.same("AnvimToolError", bullet('⏺ Agent "Lost" failed'))
  end)
end)
