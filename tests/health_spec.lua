---@module "luassert"

local helpers = require("helpers")

describe("health", function()
  it("runs :checkhealth anvim without errors", function()
    vim.cmd("silent tab checkhealth anvim")
    local out = helpers.buf_lines(0)
    vim.cmd("bwipeout")
    helpers.contains(out, "^anvim:")
    helpers.contains(out, "OK Neovim")
    for _, line in ipairs(out) do
      assert(not line:find("Failed to run healthcheck", 1, true), table.concat(out, "\n"))
    end
  end)
end)
