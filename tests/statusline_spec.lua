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

local function get(name)
  local hl = api.nvim_get_hl(0, { name = name, link = false })
  return { fg = hl.fg, bg = hl.bg, bold = hl.bold }
end

local function brightness(n)
  return (bit.rshift(n, 16) * 2 + bit.band(bit.rshift(n, 8), 255) * 3 + bit.band(n, 255)) / 6 / 255
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

  it("takes its colors from the colorscheme, and keeps a group that the user set", function()
    helpers.start()
    for _, name in ipairs({ "habamax", "catppuccin", "default" }) do
      vim.cmd.colorscheme(name)
      -- None of them ships a lualine theme, so the mode and the branch must stand out by themselves.
      for _, group in ipairs({ "AnvimStatusNormal", "AnvimStatusInsert", "AnvimStatusNormalB", "AnvimStatusFollow" }) do
        local hl = get(group)
        assert(hl.fg and hl.bg, ("%s in %s: %s"):format(group, name, vim.inspect(hl)))
        local diff = math.abs(brightness(hl.fg) - brightness(hl.bg))
        assert(diff >= 0.3, ("%s in %s: %s"):format(group, name, vim.inspect(hl)))
      end
      assert(get("AnvimStatusC").bg, name)
      assert.are.same(get("AnvimClaude").fg, get("AnvimStatusFollow").bg, name)
      -- The statusline makes a diagnostic's group when it first shows one.
      local code = layout.code_win()
      local ns = api.nvim_create_namespace("statusline_spec")
      vim.diagnostic.set(ns, api.nvim_win_get_buf(code), { { lnum = 0, col = 0, message = "e", severity = 1 } })
      text(code)
      vim.diagnostic.reset(ns)
      assert.are.same(get("AnvimStatusC").bg, get("AnvimStatusCDiagnosticError").bg, name)
      assert.are.same(get("DiagnosticError").fg, get("AnvimStatusCDiagnosticError").fg, name)
      assert.are.same(get("AnvimStatusNormal").bg, get("AnvimStatusNormalAB").fg, name)
    end
    vim.cmd.colorscheme("habamax")
    local habamax = get("AnvimStatusInsert")
    vim.cmd.colorscheme("catppuccin")
    assert.are_not.same(habamax, get("AnvimStatusInsert"))
    -- Like tokyonight on its first load, which runs no :hi clear.
    api.nvim_set_hl(0, "AnvimStatusNormal", { fg = 0x123456, bg = 0x654321 })
    api.nvim_set_hl(0, "String", { fg = 0x22aa22 })
    api.nvim_exec_autocmds("ColorScheme", { pattern = "noclear" })
    assert.are.same({ fg = 0x123456, bg = 0x654321 }, get("AnvimStatusNormal"))
    assert.are.same(0x22aa22, get("AnvimStatusInsert").bg)
  end)

  it("draws an empty statusline instead of an error, and says why once", function()
    helpers.start()
    local count, notify = vim.diagnostic.count, vim.notify
    local notes = {}
    vim.diagnostic.count = function()
      error("boom")
    end
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local ok, out = pcall(text, layout.code_win())
    pcall(text, layout.code_win())
    vim.wait(100)
    vim.diagnostic.count, vim.notify = count, notify
    assert(ok, out)
    assert.are.same("", out)
    assert(statusline.error and statusline.error:find("boom", 1, true), statusline.error)
    assert.are.same(1, #notes, vim.inspect(notes))
    assert(notes[1]:find("boom", 1, true), notes[1])
  end)
end)
