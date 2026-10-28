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

---@param name? string The fixture's name, agents-session by default.
local function recording(name)
  return helpers.events(name or "agents-session")
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

-- The groups of the footer's dots, and the footer's text, as drawn under the prompt.
local function footer()
  local ns = api.nvim_get_namespaces()["anvim.input"]
  local mark = api.nvim_buf_get_extmarks(input.buf(), ns, 0, -1, { details = true })[1]
  local chunks = mark[4].virt_lines[#mark[4].virt_lines]
  local dots, text = {}, {}
  for _, chunk in ipairs(chunks) do
    if chunk[1] == "⏺" then
      dots[#dots + 1] = chunk[2]
    end
    text[#text + 1] = chunk[1]
  end
  return dots, table.concat(text)
end

local function slots()
  return vim.tbl_map(function(agent)
    return { agent.id, agent.slot or false }
  end, agents.running())
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
  -- State that a case changes, to restore even when it fails.
  local restore ---@type fun()?

  -- Running agents would show in other specs' footers.
  after_each(function()
    agents.clear()
    local fn = restore
    restore = nil
    if fn then
      fn()
    end
  end)

  it("ctrl+b in the prompt moves a foreground agent to the background, and the agent outlives the turn", function()
    helpers.fresh()
    input.set_busy(true)
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "f1",
      tool_use_id = "toolu_F",
      description = "Sleep",
      depth = 1,
      background = false,
    })
    helpers.capture_sends(function(sent)
      api.nvim_buf_call(input.buf(), function()
        vim.fn.maparg("<C-b>", "i", false, true).callback()
      end)
      assert.are.same({ { type = "background" } }, sent)
    end)
    sidecar.dispatch({ type = "agent_background", agent_id = "f1" })
    sidecar.dispatch({ type = "turn_end", subtype = "success", duration_ms = 1, cost_usd = 0, num_turns = 0 })
    assert.are.same("running", agents.get("f1").status)
    sidecar.dispatch({ type = "agent_end", agent_id = "f1", status = "completed" })
    assert.are.same("completed", agents.get("f1").status)
  end)

  it("colors a todo item's owner as its agent: the slot color while it runs, dim once it ended", function()
    helpers.fresh()
    local todos = require("anvim.todos")
    restore = function()
      todos.set({})
    end
    sidecar.dispatch({
      type = "todos",
      items = {
        { id = 1, subject = "Fix lua", status = "in_progress", owner = "lua-fix" },
        { id = 2, subject = "Fix docs", status = "pending", owner = "nobody", blocked_by = { 1 } },
      },
    })
    local buf = todos.buf()
    local ns = api.nvim_get_namespaces()["anvim.todos"]
    -- The group of the mark that covers text on row 0-based row.
    local function group_of(row, text)
      local col = assert(helpers.buf_lines(buf)[row + 1]:find(text, 1, true), text) - 1
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
        if m[3] == col and m[4].end_col == col + #text then
          return m[4].hl_group
        end
      end
      return "none"
    end
    assert.are.same(
      { "  ☐ #1 Fix lua · lua-fix", "  ☐ #2 Fix docs · nobody  blocked by #1" },
      helpers.buf_lines(buf)
    )
    assert.are.same("none", group_of(0, "lua-fix"))

    sidecar.dispatch({
      type = "tool_use",
      id = "toolu_L",
      name = "Agent",
      input = { description = "Fix lua", prompt = "Fix it", name = "lua-fix" },
    })
    sidecar.dispatch({ type = "agent_start", agent_id = "l1", tool_use_id = "toolu_L", depth = 1, background = true })
    assert.are.same(agents.group(agents.get("l1").slot), group_of(0, "lua-fix"))
    assert.are.same("AnvimTodoActive", group_of(0, "Fix lua"))
    assert.are.same("none", group_of(1, "nobody"))

    sidecar.dispatch({ type = "agent_end", agent_id = "l1", status = "completed" })
    assert.are.same("AnvimResult", group_of(0, "lua-fix"))
    agents.clear("reset")
    assert.are.same("none", group_of(0, "lua-fix"))
  end)

  it("replays three agents in parallel: slots, places, files, bullets and the footer", function()
    helpers.fresh()
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
    local dots, text = footer()
    assert.are.same({ "AnvimAgent1", "AnvimAgent2", "AnvimAgent3" }, dots)
    assert.are.same("  ⏺⏺⏺ 3 agents ↓", text)

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
    dots, text = footer()
    assert.are.same({}, dots)
    assert(not text:find("agent", 1, true), text)
  end)

  it("selects the agent count with j on the last prompt line, and enter opens the Agent Overview", function()
    helpers.fresh()
    local layout, overview = require("anvim.layout"), require("anvim.overview")
    restore = function()
      overview.close()
      input.deselect()
      sidecar.dispatch({ type = "permission_cancel", req = 951 })
    end
    sidecar.dispatch({ type = "agent_start", agent_id = "sel1", tool_use_id = "tu_sel1", subagent_type = "Explore" })
    layout.focus_input({ insert = false })
    vim.cmd.stopinsert()
    local function keys(str)
      api.nvim_feedkeys(vim.keycode(str), "mxt", false)
    end
    -- The count's chunk and its group.
    local function count()
      local ns = api.nvim_get_namespaces()["anvim.input"]
      local mark = api.nvim_buf_get_extmarks(input.buf(), ns, 0, -1, { details = true })[1]
      for _, chunk in ipairs(mark[4].virt_lines[#mark[4].virt_lines]) do
        if chunk[1]:find("agent", 1, true) then
          return chunk[1], chunk[2]
        end
      end
    end
    assert.are.same({ "1 agent ↓", "AnvimChip" }, { count() })

    keys("j")
    assert(input.agents_selected(), "j on the last line selects the count")
    assert.are.same({ "1 agent ↓", "AnvimChipSelected" }, { count() })
    keys("<CR>")
    assert(overview.get(), "enter opens the Agent Overview")
    assert(not input.agents_selected(), "enter ends the selection")
    overview.close()
    vim.wait(50)
    layout.focus_input({ insert = false })

    local follow = require("anvim.follow")
    keys("j")
    keys("f")
    assert.are.same("sel1", follow.focus, "f on the count follows the agent")
    assert(input.agents_selected(), "f keeps the selection")
    keys("f")
    assert.is_nil(follow.focus, "f follows Claude after the last agent")
    keys("k")
    assert(not input.agents_selected(), "k ends the selection")
    assert.are.same({ "1 agent ↓", "AnvimChip" }, { count() })

    -- A request takes j for its choices, and gives it back when it closes.
    local req = { command = "make" }
    sidecar.dispatch({ type = "tool_start", id = "sel_tool", name = "Bash" })
    sidecar.dispatch({ type = "tool_use", id = "sel_tool", name = "Bash", input = req })
    sidecar.dispatch({ type = "permission_request", req = 951, tool_use_id = "sel_tool", tool = "Bash", input = req })
    keys("j")
    assert(not input.agents_selected(), "j moves through the choices while a request waits")
    sidecar.dispatch({ type = "permission_cancel", req = 951 })
    sidecar.dispatch({ type = "tool_result", id = "sel_tool", is_error = true, text = "cancelled" })
    layout.focus_input({ insert = false })
    keys("j")
    assert(input.agents_selected(), "j selects the count again after the request")
    -- While Claude works, a first <Esc> elsewhere would arm the stop.
    input.set_busy(true)
    keys("<Esc>")
    local armed = input.armed()
    input.set_busy(false)
    assert(not input.agents_selected(), "esc ends the selection")
    assert.is_nil(armed, "esc only ends the selection")
  end)
end)
