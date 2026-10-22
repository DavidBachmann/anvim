---@module "luassert"

local agentlog = require("anvim.agentlog")
local agents = require("anvim.agents")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

local alpha, beta, gamma = "a462161d1283697a4", "ac8d35b341c2136a8", "a2ba251a78b20a0f4"

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  transcript.clear()
end

local function lines(id)
  local buf = agentlog.buf(id)
  return buf and helpers.buf_lines(buf) or error("no log for " .. id)
end

-- The groups of the marks on the first line that is `text`, as "col:group",
-- and the line's own group as "line:group".
local function groups(id, text)
  local buf = agentlog.buf(id)
  local ns = api.nvim_get_namespaces()["anvim.agentlog"]
  for row, line in ipairs(helpers.buf_lines(buf)) do
    if line == text then
      local out = {}
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
        local d = mark[4]
        if d.line_hl_group then
          out[#out + 1] = "line:" .. d.line_hl_group
        elseif d.hl_group then
          out[#out + 1] = ("%d:%s"):format(mark[3], d.hl_group)
        end
      end
      table.sort(out)
      return out
    end
  end
  error(("no line %q in:\n%s"):format(text, table.concat(helpers.buf_lines(buf), "\n")))
end

local function start(id, extra)
  sidecar.dispatch(vim.tbl_extend("force", {
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "general-purpose",
    depth = 1,
    background = false,
  }, extra or {}))
end

-- The main agent's Agent call, which carries the prompt.
local function call(id, prompt)
  sidecar.dispatch({
    type = "tool_use",
    id = "tu_" .. id,
    name = "Agent",
    input = { description = "Task " .. id, subagent_type = "general-purpose", prompt = prompt },
  })
end

local function use(id, tool_id, name, input)
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = name,
    input = input,
    parent_id = "tu_" .. id,
    agent_id = id,
  })
end

local function result(id, tool_id, extra)
  sidecar.dispatch(vim.tbl_extend("force", {
    type = "tool_result",
    id = tool_id,
    is_error = false,
    text = "ok",
    parent_id = "tu_" .. id,
    agent_id = id,
  }, extra or {}))
end

local function say(id, text)
  sidecar.dispatch({ type = "agent_text", agent_id = id, parent_id = "tu_" .. id, text = text })
end

local function finish(id, extra)
  sidecar.dispatch(vim.tbl_extend("force", { type = "agent_end", agent_id = id, status = "completed" }, extra or {}))
end

local function turn_end()
  sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
end

local function float(buf, enter)
  return api.nvim_open_win(buf, enter or false, { relative = "editor", row = 1, col = 1, width = 40, height = 5 })
end

