---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

describe("input", function()
  it("labels models", function()
    assert.are.same("Opus 5.5", input.model_label("claude-opus-5-5"))
    assert.are.same("Sonnet 4.5", input.model_label("claude-sonnet-4-5-20250929"))
    assert.are.same("opus", input.model_label("opus"))
    assert.are.same("Claude", input.model_label(nil))
  end)

  it("counts a turn's time from the send, not from Claude's first reply", function()
    helpers.start()
    input.set_busy(true)
    local sent = state.turn_started
    vim.wait(20)
    sidecar.dispatch({ type = "turn_start" })
    assert.are.same(sent, state.turn_started)
    input.set_busy(false)
    sidecar.dispatch({ type = "turn_start" })
    assert(state.busy, "a turn without a prompt is busy too")
    input.set_busy(false)
  end)
end)

describe("footer", function()
  local api = vim.api
  local agents = require("anvim.agents")
  local follow = require("anvim.follow")
  local layout = require("anvim.layout")
  local saved ---@type table
  -- config.setup() makes a new table, so look it up each time.
  local function options()
    return require("anvim.config").options
  end

  local function chunks(width)
    return input.footer(width)
  end

  local function text(width)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, chunks(width)))
  end

  -- The group of the chunk that holds `needle`.
  local function group(width, needle)
    for _, chunk in ipairs(chunks(width)) do
      if chunk[1]:find(needle, 1, true) then
        return chunk[2]
      end
    end
  end

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

  -- The code window shows a file, with the cursor there, and Claude is
  -- elsewhere: the user does not follow.
  local function away(name)
    local path = helpers.tmp .. "/" .. name
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, path)
    vim.cmd.stopinsert()
    api.nvim_set_current_win(layout.wins.code)
    vim.cmd.edit(path)
    follow.track(path, 3)
  end

  before_each(function()
    helpers.start()
    saved = {
      branch = state.branch,
      model = state.model,
      effort = state.effort,
      mode = state.permission_mode,
      start = options().permission_mode,
      paused = follow.paused,
    }
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    follow.forget()
  end)

  after_each(function()
    state.branch, state.permission_mode, options().permission_mode = saved.branch, saved.mode, saved.start
    state.model, state.effort = saved.model, saved.effort
    follow.paused, state.waiting = saved.paused, nil
    agents.clear()
    follow.forget()
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    layout.focus_input({ insert = false })
  end)

  it("shows the mode's label only for a mode other than the start mode, and always in plan mode", function()
    options().permission_mode, state.permission_mode = "bypassPermissions", "bypassPermissions"
    assert(not text(200):find("bypass", 1, true), text(200))
    assert(not text(200):find("shift+tab", 1, true), text(200))
    for mode, label in pairs({
      default = "⏵ manual mode on",
      acceptEdits = "⏵⏵ accept edits on",
      plan = "⏸ plan mode on",
      auto = "⏵⏵ auto mode on",
    }) do
      state.permission_mode = mode
      assert(vim.endswith(text(200), label .. " (shift+tab to cycle) "), text(200))
    end
    options().permission_mode, state.permission_mode = "default", "default"
    assert(not text(200):find("manual", 1, true), text(200))
    options().permission_mode, state.permission_mode = "plan", "plan"
    assert(vim.endswith(text(200), "⏸ plan mode on (shift+tab to cycle) "), text(200))
  end)

  it("says ? for shortcuts while the prompt is empty, no request waits and no label shows", function()
    options().permission_mode, state.permission_mode = "bypassPermissions", "bypassPermissions"
    layout.focus_input({ insert = false })
    assert(vim.endswith(text(200), "◉ following  ? for shortcuts "), text(200))
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "what" })
    assert(not text(200):find("?", 1, true), text(200))
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    state.permission_mode = "acceptEdits"
    assert(not text(200):find("?", 1, true), text(200))
    state.permission_mode, state.waiting = "bypassPermissions", "Esc to deny"
    assert(not text(200):find("?", 1, true), text(200))
    assert(vim.endswith(text(200), "⏺ Claude is waiting for you "), text(200))
  end)

  it("shows where Claude is, in the focused agent's color, with the jump key when the user does not follow", function()
    options().permission_mode, state.permission_mode = "bypassPermissions", "bypassPermissions"
    layout.focus_input({ insert = false })
    assert(text(200):find("◉ following  ? for shortcuts", 1, true), text(200))
    assert.are.same(follow.group(), group(200, "◉ following"))
    away("footer_follow.lua")
    assert(text(200):find("⏺ Claude at footer_follow.lua:3 +1 (<leader>j)  ? for shortcuts", 1, true), text(200))
    assert.are.same("Comment", group(200, "(<leader>j)"))
    follow.paused = function()
      return true
    end
    assert(text(200):find("⏸ pinned · Claude at footer_follow.lua:3 +1 (<leader>j)", 1, true), text(200))
    follow.paused = saved.paused
    start("ff1")
    follow.set_focus("ff1")
    layout.focus_input({ insert = false })
    assert(text(200):find("◉ following Agent 1", 1, true), text(200))
    assert.are.same("AnvimAgent1", group(200, "◉ following Agent 1"))
  end)

  it("drops the hints first in a narrow column, then shortens and drops the follow status before the chip", function()
    options().permission_mode, state.permission_mode, state.branch = "default", "acceptEdits", "main"
    state.model, state.effort = "claude-opus-5-5", "xhigh"
    away("footer_narrow.lua")
    start("fn1")
    start("fn2")
    -- Each part, as a test on the footer's text or its chunks.
    local function dots(width)
      return group(width, "⏺") == "AnvimAgent1"
    end
    local parts = {
      { "the mode's hint", "(shift+tab to cycle)" },
      { "the jump key", "(<leader>j)" },
      { "the branch", "git:(main)" },
      { "the agents' count", " 2 agents" },
      { "the effort", " · xhigh" },
      { "the model", "Opus 5.5" },
      { "the long follow status", "Claude at footer_narrow.lua:3" },
      { "the long label", "accept edits on" },
      { "the dots", dots },
      { "the follow status", "footer_narrow.lua:3 +1" },
      { "the whole chip", "⧉ In footer_narrow.lua" },
      { "the chip", "⧉" },
    }
    local function has(width, part)
      if type(part) == "function" then
        return part(width)
      end
      return text(width):find(part, 1, true) ~= nil
    end
    for _, part in ipairs(parts) do
      assert(has(200, part[2]), part[1] .. ": " .. text(200))
    end
    -- The widest width at which each part is gone. Once gone, it stays gone.
    local gone = {}
    for width = 199, 20, -1 do
      for i, part in ipairs(parts) do
        if not has(width, part[2]) then
          gone[i] = gone[i] or width
        else
          assert(not gone[i], ("%s came back at %d: %s"):format(part[1], width, text(width)))
        end
      end
    end
    for i = 2, #parts do
      local order = ("%s goes before %s: %s"):format(parts[i - 1][1], parts[i][1], vim.inspect(gone))
      assert(gone[i - 1] and gone[i] and gone[i - 1] > gone[i], order)
    end
    assert(text(gone[1]):find("⏵⏵ accept edits on", 1, true), text(gone[1]))
    assert(text(gone[#parts] + 1):find("⏵⏵ accept edits", 1, true), text(gone[#parts] + 1))
    for width = gone[#parts - 1], 200 do
      assert.are.same(width, api.nvim_strwidth(text(width)), text(width))
    end
  end)

  it("keeps the follow status at 50 columns, leaves it to the statusline at 31, and shortens waiting", function()
    options().permission_mode, state.permission_mode, state.branch = "bypassPermissions", "bypassPermissions", nil
    state.model = "claude-opus-5-5"
    away("f.lua")
    local wide, follows = input.footer(50)
    assert(text(50):find("⏺ Claude at f.lua:3 +1", 1, true), text(50))
    assert(not text(50):find("Opus 5.5", 1, true), "the model goes before the follow status: " .. text(50))
    assert.are.same(true, follows)
    assert.are.same(50, api.nvim_strwidth(text(50)), text(50))
    assert(wide)
    local _, narrow = input.footer(31)
    assert.are.same(false, narrow, text(31))
    assert(text(31):find("⧉ In f.lua", 1, true), text(31))
    state.waiting = "Esc to deny"
    assert(vim.endswith(text(31), "⧉ In f.lua  ⏺ waiting "), text(31))
  end)

  it("drops ? for shortcuts before the jump key, when no label shows", function()
    options().permission_mode, state.permission_mode = "bypassPermissions", "bypassPermissions"
    away("footer_hints.lua")
    local width = 200
    while text(width):find("? for shortcuts", 1, true) do
      width = width - 1
    end
    assert(text(width):find("(<leader>j)", 1, true), text(width))
    assert.are.same(width, api.nvim_strwidth(text(width)), text(width))
  end)
end)

describe("sidecar", function()
  it("reads lines that its chunks split anywhere", function()
    local got = {}
    sidecar.on("reader_test", function(ev)
      got[#got + 1] = ev.n
    end)
    local read = sidecar.line_reader()
    local big = ('{"type":"reader_test","n":3,"pad":"%s"}'):format(("x"):rep(200000))
    local small = '{"type":"reader_test","n":1}\n\n{"type":"reader_test","n":2}\n'
    for i = 1, #small, 5 do
      read(nil, small:sub(i, i + 4))
    end
    local text = big .. "\n"
    for i = 1, #text, 7919 do
      read(nil, text:sub(i, i + 7918))
    end
    read(nil, nil)
    vim.wait(1000, function()
      return #got == 3
    end)
    assert.are.same({ 1, 2, 3 }, got)
  end)
end)
