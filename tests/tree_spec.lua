---@module "luassert"

local agents = require("anvim.agents")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")
local tree = require("anvim.tree")

local function start(id)
  sidecar.dispatch({
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "general-purpose",
    depth = 1,
    background = false,
  })
end

local function finish(id)
  sidecar.dispatch({ type = "agent_end", agent_id = id, status = "completed", summary = "done" })
end

-- An edit's tool call: a subagent's with its id, or the main agent's without.
local function edit(id, path, agent, name)
  sidecar.dispatch({
    type = "tool_use",
    id = id,
    name = name or "Edit",
    input = { file_path = path, old_string = "a", new_string = "b" },
    parent_id = agent and "tu_" .. agent or nil,
    agent_id = agent,
  })
end

local function result(id, is_error, agent)
  sidecar.dispatch({
    type = "tool_result",
    id = id,
    is_error = is_error,
    text = "",
    parent_id = agent and "tu_" .. agent or nil,
    agent_id = agent,
  })
end

local function turn_end()
  sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
end

-- The slots that the explorer shows on a file, or on a folder. Nil for none.
local function slots(path, dir)
  return tree.slots({ file = path, dir = dir ~= nil, open = dir == "open" })
end

-- The dots that the explorer's format adds to a row, with their groups.
local function dots(path)
  local picker = { opts = Snacks.picker.config.get({ source = "explorer" }) }
  for _, chunk in ipairs(tree.format({ file = path }, picker)) do
    if chunk.virt_text_pos == "right_align" and chunk.virt_text[1][1] ~= " " then
      return chunk.virt_text
    end
  end
  return {}
end

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  transcript.clear()
end

