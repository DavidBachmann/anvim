---@module "luassert"

local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local overview = require("anvim.overview")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

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

local function finish(id, status)
  sidecar.dispatch({ type = "agent_end", agent_id = id, status = status or "completed", summary = "done" })
end

local function fresh()
  helpers.start()
  overview.close()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  transcript.clear()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

local function texts(item)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, overview.format(item)))
end

-- The bullet's group and the name's group of each row.
local function groups(item)
  local chunks = overview.format(item)
  return chunks[1][2] .. " " .. chunks[2][2]
end

describe("the Agent Overview", function()
  local notify = vim.notify
  local said = {}
  before_each(function()
    said = {}
    vim.notify = function(msg, level)
      said[#said + 1] = { msg, level }
    end
  end)
  after_each(function()
    vim.notify = notify
    overview.close()
    vim.wait(50)
    sidecar.dispatch({ type = "reset" })
  end)

  it("shows how full the context window of Claude and of each agent is", function()
    fresh()
    start("a1")
    start("a2")
    sidecar.dispatch({ type = "context", percent = 6, tokens = 60000, max = 1000000 })
    sidecar.dispatch({ type = "agent_context", agent_id = "a1", tokens = 230000, max = 1000000, percent = 23 })
    assert.are.same({
      "◉ Claude        6%  idle",
      "⏺ Agent 1      23%  working",
      "⏺ Agent 2           working",
    }, vim.tbl_map(texts, overview.items()))
  end)

  it("keeps the preview's wrap when a longer row widens the list", function()
    fresh()
    local columns = vim.o.columns
    vim.o.columns = 200
    start("w1")
    overview.open()
    local function preview()
      local p = overview.get()
      return p and p.preview.win:valid() and p.preview.win.win
    end
    local function list_width()
      return vim.api.nvim_win_get_width(overview.get().list.win.win)
    end
    assert(
      vim.wait(2000, function()
        return preview() and vim.wo[preview()].wrap
      end),
      "the preview opens with wrap"
    )
    local before = list_width()
    sidecar.dispatch({ type = "agent_progress", agent_id = "w1", description = ("Running a long command "):rep(3) })
    assert(
      vim.wait(2000, function()
        return list_width() > before
      end),
      "the longer row widens the list"
    )
    assert.is_true(vim.wo[preview()].wrap)
    overview.close()
    vim.o.columns = columns
  end)

  it("lists Claude, the running agents by slot, the one without a slot, then the ended ones, newest first", function()
    fresh()
    start("x1")
    start("x2")
    finish("x1", "failed")
    finish("x2")
    start("a1", { subagent_type = "Explore", description = "Find x" })
    start("a2", { background = true })
    start("a3")
    start("a4")
    start("a5", { subagent_type = "Explore" })
    sidecar.dispatch({ type = "agent_progress", agent_id = "a1", description = "Reading a.lua" })
    local items = overview.items()
    assert.are.same("◉ Claude      idle", texts(items[1]))
    follow.set_focus("a2")
    assert.are.same({
      "⏺ Claude      idle",
      "⏺ Explore 1   Reading a.lua",
      "◉ Agent 2     bg · working",
      "⏺ Agent 3     working",
      "⏺ Agent 4     working",
      "⏺ Explore     no slot · working",
      "⏺ Agent       done · Task x2",
      "⏺ Agent       failed · Task x1",
    }, vim.tbl_map(texts, items))
    assert.are.same({
      "AnvimClaude AnvimClaude",
      "AnvimAgent1 AnvimAgent1",
      "AnvimAgent2 AnvimAgent2",
      "AnvimAgent3 AnvimAgent3",
      "AnvimAgent4 AnvimAgent4",
      "Comment Comment",
      "AnvimToolOk Comment",
      "AnvimToolError Comment",
    }, vim.tbl_map(groups, items))
    assert.are.same("Explore 1 · Find x · running · 0 tool uses", overview.title("a1"))
    sidecar.dispatch({
      type = "agent_end",
      agent_id = "a3",
      status = "stopped",
      tool_uses = 2,
      tokens = 37100,
      duration_ms = 5600,
    })
    assert.are.same("Agent · Task a3 · stopped · 2 tool uses · 37.1k tokens · 5.6s", overview.title("a3"))
    sidecar.dispatch({ type = "agent_end", agent_id = "a4", status = "completed", tool_uses = 1, duration_ms = 3723000 })
    assert.are.same("Agent · Task a4 · done · 1 tool use · 1h 2m 3s", overview.title("a4"))
    assert.are.same("Claude · idle", overview.title(nil))
  end)
end)
