---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local statusline = require("anvim.statusline")

local api = vim.api

-- The statusline's text, as Neovim draws it for the window.
local function text(win)
  return api.nvim_eval_statusline("%!v:lua.require'anvim.statusline'.render()", { winid = win, maxwidth = 300 }).str
end

describe("statusline", function()
  local before = vim.g.colors_name or "default"
  after_each(function()
    vim.cmd.colorscheme(before)
    statusline.error = nil
  end)

  it("names Vim's mode and the file in the code window, and FOLLOW without a file in the prompt", function()
    helpers.start()
    local file = helpers.tmp .. "/100%.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "return a" }, file)
    vim.cmd.stopinsert()
    api.nvim_set_current_win(layout.code_win())
    vim.cmd.edit(vim.fn.fnameescape(file))
    api.nvim_win_set_cursor(0, { 2, 6 })
    local code = text(0)
    assert(code:find("^ NORMAL "), code)
    assert(code:find(" 100%.lua ", 1, true), code)
    assert(code:find(" 66%%   2:7  $"), code)
    assert(not code:find("FOLLOW", 1, true), code)
    layout.focus_input({ insert = false })
    local prompt = text(layout.wins.input)
    assert(prompt:find("^ FOLLOW "), prompt)
    assert(not prompt:find("100%", 1, true), prompt)
    assert(not prompt:find(":%d"), prompt)
    assert.is_nil(statusline.error)
  end)

  it("leaves the busy label to the activity line, and shows a Write preview's real path with (writing)", function()
    helpers.start()
    input.set_busy(true)
    local ok, err = pcall(function()
      assert(not text(layout.wins.input):find("Working", 1, true), text(layout.wins.input))
      local buf = api.nvim_create_buf(false, true)
      vim.b[buf].anvim_preview = helpers.tmp .. "/made.lua"
      vim.bo[buf].filetype = "lua"
      local win = api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 2 })
      local writing = text(win)
      api.nvim_win_close(win, true)
      api.nvim_buf_delete(buf, { force = true })
      assert(writing:find(" made%.lua \238\130\177 %(writing%) "), writing)
      assert(not writing:find("Working", 1, true), writing)
    end)
    input.set_busy(false)
    assert(ok, err)
  end)
end)