describe("tree", function()
  after_each(function()
    agents.clear()
  end)

  it("dots a file for each agent that writes to it, from the edit's start, up to three and a +", function()
    fresh()
    local file = helpers.tmp .. "/dots.lua"
    vim.fn.writefile({ "a" }, file)
    for _, id in ipairs({ "d1", "d2", "d3", "d4" }) do
      start(id)
    end
    -- The main agent's path streams before the rest of its edit.
    helpers.field("m1", "Edit", "file_path", "end", file)
    assert.are.same({ 0 }, slots(file))
    edit("e4", file, "d4")
    edit("e2", file, "d2", "Write")
    assert.are.same({ 0, 2, 4 }, slots(file))
    assert.are.same(
      { { "⏺", "AnvimClaude" }, { "⏺", "AnvimAgent2" }, { "⏺", "AnvimAgent4" }, { " " } },
      dots(file)
    )
    edit("e1", file, "d1")
    assert.are.same({ 0, 1, 2, 4 }, slots(file))
    assert.are.same(
      { { "⏺", "AnvimClaude" }, { "⏺", "AnvimAgent1" }, { "⏺", "AnvimAgent2" }, { "+", "Comment" }, { " " } },
      dots(file)
    )
    assert.are.same({}, dots(helpers.tmp .. "/other.lua"))
  end)

  it("puts the dots below a closed folder on it, and none on an open one", function()
    fresh()
    local deep = helpers.tmp .. "/sub/deep/x.lua"
    local near = helpers.tmp .. "/sub/y.lua"
    start("f1")
    edit("e1", deep, "f1", "Write")
    edit("e2", near, nil, "Write")
    assert.are.same({ 0, 1 }, slots(helpers.tmp .. "/sub", "closed"))
    assert.is_nil(slots(helpers.tmp .. "/sub", "open"))
    assert.are.same({ 1 }, slots(helpers.tmp .. "/sub/deep", "closed"))
    assert.are.same({ 1 }, slots(deep))
    assert.is_nil(slots(helpers.tmp .. "/sub/deep"), "a file has the folder's path only as a folder")
  end)

  it("keeps the main agent's dots until the turn ends, and an agent's until the agent ends", function()
    fresh()
    local mine, theirs = helpers.tmp .. "/mine.lua", helpers.tmp .. "/theirs.lua"
    start("g1")
    edit("e1", mine)
    result("e1", false)
    edit("e2", theirs, "g1")
    result("e2", false, "g1")
    assert.are.same({ { 0 }, { 1 } }, { slots(mine), slots(theirs) })
    finish("g1")
    assert.are.same({ 0 }, slots(mine))
    assert.is_nil(slots(theirs))
    turn_end()
    assert.is_nil(slots(mine))
    -- A background agent outlives the turn, and so do its dots.
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "g2",
      tool_use_id = "tu_g2",
      description = "",
      depth = 1,
      background = true,
    })
    edit("e3", theirs, "g2")
    turn_end()
    assert.are.same({ 1 }, slots(theirs))
  end)

  it("gives a failed edit no dot, unless the agent wrote the file before in its run", function()
    fresh()
    local file = helpers.tmp .. "/failed.lua"
    helpers.field("m1", "Edit", "file_path", "end", file)
    result("m1", true)
    assert.is_nil(slots(file))
    edit("m2", file)
    result("m2", false)
    edit("m3", file)
    result("m3", true)
    assert.are.same({ 0 }, slots(file))
    start("h1")
    edit("e1", file, "h1")
    result("e1", true, "h1")
    assert.are.same({ 0 }, slots(file))
  end)

  it("gives an agent without a slot no dot until it gets one", function()
    fresh()
    local file = helpers.tmp .. "/waits.lua"
    for _, id in ipairs({ "w1", "w2", "w3", "w4", "w5" }) do
      start(id)
    end
    edit("e5", file, "w5")
    assert.is_nil(slots(file))
    finish("w3")
    assert.are.same({ 3 }, slots(file), "w5 takes the freed slot")
  end)

  it("names files as the explorer does, through symlinks and for files that do not exist yet", function()
    fresh()
    local link = vim.fn.tempname()
    assert(vim.uv.fs_symlink(helpers.tmp, link))
    local file = helpers.tmp .. "/linked.lua"
    vim.fn.writefile({ "a" }, file)
    edit("e1", link .. "/linked.lua")
    edit("e2", link .. "/./new/dir/../made.lua", nil, "Write")
    assert.are.same({ 0 }, slots(file))
    assert.are.same({ 0 }, slots(helpers.tmp .. "/new/made.lua"))
    assert.are.same({ 0 }, slots(helpers.tmp .. "/new", "closed"))
    vim.uv.fs_unlink(link)
  end)

  it("dots a symlink in the project under its own name, and its target too", function()
    fresh()
    local dir = helpers.tmp .. "/links"
    vim.fn.mkdir(dir .. "/real", "p")
    vim.fn.writefile({ "a" }, dir .. "/AGENTS.md")
    vim.fn.writefile({ "a" }, dir .. "/real/x.lua")
    assert(vim.uv.fs_symlink(dir .. "/AGENTS.md", dir .. "/CLAUDE.md"))
    assert(vim.uv.fs_symlink(dir .. "/real", dir .. "/linkdir"))
    edit("e1", dir .. "/CLAUDE.md")
    edit("e2", dir .. "/linkdir/x.lua")
    assert.are.same({ 0 }, slots(dir .. "/CLAUDE.md"))
    assert.are.same({ 0 }, slots(dir .. "/AGENTS.md"))
    assert.are.same({ 0 }, slots(dir .. "/linkdir/x.lua"))
    assert.are.same({ 0 }, slots(dir .. "/linkdir", "closed"))
    assert.are.same({ 0 }, slots(dir .. "/real/x.lua"))
    vim.fn.delete(dir, "rf")
  end)

  it("redraws the open explorer once for many changes, and not when the dots stay the same", function()
    fresh()
    local updates = 0
    local explorer, update = tree.explorer, tree.update
    tree.explorer = function()
      return {
        list = {
          update = function(_, opts)
            assert.are.same({ force = true }, opts)
            updates = updates + 1
          end,
        },
      }
    end
    tree.update = function() end
    local ok, err = pcall(function()
      for i = 1, 5 do
        edit("e" .. i, ("%s/many%d.lua"):format(helpers.tmp, i))
      end
      vim.wait(50)
      assert.are.same(1, updates)
      result("e1", false)
      vim.wait(50)
      assert.are.same(1, updates, "the edit worked, and its dot stays")
      result("e2", true)
      vim.wait(50)
      assert.are.same(2, updates)
    end)
    tree.explorer, tree.update = explorer, update
    assert(ok, err)
  end)
end)
