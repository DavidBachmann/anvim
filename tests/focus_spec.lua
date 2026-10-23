---@module "luassert"

local agents = require("anvim.agents")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local permission = require("anvim.permission")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

local function file(name)
  local path = helpers.tmp .. "/" .. name
  vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "local d = 4", "return a" }, path)
  return path
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

local tool_ids = 0

-- A tool call of agent `id`, or of the main agent for nil.
local function use(id, name, tool_input)
  tool_ids = tool_ids + 1
  local tool_id = "focus_tool" .. tool_ids
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = name,
    input = tool_input,
    parent_id = id and "tu_" .. id or nil,
    agent_id = id,
  })
  return tool_id
end

local function read(id, path, offset)
  use(id, "Read", { file_path = path, offset = offset })
end

local function code_file()
  return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code))
end

local function code_line()
  return api.nvim_win_get_cursor(layout.wins.code)[1]
end

-- The prompt in normal mode, where follow mode follows. Entering it catches
-- up from the event loop.
local function prompt()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  transcript.clear()
end

describe("focus", function()
  local restore ---@type fun()?

  after_each(function()
    permission.cancel_all()
    agents.clear()
    follow.forget()
    local fn = restore
    restore = nil
    if fn then
      fn()
    end
  end)

  it("follows the focused agent only, and catches up at once on focus", function()
    fresh()
    local a, b, main = file("focus_a.lua"), file("focus_b.lua"), file("focus_main.lua")
    start("f1")
    start("f2")
    prompt()
    local before = code_file()
    read("f1", a, 2)
    assert.are.same(before, code_file(), "an agent without focus moves nothing")
    read(nil, main)
    assert.are.same(main, code_file(), "the main agent has the focus at first")
    follow.focus_slot(1)
    assert.are.same({ a, 2 }, { code_file(), code_line() }, "focus catches up")
    assert.are.same("f1", follow.focus)
    assert.are.same("◉ following Agent 1", follow.status())
    assert.are.same("◉ Agent 1", follow.status(true))
    assert.are.same("AnvimAgent1", follow.group())

    read("f2", b)
    read(nil, b)
    assert.are.same(a, code_file(), "other agents' moves leave the view alone")
    read("f1", b, 4)
    assert.are.same({ b, 4 }, { code_file(), code_line() })
    use("f1", "Edit", { file_path = a, old_string = "local c = 3", new_string = "local c = 30" })
    assert.are.same({ a, 3 }, { code_file(), code_line() }, "an edit shows its line")

    -- A Write of a new file shows once the file exists.
    local new = helpers.tmp .. "/focus_new.lua"
    os.remove(new)
    local id = use("f1", "Write", { file_path = new, content = "return 1" })
    assert.are.same(a, code_file())
    vim.fn.writefile({ "return 1" }, new)
    sidecar.dispatch({
      type = "tool_result",
      id = id,
      is_error = false,
      text = "ok",
      parent_id = "tu_f1",
      agent_id = "f1",
    })
    assert.are.same(new, code_file())

    follow.focus_slot(0)
    assert.is_nil(follow.focus)
    assert.are.same(b, code_file(), "the main agent's last place")
    assert.are.same("◉ following", follow.status())
    assert.are.same("AnvimClaude", follow.group())
    read("f1", a)
    assert.are.same(b, code_file())
  end)
end)
