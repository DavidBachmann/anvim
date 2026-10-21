local base = require("anvim.base")
local config = require("anvim.config")
local install = require("anvim.base.install")
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

local run_install = "Run `scripts/install` in " .. install.root

---@param tools { [1]: string, [2]: string, error?: boolean }[] Each tool, what anvim needs it for, and whether it must exist.
local function executables(tools)
  for _, tool in ipairs(tools) do
    local path = vim.fn.exepath(tool[1])
    if path ~= "" then
      health.ok(("`%s`: %s"):format(tool[1], path))
    else
      local report = tool.error and health.error or health.warn
      report(("`%s` is not on PATH. %s"):format(tool[1], tool[2]))
    end
  end
end

-- The sidecar's own pre-check, so that the answer matches its warning.
---@return boolean ran
---@return string? problem Why the sandbox cannot start here.
local function sandbox_problem()
  local ok, obj = pcall(function()
    return vim.system({ config.options.bun, sidecar.dir .. "/src/sandbox.ts" }, { text = true }):wait(5000)
  end)
  if not (ok and obj.code == 0) then
    return false
  end
  local problem = vim.trim(obj.stdout or "")
  return true, problem ~= "" and problem or nil
end

local function sandbox()
  local ran, problem = sandbox_problem()
  if config.options.sandbox == false then
    health.info(
      vim.env.ANVIM_SANDBOX == "0" and "The sandbox is off, because anvim started with --no-sandbox or ANVIM_SANDBOX=0"
        or "The sandbox is off, because a spec sets `sandbox = false`"
    )
    if ran then
      health.info(problem and ("It could not start here: " .. problem) or "It could start here")
    end
    return
  end
  if not ran then
    health.warn("The sandbox is on, but its pre-check could not run")
  elseif problem then
    health.warn(
      ("The sandbox is on, but it cannot start: %s. Claude's Bash commands run without it."):format(problem),
      { "Install what is missing, or start anvim with --no-sandbox" }
    )
  else
    health.ok("The sandbox is on: Claude's Bash commands can write only in the project and a temp dir")
  end
end

function M.check()
  health.start("anvim")

  if vim.fn.has("nvim-0.12") == 1 then
    health.ok(("Neovim %s"):format(tostring(vim.version())))
  else
    health.error("anvim needs Neovim 0.12 or newer")
  end

  if vim.env.NVIM_APPNAME == "anvim" then
    health.ok("NVIM_APPNAME is anvim")
  else
    health.error(
      "NVIM_APPNAME is not anvim, so stdpath() names another Neovim's dirs",
      { "Start anvim with bin/anvim" }
    )
  end
  health.info("Install dir: " .. base.dir)

  local ok, check = pcall(function()
    return vim
      .system({ install.root .. "/scripts/install", "--check" }, { env = { ANVIM_INSTALL_DIR = base.dir } })
      :wait(5000)
  end)
  if ok and check.code == 0 then
    health.ok("The install matches the repo's lockfiles and its lists of mason packages and parsers")
  else
    health.warn("The install does not match the repo's lockfiles, or its lists of mason packages and parsers", {
      run_install,
    })
  end

  local specs = vim.fn.stdpath("config") .. "/lua/plugins"
  if vim.uv.fs_stat(specs) then
    health.info("Personal specs: " .. specs)
  else
    health.info("No personal specs in " .. specs)
  end

  local bun = config.options.bun
  if vim.fn.executable(bun) == 1 then
    health.ok(("`%s` %s"):format(bun, version({ bun, "--version" }) or "(unknown version)"))
  else
    health.error(("`%s` is not on PATH"):format(bun), { "Install Bun from https://bun.sh" })
  end

  if vim.uv.fs_stat(sidecar.dir .. "/node_modules") then
    health.ok("Sidecar dependencies are installed")
  else
    health.warn(
      "Sidecar dependencies are missing. anvim installs them from sidecar/bun.lock on start.",
      { run_install }
    )
  end

  -- The Agent SDK runs its own Claude Code binary from a per-platform package.
  -- It does not use a `claude` on PATH.
  local claude = vim.fn.glob(sidecar.dir .. "/node_modules/@anthropic-ai/claude-agent-sdk-*/claude", true, true)[1]
  if claude and vim.fn.executable(claude) == 1 then
    health.ok(
      ("Claude Code %s, bundled with the Agent SDK"):format(version({ claude, "--version" }) or "(unknown version)")
    )
  else
    health.error("The Agent SDK has no Claude Code binary", { run_install })
  end

  sandbox()

  executables({
    { "git", "lazy.nvim installs the plugins with it.", error = true },
    { "rg", "Grep needs ripgrep." },
    { "cc", "The treesitter parsers need a C compiler." },
    { "node", "The TypeScript and JSON language servers need Node.js." },
    { "npm", "mason installs the TypeScript and JSON language servers with npm." },
  })

  for _, pkg in ipairs(install.packages) do
    if vim.uv.fs_stat(base.dir .. "/mason/packages/" .. pkg.name) then
      health.ok(("mason package `%s` is installed"):format(pkg.name))
    else
      health.warn(("mason package `%s` is missing"):format(pkg.name), { run_install })
    end
  end
  -- mason puts its bin dir on PATH only once it loads.
  local cli = vim.fn.exepath("tree-sitter")
  if cli == "" and vim.fn.executable(base.dir .. "/mason/bin/tree-sitter") == 1 then
    cli = base.dir .. "/mason/bin/tree-sitter"
  end
  if cli ~= "" then
    health.ok("tree-sitter CLI: " .. cli)
  else
    health.warn("The tree-sitter CLI is missing, so no parser can install", { run_install })
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