-- Replays a fixture and records each handler that failed.
-- Runs fn and records each handler that failed, and each agent log that failed.
local function failures_of(fn)
  local failures, log = {}, sidecar.log
  sidecar.log = function(text)
    if text:find("^handler for") or text:find("^agent log of") then
      failures[#failures + 1] = text
    end
    log(text)
  end
  local ok, err = pcall(fn)
  sidecar.log = log
  assert(ok, err)
  return failures
end

-- Replays a fixture and records each handler that failed.
local function replay(name)
  return failures_of(function()
    for _, ev in ipairs(helpers.events(name)) do
      sidecar.dispatch(ev)
    end
  end)
end

describe("agent logs", function()
  local wins = {} ---@type integer[]

  after_each(function()
    for _, win in ipairs(wins) do
      pcall(api.nvim_win_close, win, true)
    end
    wins = {}
    require("anvim.permission").cancel_all()
    sidecar.dispatch({ type = "reset" })
    require("anvim.follow").forget()
  end)

  it("draws each agent's prompt, calls, results, text and end in order, and a SendMessage restart", function()
    fresh()
    local failures = replay("overview-session")
    assert.are.same({}, failures)
    local function body(id)
      local all = lines(id)
      assert(all[1]:find("^❯ Read%-only task%. Do not edit"), all[1])
      return vim.list_slice(all, vim.fn.index(all, "") + 2)
    end
    assert.are.same({
      "⏺ Bash(find . -name alpha.js 2>/dev/null; ls -la .)",
      "  ⎿  alpha.js ... +6 lines",
      "⏺ Read(alpha.js)",
      "  ⎿  Read 7 lines",
      "⏺ add",
      "✻ Done (2 tool uses · 37.3k tokens · 5.9s)",
    }, body(alpha))
    assert.are.same({
      "⏺ Read(gamma.js)",
      "  ⎿  Read 7 lines",
      "⏺ take",
      "✻ Done (1 tool use · 37.0k tokens · 4.4s)",
    }, body(gamma))
    -- SendMessage continued beta: the same buffer goes on after a rule.
    local beta_buf = agentlog.buf(beta)
    assert.are.same({
      "⏺ Bash(find . -name beta.js 2>/dev/null)",
      "  ⎿  beta.js",
      "⏺ Read(beta.js)",
      "  ⎿  Read 11 lines",
      "⏺ greet, shout",
      "✻ Done (2 tool uses · 37.1k tokens · 5.4s)",
      "",
      "─── SendMessage ───",
      "❯ How many lines does beta.js have? Reply with only the number. Do not edit any file.",
      "",
      "⏺ Bash(wc -l < beta.js)",
      "  ⎿  10",
      "⏺ 10",
      "✻ Done (1 tool use · 37.5k tokens · 3.9s)",
    }, body(beta))
    assert.are.equal(beta_buf, agentlog.buf(beta))

    -- The prompt's lines have the transcript's prompt colors.
    local first = lines(alpha)[1]
    assert.are.same({ "0:AnvimPrompt", "line:AnvimUser" }, groups(alpha, first))
    assert.are.same({ "line:AnvimUser" }, groups(alpha, lines(alpha)[2]))
    assert.are.same({ "0:AnvimToolOk", "4:AnvimToolName" }, groups(alpha, "⏺ Read(alpha.js)"))
    assert.are.same({ "0:AnvimResult" }, groups(alpha, "  ⎿  Read 7 lines"))
    assert.are.same({ "0:AnvimBullet" }, groups(alpha, "⏺ add"))
    assert.are.same(
      { "0:AnvimToolOk", "3:AnvimResult" },
      groups(alpha, "✻ Done (2 tool uses · 37.3k tokens · 5.9s)")
    )
    assert.are.same({ "0:AnvimRule" }, groups(beta, "─── SendMessage ───"))
    local buf = agentlog.buf(beta)
    assert.are.same({ "nofile", "hide", false }, { vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable })
    assert.are.same("anvim://agent/" .. beta, api.nvim_buf_get_name(buf))
  end)

  it("colors a call's bullet as its agent while it waits, and by its result after", function()
    fresh()
    start("w1")
    start("w2")
    use("w2", "r1", "Read", { file_path = helpers.tmp .. "/x.lua" })
    use("w2", "r2", "Bash", { command = "false" })
    assert.are.same({ "0:AnvimAgent2", "4:AnvimToolName" }, groups("w2", "⏺ Read(x.lua)"))
    result("w2", "r1", { result = { file = { numLines = 1 } } })
    result("w2", "r2", { is_error = true, text = "Exit code 1\nboom" })
    assert.are.same({
      "⏺ Read(x.lua)",
      "  ⎿  Read 1 line",
      "⏺ Bash(false)",
      "  ⎿  Exit code 1 ... +1 lines",
    }, lines("w2"))
    assert.are.same({ "0:AnvimToolOk", "4:AnvimToolName" }, groups("w2", "⏺ Read(x.lua)"))
    assert.are.same({ "0:AnvimToolError", "4:AnvimToolName" }, groups("w2", "⏺ Bash(false)"))
    assert.are.same({ "0:AnvimToolError" }, groups("w2", "  ⎿  Exit code 1 ... +1 lines"))
    -- Results go under their own calls, in any order. A waiting call takes the
    -- slot that its agent gets.
    start("w3")
    start("w4")
    start("w5")
    use("w5", "s1", "Read", { file_path = helpers.tmp .. "/a.lua" })
    use("w5", "s2", "Read", { file_path = helpers.tmp .. "/b.lua" })
    assert.are.same({ "0:Comment", "4:AnvimToolName" }, groups("w5", "⏺ Read(a.lua)"))
    finish("w1")
    assert.are.same({ "0:AnvimAgent1", "4:AnvimToolName" }, groups("w5", "⏺ Read(a.lua)"))
    result("w5", "s2", { result = { file = { numLines = 2 } } })
    result("w5", "s1", { result = { file = { numLines = 3 } } })
    assert.are.same({ "⏺ Read(a.lua)", "  ⎿  Read 3 lines", "⏺ Read(b.lua)", "  ⎿  Read 2 lines" }, lines("w5"))
  end)

  it("draws text under a bullet with its next lines indented, and skips blank text", function()
    fresh()
    start("t")
    say("t", "   ")
    say("t", "Found it.\n\nIn a.lua.")
    assert.are.same({ "⏺ Found it.", "  ", "  In a.lua." }, lines("t"))
    assert.are.same({ "0:AnvimBullet" }, groups("t", "⏺ Found it."))
    assert.are.same({}, groups("t", "  In a.lua."))
  end)

  it("puts the prompt on top when the Agent call comes after agent_start, and names a nested agent's parent", function()
    fresh()
    start("late")
    use("late", "l1", "Bash", { command = "ls" })
    call("late", "Find the lexer.\nReport the lines.")
    result("late", "l1", { text = "a.lua" })
    assert.are.same({
      "❯ Find the lexer.",
      "  Report the lines.",
      "",
      "⏺ Bash(ls)",
      "  ⎿  a.lua",
    }, lines("late"))
    -- A nested agent: its parent's call is a line of the parent's log.
    start("kid", { tool_use_id = "tu_kid", parent_agent_id = "late", depth = 2, subagent_type = "Explore" })
    use("late", "tu_kid", "Agent", { description = "Task kid", subagent_type = "Explore", prompt = "Look around." })
    assert.are.same({ "Started by Agent 1 (Task late)", "❯ Look around.", "" }, lines("kid"))
    assert.are.same("⏺ Explore(Task kid)", lines("late")[#lines("late")])
  end)

  it("puts a SendMessage's message after the rule when the call comes after agent_start", function()
    fresh()
    start("s", { background = true })
    call("s", "Count the files.")
    say("s", "3")
    finish("s", { summary = "3" })
    start("s", { tool_use_id = "tu_send", background = true })
    use("s", "x1", "Bash", { command = "ls" })
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_send",
      name = "SendMessage",
      input = { to = "s", message = "And the dirs?" },
    })
    assert.are.same({
      "❯ Count the files.",
      "",
      "⏺ 3",
      "✻ Done",
      "",
      "─── SendMessage ───",
      "❯ And the dirs?",
      "",
      "⏺ Bash(ls)",
    }, lines("s"))
  end)

  it("shows the summary as the last text of a log without text, and how an agent ended", function()
    fresh()
    start("e1")
    use("e1", "e1a", "Read", { file_path = helpers.tmp .. "/a.lua" })
    result("e1", "e1a", { result = { file = { numLines = 4 } } })
    finish("e1", { summary = "Found it.\nIn a.lua.", tool_uses = 1, tokens = 1200, duration_ms = 2500 })
    assert.are.same({
      "⏺ Read(a.lua)",
      "  ⎿  Read 4 lines",
      "⏺ Found it.",
      "  In a.lua.",
      "✻ Done (1 tool use · 1.2k tokens · 2.5s)",
    }, lines("e1"))
    start("e2")
    finish("e2", { status = "failed" })
    assert.are.same({ "✻ Failed" }, lines("e2"))
    assert.are.same({ "0:AnvimToolError", "3:AnvimResult" }, groups("e2", "✻ Failed"))
    -- A turn's end stops a foreground agent. Its waiting call was cut off.
    start("e3")
    use("e3", "e3a", "Bash", { command = "sleep 9" })
    turn_end()
    assert.are.same({ "⏺ Bash(sleep 9)", "  ⎿  Interrupted", "✻ Stopped" }, lines("e3"))
    assert.are.same({ "0:AnvimToolError", "4:AnvimToolName" }, groups("e3", "⏺ Bash(sleep 9)"))
    -- Its late end tells how it really ended.
    finish("e3", { summary = "Slept.", tool_uses = 1 })
    assert.are.same({ "⏺ Bash(sleep 9)", "  ⎿  Interrupted", "⏺ Slept.", "✻ Done (1 tool use)" }, lines("e3"))
  end)

  it("drops the oldest 500 lines beyond 3000, and calls whose lines stay keep their results", function()
    fresh()
    start("big")
    call("big", "Go.")
    use("big", "b1", "Read", { file_path = helpers.tmp .. "/a.lua" })
    local many = {}
    for i = 1, 2997 do
      many[i] = "line " .. i
    end
    say("big", table.concat(many, "\n"))
    assert.are.same(3000, #lines("big"))
    assert.are.same("❯ Go.", lines("big")[1])
    use("big", "b2", "Read", { file_path = helpers.tmp .. "/b.lua" })
    local all = lines("big")
    assert.are.same(2502, #all)
    assert.are.same({ "⋯ earlier lines dropped", "  line 498" }, vim.list_slice(all, 1, 2))
    assert.are.same({ "0:AnvimResult" }, groups("big", "⋯ earlier lines dropped"))
    -- b1's line went, so its result draws nothing.
    result("big", "b1", { result = { file = { numLines = 1 } } })
    result("big", "b2", { result = { file = { numLines = 2 } } })
    all = lines("big")
    assert.are.same({ "  line 2997", "⏺ Read(b.lua)", "  ⎿  Read 2 lines" }, vim.list_slice(all, #all - 2))
    assert.are.same({ "0:AnvimToolOk", "4:AnvimToolName" }, groups("big", "⏺ Read(b.lua)"))
    -- A second drop keeps one first line that says so.
    say("big", table.concat(many, "\n", 1, 600))
    all = lines("big")
    assert(#all <= 3000, #all)
    assert.are.same("⋯ earlier lines dropped", all[1])
    assert.are_not.same("⋯ earlier lines dropped", all[2])
  end)

  it("keeps a past agent's log, so a SendMessage restart after the next prompt goes on in it", function()
    fresh()
    start("p")
    call("p", "Read a.lua.")
    use("p", "p1", "Read", { file_path = helpers.tmp .. "/a.lua" })
    result("p", "p1", { result = { file = { numLines = 2 } } })
    finish("p", { summary = "Done." })
    local buf = agentlog.buf("p")
    agents.prompt_sent()
    assert.are.same({}, agents.ended(), "its tab goes")
    assert.are.equal(buf, agentlog.buf("p"), "its log stays")
    sidecar.dispatch({ type = "tool_use", id = "tu_p2", name = "SendMessage", input = { to = "p", message = "Again." } })
    start("p", { tool_use_id = "tu_p2", background = true })
    assert.are.equal(buf, agentlog.buf("p"))
    assert.are.same({
      "❯ Read a.lua.",
      "",
      "⏺ Read(a.lua)",
      "  ⎿  Read 2 lines",
      "⏺ Done.",
      "✻ Done",
      "",
      "─── SendMessage ───",
      "❯ Again.",
      "",
    }, lines("p"))
  end)

  it(
    "keeps at most 16 logs: the oldest end goes first, past or not, but never a running agent's or a shown one",
    function()
      fresh()
      start("run")
      local bufs = {}
      for i = 1, 20 do
        start("old" .. i)
        bufs[i] = agentlog.buf("old" .. i)
        finish("old" .. i)
      end
      -- 21 logs: the five oldest ends go, although 9 to 12 have no tab either.
      assert.is_not_nil(agentlog.buf("run"))
      for i = 1, 20 do
        assert.are.same(i > 5, agentlog.buf("old" .. i) ~= nil, "old" .. i)
        assert.are.same(i > 5, api.nvim_buf_is_valid(bufs[i]), "old" .. i)
      end
      agents.prompt_sent()
      assert.is_not_nil(agentlog.buf("old6"), "past logs stay while they fit")
      wins = { float(agentlog.buf("old7")) }
      start("new1")
      start("new2")
      assert.is_nil(agentlog.buf("old6"), "the oldest past log goes first")
      assert.is_not_nil(agentlog.buf("old7"), "a shown log stays")
      assert.is_nil(agentlog.buf("old8"))
      assert.is_not_nil(agentlog.buf("old9"))
      assert.is_not_nil(agentlog.buf("run"))
    end
  )

  it("starts a log of the first prompt, the rule and the message when the cap took the old one", function()
    fresh()
    local max = agentlog.max_logs
    agentlog.max_logs = 1
    local ok, err = pcall(function()
      start("q")
      call("q", "Read a.lua.")
      finish("q")
      agents.prompt_sent()
      start("r")
      assert.is_nil(agentlog.buf("q"))
    end)
    agentlog.max_logs = max
    assert(ok, err)
    start("q", { tool_use_id = "tu_q2", background = true })
    sidecar.dispatch({ type = "tool_use", id = "tu_q2", name = "SendMessage", input = { to = "q", message = "Again." } })
    assert.are.same({ "❯ Read a.lua.", "", "─── SendMessage ───", "❯ Again.", "" }, lines("q"))
  end)

  it("adds a SendMessage to an agent that still runs to its log", function()
    fresh()
    start("m", { background = true })
    call("m", "Read a.lua.")
    use("m", "m1", "Bash", { command = "ls" })
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_send_m",
      name = "SendMessage",
      input = { to = "m", message = "Also read b.lua." },
    })
    result("m", "m1", { text = "a.lua" })
    assert.are.same({
      "❯ Read a.lua.",
      "",
      "⏺ Bash(ls)",
      "  ⎿  a.lua",
      "",
      "─── SendMessage ───",
      "❯ Also read b.lua.",
      "",
    }, lines("m"))
    -- A message to an agent that anvim does not know adds nothing.
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_send_x",
      name = "SendMessage",
      input = { to = "x", message = "Hi." },
    })
    assert.are.same(8, #lines("m"))
  end)

  it(
    "drops every log on /clear, a resumed session and an exit, but a shown one only once no window shows it",
    function()
      fresh()
      for _, ev in ipairs({
        { type = "reset" },
        { type = "history", session_id = "s-logs", events = {} },
        { type = "exit", code = 0, restart = true },
      }) do
        start("d1")
        start("d2", { background = true })
        local hidden, shown = agentlog.buf("d1"), agentlog.buf("d2")
        local win = float(shown)
        sidecar.dispatch(ev)
        assert.is_nil(agentlog.buf("d1"), ev.type)
        assert.is_nil(agentlog.buf("d2"), ev.type)
        assert.is_false(api.nvim_buf_is_valid(hidden), ev.type)
        assert.is_true(api.nvim_buf_is_valid(shown), ev.type)
        vim.wait(20)
        assert.is_true(api.nvim_buf_is_valid(shown), ev.type)
        -- The window shows another buffer for a while, then the log again.
        api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
        api.nvim_win_set_buf(win, shown)
        vim.wait(20)
        assert.is_true(api.nvim_buf_is_valid(shown), ev.type)
        api.nvim_win_close(win, true)
        assert(
          vim.wait(1000, function()
            return not api.nvim_buf_is_valid(shown)
          end),
          ev.type
        )
        -- A new log of the same agent is a new buffer.
        start("d2")
        assert.is_not_nil(agentlog.buf("d2"), ev.type)
        sidecar.dispatch({ type = "reset" })
      end
      require("anvim.state").process = "ready"
    end
  )

  for _, cmd in ipairs({ "bwipeout!", "bdelete!" }) do
    it("starts a new log at the agent's next event after " .. cmd .. " of its log", function()
      fresh()
      start("k")
      call("k", "Look.")
      say("k", "First.")
      local old = agentlog.buf("k")
      vim.cmd(cmd .. " " .. old)
      assert.is_nil(agentlog.buf("k"))
      local failures = failures_of(function()
        use("k", "k1", "Bash", { command = "ls" })
        result("k", "k1", { text = "a.lua" })
        say("k", "Second.")
        start("other")
        finish("k", { summary = "Second." })
      end)
      assert.are.same({}, failures)
      assert.are.same({ "❯ Look.", "", "⏺ Bash(ls)", "  ⎿  a.lua", "⏺ Second.", "✻ Done" }, lines("k"))
      assert.are_not.equal(old, agentlog.buf("k"))
      assert.are.same("anvim://agent/k", api.nvim_buf_get_name(agentlog.buf("k")))
      vim.wait(20)
      assert.is_false(api.nvim_buf_is_valid(old))
    end)
  end

  it("draws a late text and a late end after a stop at the end of the log", function()
    fresh()
    start("z")
    use("z", "z1", "Bash", { command = "sleep 9" })
    turn_end()
    assert.are.same("✻ Stopped", lines("z")[#lines("z")])
    say("z", "Late words.")
    finish("z", { tool_uses = 2 })
    assert.are.same(
      { "⏺ Bash(sleep 9)", "  ⎿  Interrupted", "⏺ Late words.", "✻ Done (2 tool uses)" },
      lines("z")
    )
  end)

  it("shows a restart's summary when only the first run had text", function()
    fresh()
    start("r", { background = true })
    call("r", "Count.")
    say("r", "3")
    finish("r", { summary = "3" })
    sidecar.dispatch({ type = "tool_use", id = "tu_r2", name = "SendMessage", input = { to = "r", message = "Again." } })
    start("r", { tool_use_id = "tu_r2", background = true })
    finish("r", { summary = "4" })
    local all = lines("r")
    assert.are.same({ "⏺ 4", "✻ Done" }, vim.list_slice(all, #all - 1))
  end)

  it("leaves out empty names and messages, and the todo tools", function()
    fresh()
    start("par", { description = "" })
    start("sub", { parent_agent_id = "par", depth = 2 })
    assert.are.same("Started by Agent 1", lines("sub")[1])
    use("sub", "td", "TodoWrite", { todos = { { content = "x", status = "pending", activeForm = "X" } } })
    use("sub", "tc", "TaskCreate", { subject = "x" })
    result("sub", "td")
    assert.are.same({ "Started by Agent 1" }, lines("sub"))
    -- An empty message to a running agent, and to an agent that SendMessage continues.
    sidecar.dispatch({ type = "tool_use", id = "tu_e1", name = "SendMessage", input = { to = "sub", message = " " } })
    assert.are.same({ "Started by Agent 1" }, lines("sub"))
    finish("sub", { summary = "ok" })
    sidecar.dispatch({ type = "tool_use", id = "tu_e2", name = "SendMessage", input = { to = "sub", message = "" } })
    start("sub", { tool_use_id = "tu_e2", parent_agent_id = "par", depth = 2 })
    assert.are.same({ "Started by Agent 1", "⏺ ok", "✻ Done" }, lines("sub"))
  end)

  it("brings windows at the end along with new lines, but not a scrolled one or the current one", function()
    fresh()
    start("v")
    for i = 1, 20 do
      say("v", "text " .. i)
    end
    local buf = agentlog.buf("v")
    local at_end, scrolled, current = float(buf), float(buf), float(buf)
    wins = { at_end, scrolled, current }
    api.nvim_win_set_cursor(at_end, { 20, 0 })
    api.nvim_win_set_cursor(scrolled, { 1, 0 })
    api.nvim_win_set_cursor(current, { 20, 0 })
    api.nvim_win_call(current, function()
      say("v", "text 21")
      use("v", "v1", "Bash", { command = "ls" })
      result("v", "v1", { text = "a.lua" })
    end)
    assert.are.same(23, api.nvim_buf_line_count(buf))
    assert.are.same(23, api.nvim_win_get_cursor(at_end)[1])
    assert.are.same(1, api.nvim_win_get_cursor(scrolled)[1])
    assert.are.same(20, api.nvim_win_get_cursor(current)[1])
  end)

  it("replays the agents and background fixtures without a handler error", function()
    fresh()
    for _, name in ipairs({ "alpha", "beta", "gamma" }) do
      vim.fn.writefile(
        { ("export function %s() {"):format(name), ('  return "%s";'):format(name), "}" },
        helpers.tmp .. "/" .. name .. ".js"
      )
    end
    assert.are.same({}, replay("agents-session"))
    -- This recording's ends have no totals.
    local log = lines("adc8e994a94d15f64")
    assert(log[1]:find("^❯ "), log[1])
    assert.are.same("✻ Done", log[#log])
    sidecar.dispatch({ type = "reset" })
    assert.are.same({}, replay("background-session"))
    -- This recording has no text blocks, so the summary is the last text.
    log = lines("ab4185ae777e86454")
    assert.are.same({
      "⏺ The edit succeeded: `// FAST` is now the first line of alpha.js.",
      "✻ Done (2 tool uses · 35.8k tokens · 5.1s)",
    }, vim.list_slice(log, #log - 1))
  end)
end)
