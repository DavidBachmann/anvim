---@module "luassert"

local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")

-- The catch-up on entering the prompt waits for the event loop.
local function shows(path)
  return vim.wait(1000, function()
    local win = layout.wins.code
    return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == vim.fn.bufnr(path)
  end)
end

describe("follow", function()
  -- The Reads get no result, so the turn ends as after an interrupt. Their
  -- tool lines must not wait for a turn_end in another spec.
  after_each(function()
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
  end)

  it("points the statusline at Claude when not following, and focus catches up", function()
    helpers.start()
    local file = helpers.tmp .. "/follow.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a" }, file)
    vim.api.nvim_set_current_win(layout.wins.code)
    local before = vim.api.nvim_win_get_buf(layout.wins.code)
    sidecar.dispatch({ type = "tool_use", id = "r1", name = "Read", input = { file_path = file, offset = 3 } })
    assert.are.same(before, vim.api.nvim_win_get_buf(layout.wins.code), "code window stays put")
    local status = follow.status()
    assert(status:find("⏺ Claude at follow.lua:3", 1, true), status)
    layout.focus_input()
    assert(shows(file), "focusing the input catches up")
    assert.are.same(3, vim.api.nvim_win_get_cursor(layout.wins.code)[1])
    assert.are.same("◉ following", follow.status())
  end)

  it("gives a file that the catch-up loads its filetype and the read-only lock", function()
    helpers.start()
    local file = helpers.tmp .. "/caught.lua"
    vim.fn.writefile({ "local caught = 1", "return caught" }, file)
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(layout.wins.code)
    sidecar.dispatch({ type = "tool_use", id = "r2", name = "Read", input = { file_path = file } })
    layout.focus_input()
    vim.cmd.stopinsert()
    assert(shows(file), "no catch-up")
    local buf = vim.fn.bufnr(file)
    assert.are.same("lua", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
  end)
end)

describe("the tool pane", function()
  local agentlog = require("anvim.agentlog")
  local agents = require("anvim.agents")
  local transcript = require("anvim.transcript")
  local api = vim.api

  local function start(id)
    sidecar.dispatch({
      type = "agent_start",
      agent_id = id,
      tool_use_id = "tu_" .. id,
      description = "Task " .. id,
      subagent_type = "Explore",
      depth = 1,
      background = false,
    })
  end

  local function read(id, tool_id)
    local input = { file_path = helpers.tmp .. "/matchparen.lua", offset = 1, limit = 2 }
    sidecar.dispatch({
      type = "tool_use",
      id = tool_id,
      name = "Read",
      input = input,
      parent_id = "tu_" .. id,
      agent_id = id,
    })
  end

  local function pane_buf()
    return api.nvim_win_get_buf(layout.wins.pane)
  end

  local function winbar()
    local pane = layout.wins.pane
    local bar = api.nvim_eval_statusline(vim.wo[pane].winbar, { winid = pane, use_winbar = true, highlights = true })
    return { bar.str, bar.highlights[#bar.highlights].group }
  end

  before_each(function()
    helpers.start()
    sidecar.dispatch({ type = "reset" })
    follow.forget()
    layout.set_pane(true)
  end)

  after_each(function()
    layout.set_pane(false)
    agents.clear()
    follow.forget()
  end)

  it("shows the tool calls of the agent that follow mode follows, from their end", function()
    local main = transcript.log_buf()
    assert.are.same(main, pane_buf())
    assert.are.same({ " Tool calls", "WinBarNC" }, winbar())
    start("pa1")
    for i = 1, 30 do
      read("pa1", "pane_read" .. i)
    end
    follow.set_focus("pa1")
    local log = agentlog.buf("pa1")
    assert(log, "no log")
    assert.are.same(log, pane_buf(), "the focused agent's log")
    assert.are.same(api.nvim_buf_line_count(log), api.nvim_win_get_cursor(layout.wins.pane)[1], "at its end")
    assert.are.same({ " Tool calls · Explore 1", "AnvimAgent1" }, winbar())
    local wo = vim.wo[layout.wins.pane]
    assert.are.same({ false, true, "" }, { wo.number, wo.winfixbuf, wo.statuscolumn }, "the pane's own options")

    follow.set_focus(nil)
    assert.are.same(main, pane_buf(), "focus back on Claude")
    assert.are.same({ " Tool calls", "WinBarNC" }, winbar())

    follow.set_focus("pa1")
    sidecar.dispatch({ type = "agent_end", agent_id = "pa1", status = "completed", summary = "done" })
    assert.are.same(main, pane_buf(), "the focused agent ended")
  end)

  it("shows the main log after the agents go, as after /clear", function()
    start("pa2")
    read("pa2", "pane_read_clear")
    follow.set_focus("pa2")
    assert.are.same(agentlog.buf("pa2"), pane_buf())
    sidecar.dispatch({ type = "reset" })
    assert.are.same(transcript.log_buf(), pane_buf())
  end)
end)
