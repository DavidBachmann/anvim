---@module "luassert"

local config = require("anvim.config")
local helpers = require("helpers")

local function checkhealth()
  vim.cmd("silent tab checkhealth anvim")
  local out = helpers.buf_lines(0)
  vim.cmd("bwipeout")
  return out
end

-- Runs fn with these config options and environment, and puts them back.
local function with(opts, env, fn)
  local old_opts, old_env = {}, {}
  for key, value in pairs(opts) do
    old_opts[key], config.options[key] = config.options[key], value
  end
  for key, value in pairs(env) do
    old_env[key], vim.env[key] = vim.env[key], value
  end
  local ok, err = pcall(fn)
  for key in pairs(opts) do
    config.options[key] = old_opts[key]
  end
  for key in pairs(env) do
    vim.env[key] = old_env[key]
  end
  assert(ok, err)
end

describe("health", function()
  it("runs :checkhealth anvim without errors", function()
    local out = checkhealth()
    helpers.contains(out, "^anvim:")
    helpers.contains(out, "OK Neovim")
    for _, line in ipairs(out) do
      assert(not line:find("Failed to run healthcheck", 1, true), table.concat(out, "\n"))
    end
  end)

  it("reports the sandbox, and why it is off", function()
    with({ sandbox = true }, {}, function()
      helpers.contains(checkhealth(), "OK The sandbox is on: Claude's Bash commands can write only in the project")
    end)
    with({ sandbox = false }, { ANVIM_SANDBOX = "0" }, function()
      local out = checkhealth()
      helpers.contains(out, "The sandbox is off, because anvim started with %-%-no%-sandbox or ANVIM_SANDBOX=0")
      helpers.contains(out, "It could start here")
    end)
    with({ sandbox = false }, { ANVIM_SANDBOX = "" }, function()
      helpers.contains(checkhealth(), "The sandbox is off, because a spec sets `sandbox = false`")
    end)
  end)

  it("warns when the sidecar's pre-check finds the sandbox cannot start", function()
    -- A bun whose pre-check answers as on a Linux without bubblewrap.
    local bun = helpers.tmp .. "/health-bun"
    vim.fn.writefile({
      "#!/bin/sh",
      [[case "$1" in */sandbox.ts) echo "bwrap is not on PATH (install bubblewrap)" ;; *) echo 1.0.0 ;; esac]],
    }, bun)
    vim.fn.setfperm(bun, "rwxr-xr-x")
    with({ sandbox = true, bun = bun }, {}, function()
      local out = checkhealth()
      helpers.contains(
        out,
        "WARNING The sandbox is on, but it cannot start: bwrap is not on PATH %(install bubblewrap%)"
      )
      helpers.contains(out, "start anvim with %-%-no%-sandbox")
    end)
  end)
end)
