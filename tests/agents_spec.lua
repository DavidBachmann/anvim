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

  it("replays three agents in parallel: slots, places, files, bullets and the footer", function()
    fresh()
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
    assert.are.same("  ⏺⏺⏺ 3 agents", text)

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
end)
