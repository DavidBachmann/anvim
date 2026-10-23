---@module "luassert"

local agentlog = require("anvim.agentlog")
local agents = require("anvim.agents")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

local alpha, beta, gamma = "a462161d1283697a4", "ac8d35b341c2136a8", "a2ba251a78b20a0f4"

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
    helpers.fresh()
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

  it("draws text under a bullet with its next lines indented, and skips blank text", function()
    helpers.fresh()
    start("t")
    say("t", "   ")
    say("t", "Found it.\n\nIn a.lua.")
    assert.are.same({ "⏺ Found it.", "  ", "  In a.lua." }, lines("t"))
    assert.are.same({ "0:AnvimBullet" }, groups("t", "⏺ Found it."))
    assert.are.same({}, groups("t", "  In a.lua."))
  end)

  it("drops the oldest 500 lines beyond 3000, and calls whose lines stay keep their results", function()
    helpers.fresh()
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

  describe("times", function()
    local first = os.time({ year = 2026, month = 10, day = 22, hour = 9, min = 5, sec = 7 })
    local now = first
    local max_lines, drop_lines = agentlog.max_lines, agentlog.drop_lines

    before_each(function()
      now = first
      transcript.clock = function()
        return now
      end
    end)

    after_each(function()
      transcript.clock = os.time
      agentlog.max_lines, agentlog.drop_lines = max_lines, drop_lines
    end)
  end)

  it(
    "keeps at most 16 logs: the oldest end goes first, past or not, but never a running agent's or a shown one",
    function()
      helpers.fresh()
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

  it("replays the agents and background fixtures without a handler error", function()
    helpers.fresh()
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
