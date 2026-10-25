---@module "luassert"

local helpers = require("helpers")
local history = require("anvim.history")
local input = require("anvim.input")
local layout = require("anvim.layout")

local api = vim.api

local function keys(str)
  api.nvim_feedkeys(api.nvim_replace_termcodes(str, true, false, true), "mx", false)
end

local function prompt()
  return table.concat(api.nvim_buf_get_lines(input.buf(), 0, -1, false), "\n")
end

local function focus()
  api.nvim_set_current_win(layout.wins.input)
  vim.cmd.stopinsert()
end

-- Submits prompts the way <CR> does, without waiting for the turns. The
-- replay plays one recorded turn per prompt, so the specs stub the send.
-- Each turn ends before the next submit, or the next prompt would queue.
local function submit_all(list)
  helpers.capture_sends(function()
    for _, text in ipairs(list) do
      api.nvim_buf_set_lines(input.buf(), 0, -1, false, vim.split(text, "\n"))
      input.submit()
      input.set_busy(false)
    end
  end)
end

describe("history", function()
  before_each(function()
    helpers.start()
    vim.fn.delete(history.dir, "rf")
    -- A submit forgets where the last spec left off.
    submit_all({ "reset" })
    vim.fn.delete(history.dir, "rf")
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("cycles with <Up> on the first line and <Down> on the last, and keeps the draft", function()
    focus()
    submit_all({ "first prompt", "second\nprompt on two lines", "third" })
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "my draft" })
    keys("A<Up>")
    assert.are.same("third", prompt())
    keys("A<Up>")
    assert.are.same("second\nprompt on two lines", prompt())
    -- The cursor ends on the first line, so the next <Up> goes back again.
    assert.are.same(1, api.nvim_win_get_cursor(0)[1])
    keys("A<Up>")
    assert.are.same("first prompt", prompt())
    keys("A<Up>")
    assert.are.same("first prompt", prompt(), "the oldest prompt stays")
    keys("A<Down>")
    assert.are.same("second\nprompt on two lines", prompt())
    -- <Down> lands on the last line, so the next <Down> comes forward again.
    assert.are.same(2, api.nvim_win_get_cursor(0)[1])
    keys("A<Down><Down>")
    assert.are.same("my draft", prompt(), "past the newest prompt, the draft comes back")
  end)

  it("reads the file again, so two anvims in one directory keep both their prompts", function()
    submit_all({ "from this anvim" })
    local other = vim.json.decode(table.concat(vim.fn.readfile(history.path()), "\n"))
    other[#other + 1] = "from another anvim"
    vim.fn.writefile({ vim.json.encode(other) }, history.path())
    submit_all({ "again from this one" })
    local saved = vim.json.decode(table.concat(vim.fn.readfile(history.path()), "\n"))
    assert.are.same({ "from this anvim", "from another anvim", "again from this one" }, saved)
  end)
end)
