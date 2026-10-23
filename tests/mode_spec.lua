---@module "luassert"

local compose = require("anvim.compose")
local follow = require("anvim.follow")
local helpers = require("helpers")
local keyview = require("anvim.keyview")
local layout = require("anvim.layout")

local api = vim.api

---@type integer
local changes = 0
api.nvim_create_autocmd("User", {
  pattern = "AnvimMode",
  callback = function()
    changes = changes + 1
  end,
})

local file = helpers.tmp .. "/mode.lua"
local other = helpers.tmp .. "/mode_other.lua"

-- The gutter of a window, by default the code window.
local function numbers(win)
  local wo = vim.wo[win or layout.wins.code]
  return {
    number = wo.number,
    relativenumber = wo.relativenumber,
    statuscolumn = wo.statuscolumn,
    signcolumn = wo.signcolumn,
  }
end

-- The bare specs run without snacks' statuscolumn. Their files have fewer
-- than 1000 lines, so review's columns are 4 for the numbers and 2 for a sign.
local NONE = {
  number = false,
  relativenumber = false,
  statuscolumn = "%@v:lua.require'anvim.follow'.click_gutter@  %s%T",
  signcolumn = "yes:2",
}
local REVIEW = { number = true, relativenumber = true, statuscolumn = "", signcolumn = "yes" }

local function to_code(path)
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.wins.code)
  if path then
    vim.cmd.edit(path)
  end
end

local function to_prompt()
  layout.focus_input({ insert = false })
end

local function fresh()
  helpers.start()
  if compose.win() then
    api.nvim_win_close(compose.win(), true)
  end
  keyview.close()
  vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a" }, file)
  vim.fn.writefile({ "return 'other'" }, other)
  to_code(file)
end

-- Windows that a case opened, which the next cases must not see.
---@type integer[]
local extra = {}

describe("mode", function()
  after_each(function()
    for _, win in ipairs(extra) do
      pcall(api.nvim_win_close, win, true)
    end
    extra = {}
    vim.cmd.stopinsert()
  end)

  it("is follow in the prompt and review in the code window, with numbers only in review", function()
    fresh()
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
    to_prompt()
    assert.are.same("follow", follow.mode())
    assert.are.same(NONE, numbers())
    to_code()
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
  end)

  it("gives follow mode a gutter as wide as review's, which keeps its width while the buffer grows", function()
    fresh()
    local code = layout.wins.code
    -- Without a UI nothing draws, so only Neovim's own columns have a width.
    local function review()
      return vim.fn.getwininfo(code)[1].textoff
    end
    assert.are.same(review(), follow.review_width(code))
    for _, wo in ipairs({ { numberwidth = 6 }, { foldcolumn = "1" } }) do
      for name, value in pairs(wo) do
        vim.wo[code][name] = value
      end
      assert.are.same(review(), follow.review_width(code), vim.inspect(wo))
      vim.wo[code].numberwidth, vim.wo[code].foldcolumn = 4, "0"
    end
    to_prompt()
    local gutter = vim.wo[code].statuscolumn
    assert.are.same(NONE.statuscolumn, gutter)
    -- A preview that writes 1000 lines and more, while following.
    local buf = api.nvim_win_get_buf(code)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(("x\n"):rep(1200), "\n"))
    vim.bo[buf].modifiable = false
    vim.cmd.doautocmd("SafeState")
    assert.are.same(gutter, vim.wo[code].statuscolumn)
    to_code()
    assert.are.same(7, review())
    assert.are.same(review(), follow.review_width(code))
    to_prompt()
    assert.are.same("%@v:lua.require'anvim.follow'.click_gutter@   %s%T", vim.wo[code].statuscolumn)
    to_code()
    vim.cmd.edit({ bang = true })
  end)
end)
