---@module "luassert"

local compose = require("anvim.compose")
local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")

local api = vim.api

local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "mxt", false)
  vim.wait(20)
end

local function prompt(lines)
  if lines then
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, lines)
  end
  return helpers.buf_lines(input.buf())
end

-- The prompt has focus in normal mode, with lines and the cursor at pos.
local function in_prompt(lines, pos)
  helpers.start()
  vim.cmd.stopinsert()
  if compose.win() then
    api.nvim_win_close(compose.win(), true)
  end
  api.nvim_set_current_win(layout.wins.input)
  prompt(lines)
  api.nvim_win_set_cursor(0, pos)
  vim.wait(20)
end

local function compose_buf()
  return api.nvim_win_get_buf((assert(compose.win(), "no compose window")))
end

local function closed()
  return vim.wait(500, function()
    return compose.win() == nil
  end)
end

describe("compose", function()
  it("adds lines with Enter, puts the text in the prompt with :w, and :wq goes back in normal mode", function()
    in_prompt({ "hello world" }, { 1, 0 })
    helpers.capture_sends(function(sent)
      feed("<C-g>")
      feed("A<CR>second line<Esc>")
      assert.are.same({}, sent, "Enter sent the prompt")
    end)
    assert.are.same({ "hello world" }, prompt(), "the prompt changed before :w")
    feed(":w<CR>")
    assert.are.same({ "hello world", "second line" }, prompt())
    assert.is_false(vim.bo[compose_buf()].modified)
    feed("gg0wibig <Esc>")
    feed(":wq<CR>")
    assert.is_true(closed(), ":wq did not close the window")
    vim.wait(20)
    assert.are.same({ "hello big world", "second line" }, prompt())
    assert.are.same(layout.wins.input, api.nvim_get_current_win())
    assert.are.same({ 1, 9 }, api.nvim_win_get_cursor(0), "the cursor stays on the space after 'big'")
    assert.are.same("n", api.nvim_get_mode().mode)
  end)
end)
