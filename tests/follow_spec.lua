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
