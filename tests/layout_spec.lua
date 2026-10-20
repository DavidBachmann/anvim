---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local transcript = require("anvim.transcript")

describe("layout", function()
  it("has code, transcript and input windows", function()
    local win = helpers.start()
    for _, role in ipairs({ "code", "transcript", "input" }) do
      assert(vim.api.nvim_win_is_valid(layout.wins[role]), role .. " window missing")
    end
    assert.are.same(transcript.buf(), vim.api.nvim_win_get_buf(layout.wins.transcript))
    assert.are.same(input.buf(), vim.api.nvim_win_get_buf(layout.wins.input))
    assert.are.same(layout.wins.input, win, "start focuses the input")
  end)

  it("grows the prompt with its lines, and keeps the footer under the last one", function()
    helpers.start()
    local buf, win = input.buf(), layout.wins.input
    local function footer_row()
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        if mark[4].virt_lines then
          return mark[2]
        end
      end
    end
    assert.are.same(3, vim.api.nvim_win_get_height(win), "one line, the footer and the winbar")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
    input.render()
    assert.are.same(5, vim.api.nvim_win_get_height(win))
    assert.are.same(2, footer_row())
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(("x\n"):rep(30), "\n"))
    input.render()
    assert.are.same(13, vim.api.nvim_win_get_height(win), "at most 12 rows and the winbar")
    vim.api.nvim_win_set_cursor(win, { 31, 0 })
    input.show_footer()
    local showmode = vim.o.showmode
    vim.o.showmode = false
    vim.cmd.redraw()
    vim.o.showmode = showmode
    local shown = vim.api.nvim_win_text_height(win, { start_row = vim.fn.line("w0", win) - 1 }).all
    assert(shown <= 12, ("the footer is out of view: %d rows from the top line"):format(shown))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    input.render()
    assert.are.same(3, vim.api.nvim_win_get_height(win))
    assert.are.same(0, footer_row())
  end)
end)
