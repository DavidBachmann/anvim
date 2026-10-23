---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

describe("input", function()
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

  it("keeps its gutter and activity line out of a float that opens from it, as a picker's preview", function()
    helpers.start()
    require("anvim.layout").focus_input({ insert = false })
    local buf = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
    vim.api.nvim_win_set_buf(float, vim.api.nvim_create_buf(false, true))
    local stc, winbar = vim.wo[float].statuscolumn, vim.wo[float].winbar
    vim.api.nvim_win_close(float, true)
    assert.are.same("", stc)
    assert.are.same("", winbar)
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
