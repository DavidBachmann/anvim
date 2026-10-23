---@module "luassert"

local agents = require("anvim.agents")
local follow = require("anvim.follow")
local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local permission = require("anvim.permission")
local sessions = require("anvim.sessions")
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

-- The lines of the item that starts with `head` in `lines`, up to the next
-- blank line or the next tool line.
local function item(lines, head)
  local out
  for _, line in ipairs(lines) do
    if out and (line == "" or line:find("^⏺")) then
      break
    elseif out then
      out[#out + 1] = line
    elseif line == head then
      out = { line }
    end
  end
  return out or error(("no item %q in:\n%s"):format(head, table.concat(lines, "\n")))
end

local function turn_end()
  sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
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

-- Plays a fixture. Each event comes one second after the one before.
local function play(events, from, to)
  for i = from or 1, to or #events do
    now = start_time + i
    sidecar.dispatch(events[i])
  end
end

local function index_of(events, pred, from)
  for i = from or 1, #events do
    if pred(events[i]) then
      return i
    end
  end
  error("no such event")
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
    transcript.tools_apart = true
  end)

  after_each(function()
    transcript.tools_apart = false
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
      "❯ Find the bug",
      "⏺ Read(a.lua) @09:05:07",
      "  ⎿  Read 4 lines",
      "⏺ Bash(ls) @09:05:09",
      "  ⎿  a.lua",
      "",
      "❯ Find the bug",
      "⏺ Edit(a.lua) @09:05:11",
      "  ⎿  Added 1 line, removed 1 line",
    }, stamped(transcript.log_buf()))
    assert.are.same({ "AnvimResult" }, groups(transcript.buf(), "  ⎿  2 tool calls"))
    assert.are.same({ "AnvimResult" }, groups(transcript.log_buf(), "❯ Find the bug"))
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

  it("ends a run at a notice, output and a kept block, and not at a waiting block or the todo list", function()
    transcript.user("Go")
    result(call("Bash", { command = "ls" }), false)
    local block = transcript.block({ "  Do you want to proceed?" }, {})
    result(call("Bash", { command = "pwd" }), false)
    transcript.remove_block(block)
    local todo = call("TodoWrite", { todos = { { content = "Step", status = "in_progress", activeForm = "Doing" } } })
    result(todo, false)
    result(call("Bash", { command = "id" }), false)
    assert.are.same({ "❯ Go", "", "  ⎿  3 tool calls", "", "⏺ Todos · 0 of 1 done", "  ⎿  ☐ Step" }, chat())
    transcript.notice("info", "Conversation compacted")
    result(call("Bash", { command = "a" }), false)
    transcript.output("Done")
    result(call("Bash", { command = "b" }), false)
    transcript.keep_block(transcript.block({ "  Claude's plan:" }, {}))
    result(call("Bash", { command = "c" }), false)
    assert.are.same({
      "❯ Go",
      "",
      "  ⎿  3 tool calls",
      "",
      "✻ Conversation compacted",
      "",
      "  ⎿  1 tool call",
      "  ⎿  Done",
      "",
      "  ⎿  1 tool call",
      "",
      "  Claude's plan:",
      "",
      "  ⎿  1 tool call",
      "",
      "⏺ Todos · 0 of 1 done",
      "  ⎿  ☐ Step",
    }, chat())
    assert.are.same({
      "❯ Go",
      "⏺ Bash(ls)",
      "  ⎿  ok",
      "⏺ Bash(pwd)",
      "  ⎿  ok",
      "⏺ Bash(id)",
      "  ⎿  ok",
      "",
      "❯ Go",
      "⏺ Bash(a)",
      "  ⎿  ok",
      "",
      "❯ Go",
      "⏺ Bash(b)",
      "  ⎿  ok",
      "",
      "❯ Go",
      "⏺ Bash(c)",
      "  ⎿  ok",
    }, log())
  end)

  it("counts a send-back, an error and an interrupt as failed, in the run of each call", function()
    transcript.user("Install it")
    local back = call("Bash", { command = "npm i -g x" })
    sidecar.dispatch({ type = "send_back", tool_use_id = back, reason = "runs outside the sandbox" })
    result(back, true, "PreToolUse:Bash hook error: anvim held this command back and has not asked the user yet.")
    assert.are.same("  ⎿  1 tool call · 1 failed", chat()[3])
    assert.are.same({ "AnvimResult", "AnvimToolError" }, groups(transcript.buf(), "  ⎿  1 tool call · 1 failed"))
    result(call("Bash", { command = "npm test" }), true, "Exit code 1\nnpm error")
    result(call("Bash", { command = "ls" }), false)
    call("Bash", { command = "sleep 9" })
    turn_end()
    assert.are.same({ "❯ Install it", "", "  ⎿  4 tool calls · 3 failed" }, chat())
    assert.are.same({
      "❯ Install it",
      "⏺ Bash(npm i -g x)",
      "  ⎿  Sent back to Claude: runs outside the sandbox",
      "⏺ Bash(npm test)",
      "  ⎿  Exit code 1 ... +1 lines",
      "⏺ Bash(ls)",
      "  ⎿  ok",
      "⏺ Bash(sleep 9)",
      "  ⎿  Interrupted",
    }, log())
    assert.are.same({ "AnvimToolError", "AnvimToolName" }, groups(transcript.log_buf(), "⏺ Bash(sleep 9)"))
  end)

  it("keeps a subagent's calls under its Agent line, and the Agent call counts as one", function()
    for _, name in ipairs({ "alpha", "beta", "gamma" }) do
      vim.fn.writefile(
        { ("export function %s() {"):format(name), ('  return "%s";'):format(name), "}" },
        helpers.tmp .. "/" .. name .. ".js"
      )
    end
    transcript.user("Edit the headers")
    local events = helpers.events("agents-session")
    local first_end = index_of(events, function(ev)
      return ev.type == "agent_end"
    end)
    play(events, 1, first_end - 1)
    assert.are.same({ "❯ Edit the headers", "", "  ⎿  3 tool calls" }, chat())
    local alpha = "⏺ Agent(Edit alpha.js header)"
    assert.are.same({ alpha, "  ⎿  Read(alpha.js)", "     Edit(alpha.js)" }, item(log(), alpha))
    play(events, first_end)
    local lines = stamped(transcript.buf())
    assert.are.same("  ⎿  3 tool calls @" .. transcript.time_of(transcript.log_buf(), 1), lines[3])
    assert(lines[5]:find("^⏺ All three subagents reported success"), lines[5])
    assert.are.same({
      "❯ Edit the headers",
      "⏺ Agent(Edit alpha.js header)",
      "  ⎿  Done (2 tool uses · 37.1k tokens · 5.6s)",
      "⏺ Agent(Edit beta.js header)",
      "  ⎿  Done (2 tool uses · 37.1k tokens · 5.9s)",
      "⏺ Agent(Edit gamma.js header)",
      "  ⎿  Done (2 tool uses · 37.1k tokens · 4.9s)",
    }, log())
    for row, line in ipairs(log()) do
      if line:find("^⏺") then
        assert(transcript.time_of(transcript.log_buf(), row - 1), "no time on " .. line)
      end
    end
  end)

  it("keeps background agents' held lines in the main log, and their end rows in the chat", function()
    for _, name in ipairs({ "alpha", "beta" }) do
      vim.fn.writefile(
        { ("export function %s() {"):format(name), ('  return "%s";'):format(name), "}" },
        helpers.tmp .. "/" .. name .. ".js"
      )
    end
    transcript.user("Mark the files")
    local events = helpers.events("background-session")
    local fast_line, slow_line = "⏺ Agent(Add FAST marker to alpha.js)", "⏺ Agent(Add SLOW marker to beta.js)"
    local i = index_of(events, function(ev)
      return ev.type == "turn_end"
    end)
    play(events, 1, i)
    assert.are.same({ "❯ Mark the files", "", "  ⎿  2 tool calls", "", "⏺ launched" }, chat())
    assert.are.same({ fast_line, "  ⎿  Backgrounded agent", "     Read(alpha.js)" }, item(log(), fast_line))
    assert.are.same({ slow_line, "  ⎿  Backgrounded agent" }, item(log(), slow_line))
    local j = index_of(events, function(ev)
      return ev.type == "agent_end"
    end, i + 1)
    play(events, i + 1, j)
    assert.are.same({ fast_line, "  ⎿  Done (2 tool uses · 35.8k tokens · 5.1s)" }, item(log(), fast_line))
    assert.are.same({
      '⏺ Agent "Add FAST marker to alpha.js" finished',
      "  ⎿  The edit succeeded: `// FAST` is now the first line of alpha.js.",
    }, vim.list_slice(chat(), 7, 8))
    play(events, j + 1)
    assert.are.same({
      "❯ Mark the files",
      fast_line,
      "  ⎿  Done (2 tool uses · 35.8k tokens · 5.1s)",
      slow_line,
      "  ⎿  Done (3 tool uses · 36.0k tokens · 14.4s)",
    }, log())
    local all = chat()
    assert.are.same('⏺ Agent "Add SLOW marker to beta.js" finished', all[#all - 3])
    assert.are.same("  ⎿  2 tool calls", all[3], "the run's count line stays as it was")
  end)

  it("counts a background agent that fails after its run ended on that run's count line", function()
    transcript.user("Look around")
    local id = call("Agent", { description = "Look", subagent_type = "Explore", run_in_background = true })
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "late1",
      tool_use_id = id,
      description = "Look",
      subagent_type = "Explore",
      depth = 1,
      background = true,
    })
    result(id, false, "Async agent launched successfully.", { result = { status = "async_launched" } })
    transcript.text_delta("It runs.")
    transcript.text_stop()
    turn_end()
    sidecar.dispatch({ type = "agent_end", agent_id = "late1", status = "failed", summary = "No access." })
    -- The end starts a turn, whose calls answer it.
    sidecar.dispatch({ type = "turn_start" })
    result(call("Bash", { command = "ls" }), false)
    turn_end()
    assert.are.same({
      "❯ Look around",
      "",
      "  ⎿  1 tool call · 1 failed",
      "",
      "⏺ It runs.",
      "",
      '⏺ Agent "Look" failed',
      "  ⎿  No access.",
      "",
      "  ⎿  1 tool call",
    }, chat())
    assert.are.same({
      "❯ Look around",
      "⏺ Explore(Look)",
      "  ⎿  Failed",
      "",
      '⏺ Agent "Look" failed',
      "⏺ Bash(ls)",
      "  ⎿  ok",
    }, log())
    assert.are.same({ "AnvimResult" }, groups(transcript.log_buf(), '⏺ Agent "Look" failed'))
  end)

  it("keeps the prompt as the head of calls after an agent's end that came while Claude worked", function()
    transcript.user("Keep going")
    local id = call("Agent", { description = "Side", subagent_type = "Explore", run_in_background = true })
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "mid1",
      tool_use_id = id,
      description = "Side",
      subagent_type = "Explore",
      depth = 1,
      background = true,
    })
    result(id, false, "Async agent launched successfully.", { result = { status = "async_launched" } })
    sidecar.dispatch({ type = "turn_start" })
    sidecar.dispatch({ type = "agent_end", agent_id = "mid1", status = "completed", summary = "Done." })
    result(call("Bash", { command = "ls" }), false)
    turn_end()
    assert.are.same({ "", "❯ Keep going", "⏺ Bash(ls)", "  ⎿  ok" }, vim.list_slice(log(), 4))
  end)

  it("marks the focused agent's line in the main log", function()
    call("Agent", { description = "Mark m1", subagent_type = "Explore" })
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "m1",
      tool_use_id = "log" .. next_id,
      description = "Mark m1",
      depth = 1,
    })
    follow.focus_slot(1)
    local ns = api.nvim_get_namespaces()["anvim.transcript.focus"]
    local marks = api.nvim_buf_get_extmarks(transcript.log_buf(), ns, 0, -1, { details = true })
    assert.are.same(1, #marks)
    assert.are.same("⏺ Explore(Mark m1)", log()[marks[1][2] + 1])
    assert.are.same({ { "◉ focused", "AnvimAgent1" } }, marks[1][4].virt_text)
    assert.are.same({}, api.nvim_buf_get_extmarks(transcript.buf(), ns, 0, -1, {}))
    assert.are.same("AnvimAgent1", groups(transcript.log_buf(), "⏺ Explore(Mark m1)")[1])
  end)

  it("keeps the todo list in the chat, where TodoWrite and the Task tools count for nothing", function()
    transcript.user("Do three steps")
    play(helpers.events("tasks-session"))
    local all = chat()
    assert.are.same({
      "❯ Do three steps",
      "",
      "  ⎿  5 tool calls",
      "",
      "⏺ Todos · 3 of 3 done",
      "  ⎿  ☒ Count lines of notes.lua with wc",
      "     ☒ List .lua files with Explore agent",
      "     ☒ Explain what util.lua does",
      "",
    }, vim.list_slice(all, 1, 9))
    assert(all[10]:find("^⏺ I tracked the three steps as tasks"), all[10])
    assert.are.same({
      "❯ Do three steps",
      "⏺ ToolSearch(select:TaskCreate,TaskUpdate)",
      "  ⎿  Done",
      "⏺ Bash(wc -l notes.lua)",
      "  ⎿  16 notes.lua",
      "⏺ Explore(List lua files in project)",
      "  ⎿  Done (1 tool use · 25.8k tokens · 3.9s)",
      "⏺ Read(util.lua)",
      "  ⎿  Read 8 lines",
      "⏺ show_user(util.lua#L3-5)",
      "  ⎿  The trim function that util.lua exports.",
    }, log())
    -- <leader>cy runs this.
    local notify = vim.notify
    vim.notify = function() end
    sessions.yank("a")
    vim.notify = notify
    assert(vim.fn.getreg("a"):find("^I tracked the three steps as tasks"), vim.fn.getreg("a"))
  end)

  it("shows a permission request in the chat, and its outcome on the tool's line in the main log", function()
    local guard, pause = permission.guard_ms, input.esc_pause_ms
    restore = function()
      permission.guard_ms, input.esc_pause_ms = guard, pause
    end
    permission.guard_ms, input.esc_pause_ms = 0, 0
    api.nvim_set_current_win(layout.wins.input)
    vim.cmd.stopinsert()
    local function keys(str)
      api.nvim_feedkeys(api.nvim_replace_termcodes(str, true, false, true), "mx", false)
    end
    local file = helpers.tmp .. "/matchparen.lua"
    local fixture = helpers.root .. "/tests/fixtures/permission-session.jsonl"
    transcript.user("Add a comment")
    helpers.capture_sends(function(sent)
      for _, frame in ipairs(vim.fn.readfile(fixture)) do
        frame = frame:gsub("/ANVIM_FIXTURE", helpers.tmp)
        local ev = vim.json.decode(frame:match("^%d+ (.*)$"), { luanil = { object = true, array = true } })
        if ev.type:match("^tool_") or ev.type:match("^text_") or ev.type:match("^permission_") then
          sidecar.dispatch(ev)
        elseif ev.type == "await_preview" then
          sidecar.dispatch(ev)
          assert(
            vim.wait(3000, function()
              return vim.tbl_contains(sent, function(msg)
                return msg.type == "preview_done" and msg.req == ev.req
              end, { predicate = true })
            end),
            "preview did not catch up"
          )
        end
        if ev.type == "permission_request" then
          local all = chat()
          assert.are.same("  Do you want to make this edit to matchparen.lua?", all[#all - 3])
          assert.are.same("  ⎿  3 tool calls", all[3])
          keys("1")
        end
      end
    end)
    assert.are.same("local api = vim.api", buf_lines(vim.fn.bufnr(file))[1], "the buffer shows the file on disk")
    assert.are.same({ "⏺ Edit(matchparen.lua)", "  ⎿  Added 1 line, removed 0 lines" }, vim.list_slice(log(), 6, 7))
    assert.are.same("  ⎿  3 tool calls", chat()[3], "the block went, and the count line stays")

    helpers.capture_sends(function()
      local id = call("Bash", { command = "make" })
      sidecar.dispatch({
        type = "permission_request",
        req = 951,
        tool_use_id = id,
        tool = "Bash",
        input = { command = "make" },
      })
      assert.are.same("    2. No, and tell Claude what to do differently (esc twice)", chat()[#chat()])
      keys("2Use make test<CR>")
      result(id, true, "The user doesn't want to proceed with this tool use.")
    end)
    assert.are.same({ "⏺ Bash(make)", "  ⎿  Rejected: Use make test" }, vim.list_slice(log(), #log() - 1))
    -- Claude's text after the edit ended the first run.
    local all = chat()
    assert.are.same({ "", "  ⎿  1 tool call · 1 failed" }, vim.list_slice(all, #all - 1))
  end)

  it("draws a resumed session's tool calls into the main log, with the times it saved", function()
    local saved = { state.session_id, state.turns }
    restore = function()
      state.session_id, state.turns = saved[1], saved[2]
    end
    local past = start_time - 86400
    sessions.history({
      session_id = "tool-log",
      events = {
        { type = "user", text = "Old prompt", time = past },
        { type = "tool_use", id = "old1", name = "Bash", input = { command = "ls" }, time = past + 1 },
        { type = "tool_result", id = "old1", is_error = false, text = "a.lua" },
        { type = "tool_use", id = "old2", name = "Bash", input = { command = "pwd" }, time = past + 2 },
        { type = "tool_result", id = "old2", is_error = false, text = "/x" },
        { type = "text_start", time = past + 3 },
        { type = "text_delta", text = "Old reply." },
        { type = "text_stop" },
        { type = "user", text = "Next prompt", time = past + 4 },
        { type = "tool_use", id = "old3", name = "Bash", input = { command = "sleep 9" }, time = past + 5 },
        { type = "agent_end", status = "failed", description = "bg", summary = "No access.", time = past + 6 },
        { type = "tool_use", id = "old4", name = "Bash", input = { command = "cat log" }, time = past + 7 },
        { type = "tool_result", id = "old4", is_error = false, text = "x" },
      },
    })
    assert.are.same({
      "❯ Old prompt @09:05:07",
      "",
      "  ⎿  2 tool calls @09:05:08",
      "",
      "⏺ Old reply. @09:05:10",
      "",
      "❯ Next prompt @09:05:11",
      "",
      "  ⎿  1 tool call · 1 failed @09:05:12",
      "",
      '⏺ Agent "bg" failed @09:05:13',
      "  ⎿  No access.",
      "",
      "  ⎿  1 tool call @09:05:14",
    }, stamped(transcript.buf()))
    assert.are.same({
      "❯ Old prompt",
      "⏺ Bash(ls) @09:05:08",
      "  ⎿  a.lua",
      "⏺ Bash(pwd) @09:05:09",
      "  ⎿  /x",
      "",
      "❯ Next prompt",
      "⏺ Bash(sleep 9) @09:05:12",
      "  ⎿  Interrupted",
      "",
      '⏺ Agent "bg" failed',
      "⏺ Bash(cat log) @09:05:14",
      "  ⎿  x",
    }, stamped(transcript.log_buf()))
  end)

  it("counts a tool call that comes first at the chat's top, and gives it no head line", function()
    result(call("Bash", { command = "a" }), false)
    assert.are.same({ "  ⎿  1 tool call @09:05:07" }, stamped(transcript.buf()))
    assert.are.same({ "⏺ Bash(a) @09:05:07", "  ⎿  ok" }, stamped(transcript.log_buf()))
    transcript.user("Next")
    result(call("Bash", { command = "b" }), false)
    assert.are.same({ "  ⎿  1 tool call", "", "❯ Next", "", "  ⎿  1 tool call" }, chat())
    assert.are.same({ "⏺ Bash(a)", "  ⎿  ok", "", "❯ Next", "⏺ Bash(b)", "  ⎿  ok" }, log())
  end)

  it("starts a new run in the chat buffer that layout repair makes after a wipe", function()
    transcript.user("Go")
    result(call("Bash", { command = "a" }), false)
    local old = transcript.buf()
    vim.cmd("bwipeout! " .. old)
    assert(
      vim.wait(1000, function()
        local win = layout.wins.transcript
        return win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) ~= old
      end, 10),
      "layout repair made no new transcript"
    )
    result(call("Bash", { command = "b" }), false)
    assert.are.same({ "  ⎿  1 tool call" }, chat())
    assert.are.same({ "❯ Go", "⏺ Bash(a)", "  ⎿  ok", "", "❯ Go", "⏺ Bash(b)", "  ⎿  ok" }, log())
  end)

  it("leaves the calls drawn before a switch where they are, and later calls follow the flag", function()
    transcript.user("Go")
    result(call("Bash", { command = "a" }), false)
    transcript.tools_apart = false
    result(call("Bash", { command = "b" }), false)
    transcript.tools_apart = true
    result(call("Bash", { command = "c" }), false)
    assert.are.same(
      { "❯ Go", "", "  ⎿  1 tool call", "", "⏺ Bash(b)", "  ⎿  ok", "", "  ⎿  1 tool call" },
      chat()
    )
    assert.are.same({ "❯ Go", "⏺ Bash(a)", "  ⎿  ok", "", "❯ Go", "⏺ Bash(c)", "  ⎿  ok" }, log())
  end)
end)
