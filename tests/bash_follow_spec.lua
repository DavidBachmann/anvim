---@module "luassert"

local agents = require("anvim.agents")
local bashread = require("anvim.bashread")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local trail = require("anvim.trail")

local api = vim.api

local function file(name, n)
  local lines = {}
  for i = 1, n or 12 do
    lines[i] = ("local x%d = %d"):format(i, i)
  end
  local path = helpers.tmp .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local tool_ids = 0

-- A Bash call of agent `id`, or of the main agent for nil. Returns its id.
local function bash(command, id, input, tool_id)
  tool_ids = tool_ids + 1
  tool_id = tool_id or "bash_tool" .. tool_ids
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = "Bash",
    input = vim.tbl_extend("force", { command = command, description = "Read" }, input or {}),
    parent_id = id and "tu_" .. id or nil,
    agent_id = id,
  })
  return tool_id
end

local function result(tool_id, stdout, id)
  sidecar.dispatch({
    type = "tool_result",
    id = tool_id,
    is_error = false,
    text = stdout,
    -- A subagent's result has no tool_use_result.
    result = not id and { stdout = stdout, stderr = "", interrupted = false } or nil,
    parent_id = id and "tu_" .. id or nil,
    agent_id = id,
  })
end

local function code_file()
  return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code))
end

local function code_line()
  return api.nvim_win_get_cursor(layout.wins.code)[1]
end

-- The 1-based lines of a buffer that flash as read.
local function flashed(path)
  local ns = api.nvim_get_namespaces()["anvim.follow"]
  local lines = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(vim.fn.bufnr(path), ns, 0, -1, { details = true })) do
    if mark[4].line_hl_group == "AnvimRead" then
      lines[#lines + 1] = mark[2] + 1
    end
  end
  table.sort(lines)
  return lines
end

-- The prompt in normal mode, where follow mode follows.
local function prompt()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

local function elsewhere()
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.wins.code)
end

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  bashread.forget()
end

describe("bash reads", function()
  after_each(function()
    agents.clear()
    follow.forget()
    vim.cmd.stopinsert()
  end)

  it("show a file that Claude reads with cat as a Read does, and only point at it elsewhere", function()
    fresh()
    local a, b = file("bash_a.lua"), file("bash_b.lua")
    prompt()
    bash("cat bash_a.lua")
    assert.are.same({ a, 1 }, { code_file(), code_line() })
    assert.are.same({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, flashed(a))

    elsewhere()
    bash("cd " .. helpers.tmp .. " && sed -n 3,4p bash_b.lua 2>/dev/null")
    assert.are.same(a, code_file(), "the user is in control")
    assert.are.same("⏺ Claude at bash_b.lua:3 +1", follow.status())
    prompt()
    assert(
      vim.wait(1000, function()
        return code_file() == b
      end),
      "entering the prompt did not catch up"
    )
    assert.are.same(3, code_line())

    local items = trail.items()
    assert.are.same("Read bash_b.lua#L3-4", items[1].text)
    assert.are.same("Read bash_a.lua", items[2].text)
  end)

  it("show a grep's first hit and flash its file's hits, at the tool result", function()
    fresh()
    local g = file("bash_g.lua", 40)
    local other = file("bash_g_other.lua")
    prompt()
    local before = code_file()
    local id = bash("grep -n x bash_g.lua | head -20")
    assert.are.same(before, code_file(), "a grep moves nothing before its result")
    result(id, "3:local x3 = 3\n7:local x7 = 7\n39:local x39 = 39\n")
    assert.are.same({ g, 3 }, { code_file(), code_line() })
    assert.are.same({ 3, 7 }, flashed(g), "the hits in view flash")

    id = bash("grep -rn x . ; echo ---")
    result(id, "bash_g_other.lua:5:local x5 = 5\nbash_g.lua:9:local x9 = 9\n---\n")
    assert.are.same({ other, 5 }, { code_file(), code_line() })
    assert.are.same({ 5 }, flashed(other))

    elsewhere()
    id = bash("grep -n x bash_g.lua")
    result(id, "12:local x12 = 12")
    assert.are.same(other, code_file())
    assert.are.same("⏺ Claude at bash_g.lua:12 +1", follow.status())
  end)
end)
