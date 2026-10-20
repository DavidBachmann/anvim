---@module "luassert"

local boot = require("anvim.boot")
local helpers = require("helpers")

local n = 0
local function parse(text)
  n = n + 1
  local path = ("%s/lazy%d.lua"):format(helpers.tmp, n)
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  return boot.read(path)
end

describe("boot", function()
  it("reads the imports of a lazy.lua in order", function()
    local text = parse([[
require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = 'lazyvim.plugins.extras.lang.go' },
    {import="plugins"},
  },
})
]])
    assert.are.same({ "lazyvim.plugins", "lazyvim.plugins.extras.lang.go", "plugins" }, boot.imports(text))
  end)

  it("skips commented and disabled imports", function()
    local text = parse([==[
-- { import = "lazyvim.plugins.extras.lang.go" },
{ import = "lazyvim.plugins.extras.lang.rust" }, -- { import = "x.y" }
--[[
{ import = "lazyvim.plugins.extras.lang.java" },
]]
--[=[ { import = "lazyvim.plugins.extras.lang.zig" } ]=]
{ import = "lazyvim.plugins.extras.lang.php", enabled = false },
{ import = "lazyvim.plugins.extras.lang.ruby", cond = function() return false end },
{ "foo/bar", url = "https://x--y" }, { import = "plugins" },
]==])
    assert.are.same({ "lazyvim.plugins.extras.lang.rust", "plugins" }, boot.imports(text))
  end)

  it("falls back to LazyVim and plugins when lazy.lua is missing", function()
    local text = boot.read(helpers.tmp .. "/missing.lua")
    assert.are.same("", text)
    assert.are.same({ "lazyvim.plugins", "plugins" }, boot.imports(text))
    assert.are.same({}, boot.disabled_plugins(text))
  end)

  it("reads the disabled runtime plugins", function()
    local text = parse([[
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip",
        -- "matchit",
        "tarPlugin",
        'tohtml',
      },
    },
  },
]])
    assert.are.same({ "gzip", "tarPlugin", "tohtml" }, boot.disabled_plugins(text))
  end)
end)
