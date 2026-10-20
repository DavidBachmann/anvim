local config = require("anvim.config")
local sidecar = require("anvim.sidecar")

local M = {}

local health = vim.health

---@return string? version The first word that cmd prints, or nil if it fails.
local function version(cmd)
  local ok, obj = pcall(function()
    return vim.system(cmd, { text = true }):wait(5000)
  end)
  if ok and obj.code == 0 then
    return obj.stdout:match("%S+")
  end
end

function M.check()
  health.start("anvim")

  if vim.fn.has("nvim-0.12") == 1 then
    health.ok(("Neovim %s"):format(tostring(vim.version())))
  else
    health.error("anvim needs Neovim 0.12 or newer")
  end

  local bun = config.options.bun
  if vim.fn.executable(bun) == 1 then
    health.ok(("`%s` %s"):format(bun, version({ bun, "--version" }) or "(unknown version)"))
  else
    health.error(("`%s` is not on PATH"):format(bun), { "Install Bun from https://bun.sh" })
  end

  local install = ("Run `bun install` in %s"):format(sidecar.dir)
  if vim.uv.fs_stat(sidecar.dir .. "/node_modules") then
    health.ok("Sidecar dependencies are installed")
  else
    health.warn("Sidecar dependencies are missing. anvim installs them on start.", { install })
  end

  -- The Agent SDK runs its own Claude Code binary from a per-platform package.
  -- It does not use a `claude` on PATH.
  local claude = vim.fn.glob(sidecar.dir .. "/node_modules/@anthropic-ai/claude-agent-sdk-*/claude", true, true)[1]
  if claude and vim.fn.executable(claude) == 1 then
    health.ok(
      ("Claude Code %s, bundled with the Agent SDK"):format(version({ claude, "--version" }) or "(unknown version)")
    )
  else
    health.error("The Agent SDK has no Claude Code binary", { install })
  end

  local chrome = vim.env.CHROME or "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  if vim.fn.executable(chrome) == 1 then
    health.ok("Google Chrome is installed, for the screen tool")
  else
    health.warn("Google Chrome is missing. Only the screen tool needs it.", { "Set CHROME to the Chrome binary" })
  end

  health.info("Log: " .. sidecar.log_path)
end

return M
