---@module "luassert"

local sidecar = require("anvim.sidecar")

describe("sidecar env", function()
  it("drops the variables that tie Claude's shell to this Neovim", function()
    local saved = { NVIM_APPNAME = vim.env.NVIM_APPNAME, NVIM_LOG_FILE = vim.env.NVIM_LOG_FILE }
    vim.env.NVIM_APPNAME = "anvim"
    vim.env.NVIM_LOG_FILE = "/tmp/anvim-nvim.log"
    local env = sidecar.env()
    for key, value in pairs(saved) do
      vim.env[key] = value
    end
    for _, key in ipairs({ "NVIM", "NVIM_APPNAME", "NVIM_LOG_FILE", "VIMRUNTIME" }) do
      assert.is_nil(env[key], key)
    end
    assert.are.same(vim.env.PATH, env.PATH)
  end)
end)
