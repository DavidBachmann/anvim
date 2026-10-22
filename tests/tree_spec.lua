---@module "luassert"

local agents = require("anvim.agents")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
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

  it("marks each agent once on a closed folder, with a ⏺ when its place is below it", function()
    fresh()
    local inner, other, outer = file("fold/inner.lua"), file("fold/deep/other.lua"), file("fold_outer.lua")
    local dir = helpers.tmp .. "/fold"
    start("q1")
    edit("e1", inner, "q1")
    result("e1", false, "q1")
    edit("e2", other, "q1")
    result("e2", false, "q1")
    assert.are.same({ "1:place" }, marks(dir, "closed"))
    assert.are.same({ { "⏺", "AnvimAgent1" }, { " " } }, dots(dir, "closed"))
    read("r1", outer, "q1")
    assert.are.same({ "1:wrote" }, marks(dir, "closed"))
    assert.are.same({ { "•", "AnvimAgent1" }, { " " } }, dots(dir, "closed"))
    read("r2", other)
    assert.are.same({ "0:place", "1:wrote" }, marks(dir, "closed"))
    assert.are.same({ "0:place", "1:wrote" }, marks(dir .. "/deep", "closed"))
    assert.is_nil(marks(dir, "open"))
    assert.are.same({}, dots(dir, "open"))
  end)

  it("keeps the main agent's place mark until the turn ends, and an agent's until the agent ends", function()
    fresh()
    local a, b, c = file("life_a.lua"), file("life_b.lua"), file("life_c.lua")
    read("r1", a)
    start("l1")
    read("r2", b, "l1")
    start("l2", true)
    read("r3", c, "l2")
    assert.are.same({ { "0:place" }, { "1:place" }, { "2:place" } }, { marks(a), marks(b), marks(c) })
    finish("l1")
    assert.is_nil(marks(b))
    turn_end()
    assert.is_nil(marks(a))
    assert.are.same(a, follow.place().path, "the footer still knows where Claude is")
    assert.are.same({ "2:place" }, marks(c), "a background agent's mark outlives the turn")
    -- The next turn marks the main agent's place again once it moves.
    turn_start()
    read("r4", a)
    assert.are.same({ "0:place" }, marks(a))
    finish("l2")
    assert.is_nil(marks(c))
  end)

  it("drops the main agent's place mark when a turn's end flushes the steps through a Bash call's reads", function()
    fresh()
    local a, b, c = file("steps_a.lua"), file("steps_b.lua"), file("steps_c.lua")
    require("anvim.context").clear()
    layout.focus_input({ insert = false })
    assert.is_true(follow.shows(nil))
    sidecar.dispatch({
      type = "tool_use",
      id = "s1",
      name = "Bash",
      input = { command = ("cat %s %s %s"):format(a, b, c), description = "Read" },
    })
    assert.are.same({ "0:place" }, marks(a))
    turn_end()
    assert.are.same(c, follow.places()[""].path, "the steps counted at once")
    assert.is_nil(marks(a))
    assert.is_nil(marks(c))
  end)

  it("drops the main agent's place mark when the sidecar exits", function()
    fresh()
    local a = file("exit_a.lua")
    read("r1", a)
    assert.are.same({ "0:place" }, marks(a))
    sidecar.dispatch({ type = "exit", code = 0, restart = true })
    state.process = "ready"
    assert.is_nil(marks(a))
  end)

  it("gives a waiting agent no mark until it gets a slot", function()
    fresh()
    local a = file("wait_a.lua")
    for _, id in ipairs({ "w1", "w2", "w3", "w4", "w5" }) do
      start(id)
    end
    read("r1", a, "w5")
    assert.is_nil(marks(a))
    finish("w3")
    assert.are.same({ "3:place" }, marks(a), "w5 takes the freed slot")
  end)

  it("puts the marks of a file's writers on it, from the edit's start, up to three and a +", function()
    fresh()
    local path = file("dots.lua")
    for _, id in ipairs({ "d1", "d2", "d3", "d4" }) do
      start(id)
    end
    -- The main agent's path streams before the rest of its edit.
    helpers.field("m1", "Edit", "file_path", "end", path)
    assert.are.same({ "0:wrote" }, marks(path))
    edit("e4", path, "d4")
    edit("e2", path, "d2", "Write")
    assert.are.same({ "0:wrote", "2:place", "4:place" }, marks(path))
    assert.are.same(
      { { "•", "AnvimClaude" }, { "⏺", "AnvimAgent2" }, { "⏺", "AnvimAgent4" }, { " " } },
      dots(path)
    )
    edit("e1", path, "d1")
    assert.are.same(
      { { "•", "AnvimClaude" }, { "⏺", "AnvimAgent1" }, { "⏺", "AnvimAgent2" }, { "+", "Comment" }, { " " } },
      dots(path)
    )
    assert.are.same({}, dots(helpers.tmp .. "/other.lua"))
  end)

  it("puts the marks below a closed folder on it, and none on an open one", function()
    fresh()
    local deep = helpers.tmp .. "/sub/deep/x.lua"
    local near = helpers.tmp .. "/sub/y.lua"
    start("f1")
    edit("e1", deep, "f1", "Write")
    edit("e2", near, nil, "Write")
    assert.are.same({ "0:wrote", "1:wrote" }, marks(helpers.tmp .. "/sub", "closed"))
    assert.is_nil(marks(helpers.tmp .. "/sub", "open"))
    assert.are.same({ "1:wrote" }, marks(helpers.tmp .. "/sub/deep", "closed"))
    assert.are.same({ "1:wrote" }, marks(deep))
    assert.is_nil(marks(helpers.tmp .. "/sub/deep"), "a file has the folder's path only as a folder")
  end)

  it("keeps the main agent's written files until the turn ends, and an agent's until the agent ends", function()
    fresh()
    local mine, theirs = helpers.tmp .. "/mine.lua", helpers.tmp .. "/theirs.lua"
    start("g1")
    edit("e1", mine)
    result("e1", false)
    edit("e2", theirs, "g1")
    result("e2", false, "g1")
    assert.are.same({ { "0:wrote" }, { "1:wrote" } }, { marks(mine), marks(theirs) })
    finish("g1")
    assert.are.same({ "0:wrote" }, marks(mine))
    assert.is_nil(marks(theirs))
    turn_end()
    assert.is_nil(marks(mine))
    -- A background agent outlives the turn, and so do its marks.
    start("g2", true)
    edit("e3", theirs, "g2")
    turn_end()
    assert.are.same({ "1:wrote" }, marks(theirs))
  end)

  it("gives a failed edit no mark, unless the agent wrote the file before in its run", function()
    fresh()
    local path = helpers.tmp .. "/failed.lua"
    helpers.field("m1", "Edit", "file_path", "end", path)
    result("m1", true)
    assert.is_nil(marks(path))
    edit("m2", path)
    result("m2", false)
    edit("m3", path)
    result("m3", true)
    assert.are.same({ "0:wrote" }, marks(path))
    start("h1")
    edit("e1", path, "h1")
    result("e1", true, "h1")
    assert.are.same({ "0:wrote" }, marks(path))
  end)

  it("names files as the explorer does, through symlinks and for files that do not exist yet", function()
    fresh()
    local link = vim.fn.tempname()
    assert(vim.uv.fs_symlink(helpers.tmp, link))
    local path = file("linked.lua")
    edit("e1", link .. "/linked.lua")
    edit("e2", link .. "/./new/dir/../made.lua", nil, "Write")
    assert.are.same({ "0:wrote" }, marks(path))
    assert.are.same({ "0:wrote" }, marks(helpers.tmp .. "/new/made.lua"))
    assert.are.same({ "0:wrote" }, marks(helpers.tmp .. "/new", "closed"))
    read("r1", link .. "/linked.lua")
    assert.are.same({ "0:place" }, marks(path), "a place resolves as a written file does")
    vim.uv.fs_unlink(link)
  end)

  it("marks a symlink in the project under its own name, and its target too", function()
    fresh()
    local dir = helpers.tmp .. "/links"
    vim.fn.mkdir(dir .. "/real", "p")
    vim.fn.writefile({ "a" }, dir .. "/AGENTS.md")
    vim.fn.writefile({ "a" }, dir .. "/real/x.lua")
    assert(vim.uv.fs_symlink(dir .. "/AGENTS.md", dir .. "/CLAUDE.md"))
    assert(vim.uv.fs_symlink(dir .. "/real", dir .. "/linkdir"))
    edit("e1", dir .. "/CLAUDE.md")
    edit("e2", dir .. "/linkdir/x.lua")
    assert.are.same({ "0:wrote" }, marks(dir .. "/CLAUDE.md"))
    assert.are.same({ "0:wrote" }, marks(dir .. "/AGENTS.md"))
    assert.are.same({ "0:wrote" }, marks(dir .. "/linkdir/x.lua"))
    assert.are.same({ "0:wrote" }, marks(dir .. "/linkdir", "closed"))
    assert.are.same({ "0:wrote" }, marks(dir .. "/real/x.lua"))
    vim.fn.delete(dir, "rf")
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

  it("neither recomputes nor redraws the marks when a place moves within its file", function()
    fresh()
    local a, b = file("move_a.lua"), file("move_b.lua")
    start("v1")
    local fired = 0
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "AnvimAgentFiles",
      callback = function()
        fired = fired + 1
      end,
    })
    count_redraws(function(updates)
      read("r1", a, "v1")
      assert.are.same(1, updates())
      fired = 0
      read("r2", a, "v1", 8)
      read("r3", a, "v1", 3)
      assert.are.same({ 0, 1 }, { fired, updates() })
      assert.are.same({ a, 3 }, { follow.places().v1.path, follow.places().v1.line })
      read("r4", b, "v1")
      assert.are.same({ 1, 2 }, { fired, updates() })
    end)
    vim.api.nvim_del_autocmd(id)
  end)
end)
