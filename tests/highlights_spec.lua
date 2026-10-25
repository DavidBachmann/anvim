---@module "luassert"

local helpers = require("helpers")

local function get(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- The colors, without the cterm and default fields.
local function colors(name)
  local hl = get(name)
  return { fg = hl.fg, bg = hl.bg, strikethrough = hl.strikethrough }
end

describe("highlights", function()
  local before = vim.g.colors_name or "default"
  after_each(function()
    vim.cmd.colorscheme(before)
  end)

  -- Like tokyonight on its first load, which sets its groups over the old ones.
  local function without_clear(comment, delete)
    vim.api.nvim_set_hl(0, "Comment", { fg = comment })
    vim.api.nvim_set_hl(0, "DiffDelete", { bg = delete })
    vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "noclear" })
  end

  local function assert_follow(what)
    assert.are.same({ fg = get("Comment").fg, strikethrough = true }, colors("AnvimTodoDone"), what)
    assert.are.same({ bg = get("DiffDelete").bg, strikethrough = true }, colors("AnvimDelete"), what)
  end

  it("derive the struck-through groups from each colorscheme", function()
    helpers.start()
    -- Both ship with Neovim, and differ in Comment and DiffDelete.
    vim.cmd.colorscheme("habamax")
    assert_follow("habamax")
    local habamax = colors("AnvimDelete")
    vim.cmd.colorscheme("catppuccin")
    assert_follow("catppuccin")
    assert.are_not.same(habamax, colors("AnvimDelete"))
    without_clear(0x111111, 0x222222)
    assert_follow("a colorscheme without :hi clear")
    assert.are.same(0x222222, colors("AnvimDelete").bg)
  end)

  it("keep a group that the user set", function()
    helpers.start()
    vim.cmd.colorscheme("habamax")
    vim.api.nvim_set_hl(0, "AnvimDelete", { bg = 0x123456 })
    without_clear(0x111111, 0x222222)
    assert.are.same({ bg = 0x123456 }, colors("AnvimDelete"))
    assert.are.same({ fg = 0x111111, strikethrough = true }, colors("AnvimTodoDone"))
  end)

  it("give the tool pane the terminal's background, and its bar the code's", function()
    helpers.start()
    local layout = require("anvim.layout")
    layout.set_pane(true)
    assert.matches("Normal:AnvimPane,", vim.wo[layout.wins.pane].winhighlight, nil, true)
    vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgb:1919/1717/2424\7" } })
    assert.are.same(0x191724, get("AnvimPane").bg)
    local code = vim.api.nvim_win_call(layout.wins.code, function()
      return get("Normal")
    end)
    assert.are.same(code.bg, get("AnvimPaneWinBar").bg)
    layout.set_pane(false)
  end)

  it("give the Claude column the code's text, so that its times stand out", function()
    helpers.start()
    -- Neovim's own catppuccin gives floats the text color of comments.
    vim.cmd.colorscheme("catppuccin")
    local code = vim.api.nvim_win_call(require("anvim.layout").wins.code, function()
      return get("Normal")
    end)
    assert.are.same(code.fg, get("AnvimNormal").fg)
    assert.are_not.same(get("AnvimTime").fg, get("AnvimNormal").fg)
    assert.are.same(get("SnacksPickerList").bg, get("AnvimNormal").bg)
  end)
end)
