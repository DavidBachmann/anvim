---@module "luassert"

local agents = require("anvim.agents")
local follow = require("anvim.follow")
local helpers = require("helpers")
local permission = require("anvim.permission")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local api = vim.api
local buf_lines = helpers.buf_lines

local start_time = os.time({ year = 2026, month = 10, day = 22, hour = 9, min = 5, sec = 7 })
local now = start_time

local function chat()
  return buf_lines(transcript.buf())
end

local function log()
  return buf_lines(transcript.log_buf())
end

-- The lines of a buffer, each with its time after an @ where it has one.
local function stamped(buf)
  local out = {}
  for row, line in ipairs(buf_lines(buf)) do
    local time = transcript.time_of(buf, row - 1)
    out[row] = time and ("%s @%s"):format(line, time) or line
  end
  return out
end

-- The highlight groups of the transcript's marks on the first line `text`.
local function groups(buf, text)
  local row = vim.fn.index(buf_lines(buf), text)
  assert(row >= 0, ("no line %q in:\n%s"):format(text, table.concat(buf_lines(buf), "\n")))
  local ns = api.nvim_get_namespaces()["anvim.transcript"]
  local out = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
    out[#out + 1] = mark[4].hl_group
  end
  return out
end

local next_id = 0

-- A tool call of the main agent, as the sidecar streams it.
local function call(name, tool_input)
  next_id = next_id + 1
  local id = "log" .. next_id
  sidecar.dispatch({ type = "tool_start", id = id, name = name })
  sidecar.dispatch({ type = "tool_use", id = id, name = name, input = tool_input })
  return id
end

local function result(id, is_error, text, extra)
  local ev = { type = "tool_result", id = id, is_error = is_error, text = text or "ok" }
  sidecar.dispatch(vim.tbl_extend("force", ev, extra or {}))
end

describe("the main log", function()
  local restore ---@type fun()?

  before_each(function()
    helpers.start()
    sidecar.dispatch({ type = "reset" })
    transcript.clear()
    now = start_time
    transcript.clock = function()
      return now
    end
    transcript.pane_on = true
  end)

  after_each(function()
    transcript.pane_on = false
    transcript.clock = os.time
    permission.cancel_all()
    agents.clear()
    follow.forget()
    transcript.turn_end()
    transcript.clear()
    local fn = restore
    restore = nil
    if fn then
      fn()
    end
  end)

  it("takes the main agent's tool calls, and the chat counts each run in one line", function()
    transcript.user("Find the bug\nin a.lua")
    local read = call("Read", { file_path = state.cwd .. "/a.lua" })
    assert.are.same({ "❯ Find the bug", "  in a.lua", "", "  ⎿  1 tool call" }, chat())
    now = start_time + 2
    local bash = call("Bash", { command = "ls" })
    assert.are.same("  ⎿  2 tool calls", chat()[4], "the count grows as calls come")
    result(read, false, "x", { result = { file = { numLines = 4 } } })
    result(bash, false, "a.lua")
    now = start_time + 3
    transcript.text_delta("Found it.")
    transcript.text_stop()
    now = start_time + 4
    local edit = call("Edit", { file_path = state.cwd .. "/a.lua", old_string = "a", new_string = "b" })
    result(edit, false, "ok")
    assert.are.same({
      "❯ Find the bug @09:05:07",
      "  in a.lua",
      "",
      "  ⎿  2 tool calls @09:05:07",
      "",
      "⏺ Found it. @09:05:10",
      "",
      "  ⎿  1 tool call @09:05:11",
    }, stamped(transcript.buf()))
    assert.are.same({
      "⏺ Read(a.lua) @09:05:07",
      "  ⎿  Read 4 lines",
      "⏺ Bash(ls) @09:05:09",
      "  ⎿  a.lua",
      "",
      "⏺ Edit(a.lua) @09:05:11",
      "  ⎿  Added 1 line, removed 1 line",
    }, stamped(transcript.log_buf()))
    assert.are.same({ "AnvimResult" }, groups(transcript.buf(), "  ⎿  2 tool calls"))
    assert.are.same({ "AnvimToolOk", "AnvimToolName" }, groups(transcript.log_buf(), "⏺ Read(a.lua)"))
    assert.are.same("anvim://tools", api.nvim_buf_get_name(transcript.log_buf()))
    assert.is_false(vim.bo[transcript.log_buf()].modifiable)
    assert.is_true(vim.b[transcript.log_buf()].anvim_stop_at_end)
    assert.are.same("Found it.", transcript.last_reply())

    transcript.clear()
    assert.are.same({ "" }, log())
    for _, name in ipairs({ "anvim.transcript", "anvim.time" }) do
      local ns = api.nvim_get_namespaces()[name]
      assert.are.same({}, api.nvim_buf_get_extmarks(transcript.log_buf(), ns, 0, -1, {}), name)
    end
  end)

  it("counts a tool call that comes first at the chat's top", function()
    result(call("Bash", { command = "a" }), false)
    assert.are.same({ "  ⎿  1 tool call @09:05:07" }, stamped(transcript.buf()))
    assert.are.same({ "⏺ Bash(a) @09:05:07", "  ⎿  ok" }, stamped(transcript.log_buf()))
    transcript.user("Next")
    result(call("Bash", { command = "b" }), false)
    assert.are.same({ "  ⎿  1 tool call", "", "❯ Next", "", "  ⎿  1 tool call" }, chat())
    assert.are.same({ "⏺ Bash(a)", "  ⎿  ok", "", "⏺ Bash(b)", "  ⎿  ok" }, log())
  end)

  it("keeps Claude's questions and the user's answers in the chat", function()
    local fruit = {
      question = "Which fruit do you like?",
      header = "Fruit",
      options = { { label = "Apple" }, { label = "Pear" } },
    }
    local asked = call("AskUserQuestion", { questions = { fruit } })
    local answers = { [fruit.question] = "Neither. I like mango\nand kiwi." }
    result(asked, false, "The user answered", { result = { questions = { fruit }, answers = answers } })
    result(call("AskUserQuestion", { questions = { fruit } }), true, "The user doesn't want to proceed")
    assert.are.same({
      "⏺ User answered Claude's questions:",
      "  ⎿  · Which fruit do you like? → Neither. I like mango",
      "       and kiwi.",
      "",
      "⏺ User declined to answer questions",
      "  ⎿  · Which fruit do you like? (Apple / Pear)",
    }, chat())
    assert.are.same({ "" }, log())
  end)

  it("shows each call's whole input and output in verbose mode, also in an agent's log", function()
    local input = require("anvim.input")
    restore = function()
      if transcript.verbose then
        input.toggle_verbose()
      end
    end
    transcript.user("List")
    result(call("Bash", { command = "printf 'a\\nb'\necho c" }), false, "a\nb\nc", { result = { stdout = "a\nb\nc" } })
    transcript.user("Next")
    result(call("Read", { file_path = state.cwd .. "/a.lua" }), false, "x", { result = { file = { numLines = 4 } } })
    result(call("Bash", { command = "false" }), true, "Exit code 1\nboom")
    call("Bash", { command = "sleep 1\necho done" })
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_v",
      name = "Agent",
      input = { description = "Look", prompt = "Look" },
    })
    sidecar.dispatch({ type = "agent_start", agent_id = "av", tool_use_id = "tu_v", description = "Look", depth = 1 })
    local sub = { parent_id = "tu_v", agent_id = "av" }
    sidecar.dispatch(
      vim.tbl_extend("force", sub, { type = "tool_use", id = "sv", name = "Bash", input = { command = "ls\npwd" } })
    )
    result("sv", false, "a.lua\n/x", sub)
    local agent_log = require("anvim.agentlog").buf("av")
    local summary, agent_summary = log(), buf_lines(agent_log)
    assert.are.same({
      "⏺ Bash(printf 'a\\nb'...)",
      "  ⎿  a ... +2 lines",
      "",
      "⏺ Read(a.lua)",
      "  ⎿  Read 4 lines",
      "⏺ Bash(false)",
      "  ⎿  Exit code 1 ... +1 lines",
      "⏺ Bash(sleep 1...)",
      "⏺ Agent(Look)",
      "  ⎿  Bash(ls...)",
    }, summary)

    input.toggle_verbose()
    assert.are.same({
      "⏺ Bash(printf 'a\\nb'",
      "  echo c)",
      "  ⎿  a",
      "     b",
      "     c",
      "",
      "⏺ Read(a.lua)",
      "  ⎿  Read 4 lines",
      "⏺ Bash(false)",
      "  ⎿  Exit code 1",
      "     boom",
      "⏺ Bash(sleep 1",
      "  echo done)",
      "⏺ Agent(Look)",
      "  ⎿  Bash(ls...)",
    }, log())
    assert.are.same({ "⏺ Bash(ls", "  pwd)", "  ⎿  a.lua", "     /x" }, vim.list_slice(buf_lines(agent_log), 3))
    assert.are.same(
      { "⏺ Bash(printf 'a\\nb' @09:05:07", "  echo c)" },
      vim.list_slice(stamped(transcript.log_buf()), 1, 2)
    )
    assert.are.same("09:05:07", transcript.time_of(agent_log, 2))
    assert.are.same({ "AnvimToolError", "AnvimToolName" }, groups(transcript.log_buf(), "⏺ Bash(false)"))
    assert.are.same({ "AnvimToolError" }, groups(transcript.log_buf(), "     boom"))

    input.toggle_verbose()
    assert.are.same(summary, log())
    assert.are.same(agent_summary, buf_lines(agent_log))
  end)
end)
