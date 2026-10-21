---@module "luassert"

local agents = require("anvim.agents")
local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

-- The path and line of an agent's place, as follow mode keeps it.
local function place_of(id)
  local p = require("anvim.follow").places()[id]
  return p and { p.path, p.line }
end

-- The events of a recorded turn, with the paths in the temp project. The
-- events that need a real sidecar stay out.
local function recording()
  local skip = { commands = true, init = true, status = true, context = true, await_preview = true }
  local events = {}
  for _, frame in ipairs(vim.fn.readfile(helpers.root .. "/tests/fixtures/agents-session.jsonl")) do
    local json = frame:match("^%d+ (.*)$"):gsub("/ANVIM_FIXTURE", helpers.tmp)
    local ev = vim.json.decode(json, { luanil = { object = true, array = true } })
    if not skip[ev.type] then
      events[#events + 1] = ev
    end
  end
  return events
end

-- The bullet's group on the line that matches pattern.
local function bullet(pattern)
  local buf = transcript.buf()
  local ns = api.nvim_get_namespaces()["anvim.transcript"]
  for row, line in ipairs(helpers.buf_lines(buf)) do
    if line:find(pattern) then
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, 0 }, { details = true })) do
        if mark[4].end_col == #"⏺" then
          return mark[4].hl_group
        end
      end
    end
  end
  error("no line matches " .. pattern)
end

