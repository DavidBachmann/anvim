---@module "luassert"

local agents = require("anvim.agents")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")
local tree = require("anvim.tree")

local function start(id, background)
  sidecar.dispatch({
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "general-purpose",
    depth = 1,
    background = background == true,
  })
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

-- A Read's tool call, which moves the agent's place.
local function read(id, path, agent, offset)
  sidecar.dispatch({
    type = "tool_use",
    id = id,
    name = "Read",
    input = { file_path = path, offset = offset },
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

local function turn_start()
  sidecar.dispatch({ type = "turn_start" })
end

-- The marks that the explorer shows on a file, or on a folder, as "slot:kind".
-- Nil for none.
local function marks(path, dir)
  local list = tree.marks({ file = path, dir = dir ~= nil, open = dir == "open" })
  return list and vim.tbl_map(function(mark)
    return ("%d:%s"):format(mark.slot, mark.kind)
  end, list)
end

-- The dots that the explorer's format adds to a row, with their groups.
local function dots(path, dir)
  local picker = { opts = Snacks.picker.config.get({ source = "explorer" }), list = { win = {} } }
  for _, chunk in ipairs(tree.format({ file = path, dir = dir ~= nil, open = dir == "open" }, picker)) do
    if chunk.virt_text_pos == "right_align" and chunk.virt_text[1][1] ~= " " then
      return chunk.virt_text
    end
  end
  return {}
end

local function file(name)
  local path = helpers.tmp .. "/" .. name
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" }, path)
  return path
end

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  transcript.clear()
  -- The main agent's place stays for the footer after a turn, and a spec
  -- before this one may have left one.
  turn_end()
  turn_start()
end

-- Counts the open explorer's redraws, with a stand-in for the explorer.
local function count_redraws(fn)
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
  local ok, err = pcall(fn, function()
    vim.wait(50)
    return updates
  end)
  tree.explorer, tree.update = explorer, update
  assert(ok, err)
end

describe("tree", function()
  after_each(function()
    agents.clear()
    -- A running turn keeps the spinner's timer going for the specs after this one.
    turn_end()
  end)

  it("marks each agent's place with a ⏺ and the other files it writes to with a •, in slot order", function()
    fresh()
    local a, b = file("place_a.lua"), file("place_b.lua")
    start("p1")
    edit("e1", a, "p1")
    result("e1", false, "p1")
    assert.are.same({ "1:place" }, marks(a), "one mark per agent: the place wins")
    read("r1", b, "p1")
    assert.are.same({ "1:wrote" }, marks(a))
    assert.are.same({ "1:place" }, marks(b))
    read("r2", a)
    assert.are.same({ "0:place", "1:wrote" }, marks(a))
    assert.are.same({ { "⏺", "AnvimClaude" }, { "•", "AnvimAgent1" }, { " " } }, dots(a))
    assert.are.same({ { "⏺", "AnvimAgent1" }, { " " } }, dots(b))
    -- The main agent writes where it reads: one ⏺, no •.
    helpers.field("m1", "Edit", "file_path", "end", a)
    assert.are.same({ "0:place", "1:wrote" }, marks(a))
    read("r3", b)
    assert.are.same({ "0:wrote", "1:wrote" }, marks(a))
    assert.are.same({ "0:place", "1:place" }, marks(b))
  end)

  it("redraws the open explorer once for many changes, and not when the marks stay the same", function()
    fresh()
    count_redraws(function(updates)
      for i = 1, 5 do
        edit("e" .. i, ("%s/many%d.lua"):format(helpers.tmp, i))
      end
      assert.are.same(1, updates())
      result("e1", false)
      assert.are.same(1, updates(), "the edit worked, and its mark stays")
      result("e2", true)
      assert.are.same(2, updates())
    end)
  end)
end)
