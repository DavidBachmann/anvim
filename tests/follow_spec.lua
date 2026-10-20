---@module "luassert"

local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")

describe("follow", function()
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
    assert.are.same(vim.fn.bufnr(file), vim.api.nvim_win_get_buf(layout.wins.code), "focusing the input catches up")
    assert.are.same(3, vim.api.nvim_win_get_cursor(layout.wins.code)[1])
    assert.are.same("◉ following", follow.status())
  end)
end)