-- The groups of the footer's dots, and the footer's text: as drawn under the
-- prompt, or at a width.
local function footer(width)
  local chunks
  if width then
    chunks = input.footer(width)
  else
    local ns = api.nvim_get_namespaces()["anvim.input"]
    local mark = api.nvim_buf_get_extmarks(input.buf(), ns, 0, -1, { details = true })[1]
    chunks = mark[4].virt_lines[1]
  end
  local dots, text = {}, {}
  for _, chunk in ipairs(chunks) do
    if chunk[1] == "⏺" then
      dots[#dots + 1] = chunk[2]
    end
    text[#text + 1] = chunk[1]
  end
  return dots, table.concat(text)
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

local function finish(id)
  sidecar.dispatch({ type = "agent_end", agent_id = id, status = "completed", summary = "done" })
end

local function slots()
  return vim.tbl_map(function(agent)
    return { agent.id, agent.slot or false }
  end, agents.running())
end

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  transcript.clear()
end

-- The tree's marks on each of the replay's files, as "slot:kind".
local function tree_marks()
  local ret = {}
  for _, name in ipairs({ "alpha", "beta", "gamma" }) do
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

describe("agents", function()
  local column_width ---@type integer?
  -- State that a case changes, to restore even when it fails.
  local restore ---@type fun()?

  -- Running agents would show in other specs' footers.
  after_each(function()
    agents.clear()
    if column_width then
      api.nvim_win_set_width(require("anvim.layout").wins.input, column_width)
      column_width = nil
    end
    local fn = restore
    restore = nil
    if fn then
      fn()
    end
  end)

  it("replays three agents in parallel: slots, places, files, bullets and the footer", function()
    fresh()
    -- Room for the dots in the footer under the prompt.
    local win = require("anvim.layout").wins.input
    column_width = api.nvim_win_get_width(win)
    api.nvim_win_set_width(win, 60)
    for _, name in ipairs({ "alpha", "beta", "gamma" }) do
      vim.fn.writefile(
        { ("export function %s() {"):format(name), ('  return "%s";'):format(name), "}" },
        helpers.tmp .. "/" .. name .. ".js"
      )
    end
    local events = recording()
    local i = 1
    -- Up to the first agent's end, all three run.
    while not (events[i].type == "agent_end") do
      sidecar.dispatch(events[i])
      i = i + 1
    end
    local alpha, beta, gamma = "adc8e994a94d15f64", "aaa5f2a64f18ba7a5", "abc3a486dba70f916"
    assert.are.same({ { alpha, 1 }, { beta, 2 }, { gamma, 3 } }, slots())
    local a = agents.get(alpha)
    assert.are.equal(a, agents.by_tool("toolu_01G1zf59XnZb8KKDJharP7iV"))
    assert.are.same("Edit alpha.js header", a.description)
    assert.are.same("general-purpose", a.type)
    assert.are.same({ helpers.tmp .. "/alpha.js", 1 }, place_of(a.id))
    assert.are.same({ helpers.tmp .. "/alpha.js" }, a.files)
    assert.are.same(2, a.tools)
    assert.are.same("Editing alpha.js", a.activity)
    -- beta's edit is still on its way.
    local b = agents.get(beta)
    assert.are.same({ helpers.tmp .. "/beta.js", 1 }, place_of(b.id))
    assert.are.same({}, b.files)
    assert.are.same({ alpha = "1:place", beta = "2:place", gamma = "3:place" }, tree_marks())

    assert.are.same("AnvimAgent1", bullet("^⏺ Agent%(Edit alpha%.js header%)"))
    assert.are.same("AnvimAgent2", bullet("^⏺ Agent%(Edit beta%.js header%)"))
    assert.are.same("AnvimAgent3", bullet("^⏺ Agent%(Edit gamma%.js header%)"))
    assert.are.same({ "AnvimAgent1", "AnvimAgent2", "AnvimAgent3" }, footer())
    local _, text = footer(120)
    assert(text:find("  ⏺⏺⏺ 3 agents", 1, true), text)

    sidecar.dispatch(events[i])
    assert.are.same({ { beta, 2 }, { gamma, 3 } }, slots(), "beta and gamma keep their slots")
    assert.are.same({ alpha = "", beta = "2:place", gamma = "3:place" }, tree_marks())
    assert.are.same("AnvimToolPending", bullet("^⏺ Agent%(Edit alpha%.js header%)"))
    assert.are.same({ "AnvimAgent2", "AnvimAgent3" }, footer())
    for j = i + 1, #events do
      sidecar.dispatch(events[j])
    end
    assert.are.same({}, slots())
    assert.are.same({ alpha = "", beta = "", gamma = "" }, tree_marks())
    assert.are.same("completed", agents.get(gamma).status)
    assert(agents.get(gamma).summary:find("gamma.js", 1, true), agents.get(gamma).summary)
    for _, name in ipairs({ "alpha", "beta", "gamma" }) do
      assert.are.same("AnvimToolOk", bullet(("^⏺ Agent%%(Edit %s%%.js header%%)"):format(name)))
    end
    local dots
    dots, text = footer()
    assert.are.same({}, dots)
    assert(not text:find("agent", 1, true), text)
  end)

  it("gives the lowest free slot, and a fifth agent at once waits for one", function()
    fresh()
    for _, id in ipairs({ "a1", "a2", "a3", "a4", "a5" }) do
      start(id)
    end
    assert.are.same({ { "a1", 1 }, { "a2", 2 }, { "a3", 3 }, { "a4", 4 }, { "a5", false } }, slots())
    assert.are.same("Comment", agents.group(agents.get("a5").slot))
    local dots, text = footer(120)
    assert.are.same(4, #dots)
    assert(text:find("⏺⏺⏺⏺ 5 agents", 1, true), text)
    finish("a2")
    assert.are.same(2, agents.get("a5").slot, "the waiting agent gets the freed slot")
    finish("a1")
    finish("a5")
    start("a6")
    assert.are.same(
      { { "a6", 1 }, { "a5", false } },
      { { "a6", agents.get("a6").slot }, { "a5", agents.get("a5").slot or false } }
    )
    start("a7")
    assert.are.same(2, agents.get("a7").slot, "the lowest free slot")
    assert.are.same("AnvimAgent4", agents.group(4))
    assert.are.same("AnvimClaude", agents.group(0))
  end)

  it("starts an agent that SendMessage continues again, with a slot and a run of its own", function()
    fresh()
    local events = 0
    local id = api.nvim_create_autocmd("User", {
      pattern = "AnvimAgents",
      callback = function()
        events = events + 1
      end,
    })
    start("b1")
    local agent = agents.get("b1")
    local file = helpers.tmp .. "/continued.lua"
    vim.fn.writefile({ "return 1" }, file)
    local edit = { file_path = file, old_string = "return 1", new_string = "return 2" }
    sidecar.dispatch({ type = "tool_use", id = "e1", name = "Edit", input = edit, parent_id = "tu_b1", agent_id = "b1" })
    sidecar.dispatch({
      type = "tool_result",
      id = "e1",
      is_error = false,
      text = "ok",
      parent_id = "tu_b1",
      agent_id = "b1",
    })
    finish("b1")
    assert.are.same({}, slots())
    events = 0
    start("b1", { tool_use_id = "tu_b1_again", description = "", background = true })
    api.nvim_del_autocmd(id)
    assert.are.same(1, events, "the restart fires AnvimAgents")
    assert.are.same({ { "b1", 1 } }, slots())
    assert.are.equal(agent, agents.by_tool("tu_b1_again"), "the same agent")
    assert.are.equal(agent, agents.by_tool("tu_b1"))
    assert.are.same(
      { "running", true, {}, "Task b1" },
      { agent.status, agent.background, agent.files, agent.description }
    )
  end)

  it("colors the Agent bullet when its tool call comes before or after agent_start", function()
    fresh()
    sidecar.dispatch({ type = "turn_start" })
    -- Before: the tool call, then agent_start.
    sidecar.dispatch({ type = "tool_start", id = "tu_x", name = "Agent" })
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_x",
      name = "Agent",
      input = { description = "Find x", subagent_type = "Explore" },
    })
    assert.are.same("AnvimToolPending", bullet("^⏺ Explore%(Find x%)"))
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "x",
      tool_use_id = "tu_x",
      description = "",
      depth = 1,
      background = false,
    })
    assert.are.same("AnvimAgent1", bullet("^⏺ Explore%(Find x%)"))
    assert.are.same("Find x", agents.get("x").description)
    assert.are.same("Explore", agents.get("x").type)
    -- After: agent_start, then the streamed tool call.
    sidecar.dispatch({ type = "agent_start", agent_id = "y", tool_use_id = "tu_y", description = "Find y", depth = 1 })
    sidecar.dispatch({ type = "tool_start", id = "tu_y", name = "Agent" })
    assert.are.same("AnvimAgent2", bullet("^⏺ Agent$"))
    helpers.field("tu_y", "Agent", "description", "end", "Find y")
    assert.are.same("AnvimAgent2", bullet("^⏺ Agent%(Find y%)"))
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_y",
      name = "Agent",
      input = { description = "Find y", subagent_type = "Plan" },
    })
    assert.are.same("AnvimAgent2", bullet("^⏺ Plan%(Find y%)"))
    assert.are.same("Plan", agents.get("y").type)
    -- A tool call with only the parent id still belongs to its agent.
    sidecar.dispatch({ type = "tool_use", id = "r1", name = "Grep", input = { pattern = "y" }, parent_id = "tu_y" })
    assert.are.same(1, agents.get("y").tools)
    assert.are.same(0, agents.get("x").tools)
    sidecar.dispatch({ type = "tool_result", id = "tu_y", is_error = true, text = "failed" })
    assert.are.same("AnvimToolError", bullet("^⏺ Plan%(Find y%)"))
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
  end)

  it("keeps each agent's last place, and the files whose edits worked", function()
    fresh()
    local file = helpers.tmp .. "/places.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a" }, file)
    start("p")
    local function use(id, name, input_)
      sidecar.dispatch({ type = "tool_use", id = id, name = name, input = input_, parent_id = "tu_p", agent_id = "p" })
    end
    local function result(id, is_error)
      sidecar.dispatch({
        type = "tool_result",
        id = id,
        is_error = is_error,
        text = "",
        parent_id = "tu_p",
        agent_id = "p",
      })
    end
    use("p1", "Read", { file_path = file, offset = 2 })
    assert.are.same({ file, 2 }, place_of("p"))
    use("p2", "Edit", { file_path = file, old_string = "local c = 3\n", new_string = "local c = 4\n" })
    assert.are.same({ file, 3 }, place_of("p"))
    result("p2", true)
    assert.are.same({}, agents.get("p").files, "a failed edit edits nothing")
    -- The edit may have changed the file already.
    use("p3", "Edit", { file_path = file, old_string = "local x = 9", new_string = "return a" })
    assert.are.same({ file, 4 }, place_of("p"))
    result("p3", false)
    local other = helpers.tmp .. "/new.lua"
    use("p4", "Write", { file_path = other, content = "x" })
    result("p4", false)
    use("p5", "Edit", { file_path = file, old_string = "local a", new_string = "local A" })
    result("p5", false)
    assert.are.same({ file, 1 }, place_of("p"))
    assert.are.same({ file, other }, agents.get("p").files)
    assert.are.same(5, agents.get("p").tools)
  end)

  it("frees foreground slots at the turn's end, and background agents keep theirs", function()
    fresh()
    start("f")
    start("g", { background = true })
    local fired = 0
    local id = api.nvim_create_autocmd("User", {
      pattern = "AnvimAgents",
      callback = function()
        fired = fired + 1
      end,
    })
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
    api.nvim_del_autocmd(id)
    assert.are.same(1, fired)
    assert.are.same("stopped", agents.get("f").status)
    assert.is_nil(agents.get("f").slot)
    assert.are.same({ { "g", 2 } }, slots())
    -- An end after the turn's end only records how the agent ended.
    finish("f")
    assert.are.same("completed", agents.get("f").status)
    assert.are.same({ { "g", 2 } }, slots())
  end)

  it("forgets every agent on /clear, a resumed session and an exit", function()
    fresh()
    for _, ev in ipairs({
      { type = "reset" },
      { type = "history", session_id = "s-agents", events = {} },
      { type = "exit", code = 0, restart = true },
    }) do
      start("c1")
      start("c2", { background = true })
      sidecar.dispatch(ev)
      assert.are.same({}, slots(), ev.type)
      assert.is_nil(agents.get("c1"), ev.type)
      assert.is_nil(agents.by_tool("tu_c2"), ev.type)
      start("c3")
      assert.are.same({ { "c3", 1 } }, slots(), ev.type)
      sidecar.dispatch({ type = "reset" })
    end
    -- Only the event was fake. The replay sidecar still runs for the next specs.
    require("anvim.state").process = "ready"
  end)

  it("fits the dots into the footer: the count goes before the mode's short label, the dots before the chip", function()
    fresh()
    local state = require("anvim.state")
    local code = require("anvim.layout").wins.code
    local model, branch, buf = state.model, state.branch, api.nvim_win_get_buf(code)
    restore = function()
      state.model, state.branch = model, branch
      if api.nvim_buf_is_valid(buf) then
        api.nvim_win_set_buf(code, buf)
      end
    end
    state.model, state.branch = "claude-opus-5-5", "main"
    -- The bypass label shows when the session started in another mode. The
    -- follow status has a test of its own in input_spec.
    local config, follow = require("anvim.config").options, require("anvim.follow")
    local start_mode, mode, status, place = config.permission_mode, state.permission_mode, follow.status, follow.place
    config.permission_mode, state.permission_mode = "default", "bypassPermissions"
    follow.status, follow.place = function()
      return ""
    end, function() end
    local undo = restore
    restore = function()
      config.permission_mode, state.permission_mode, follow.status, follow.place = start_mode, mode, status, place
      undo()
    end
    local file = helpers.tmp .. "/agents_footer.lua"
    vim.fn.writefile({ "return 1" }, file)
    require("anvim.context").clear()
    api.nvim_win_set_buf(code, vim.fn.bufadd(file))
    start("d1")
    start("d2")
    local parts = {
      "git:(main)",
      "(shift+tab to cycle)",
      "⏺⏺ 2 agents",
      "⏺⏺",
      "⧉ In agents_footer.lua",
      "⧉ In agents_f...",
      "⏵⏵ bypass permissions on",
    }
    for width, want in pairs({
      [120] = {
        "git:(main)",
        "(shift+tab to cycle)",
        "⏺⏺ 2 agents",
        "⏺⏺",
        "⧉ In agents_footer.lua",
        "⏵⏵ bypass permissions on",
      },
      [95] = { "git:(main)", "⏺⏺ 2 agents", "⏺⏺", "⧉ In agents_footer.lua", "⏵⏵ bypass permissions on" },
      [85] = { "⏺⏺ 2 agents", "⏺⏺", "⧉ In agents_footer.lua", "⏵⏵ bypass permissions on" },
      [75] = { "⏺⏺", "⧉ In agents_footer.lua", "⏵⏵ bypass permissions on" },
      [60] = { "⏺⏺", "⧉ In agents_footer.lua" },
      [51] = { "⏺⏺", "⧉ In agents_footer.lua" },
      [45] = { "⧉ In agents_footer.lua" },
      [37] = { "⧉ In agents_f..." },
      [30] = {},
    }) do
      local dots, text = footer(width)
      for _, part in ipairs(parts) do
        assert.are.same(
          vim.tbl_contains(want, part),
          text:find(part, 1, true) ~= nil,
          ("%q at %d: %s"):format(part, width, text)
        )
      end
      assert.are.same(vim.tbl_contains(want, "⏺⏺") and { "AnvimAgent1", "AnvimAgent2" } or {}, dots, text)
      assert(text:find("⏵⏵ bypass", 1, true), text)
      assert.are.same(width, api.nvim_strwidth(text), text)
    end
  end)

  it("links the agent colors to mini.icons groups", function()
    for slot, group in ipairs({ "MiniIconsAzure", "MiniIconsPurple", "MiniIconsYellow", "MiniIconsBlue" }) do
      assert.are.same(group, api.nvim_get_hl(0, { name = "AnvimAgent" .. slot }).link)
    end
  end)
end)
