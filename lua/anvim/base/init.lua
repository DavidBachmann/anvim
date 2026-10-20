-- anvim's base editor: the options, keys and plugins under the anvim layout.
local M = {}

-- An empty value counts as unset, as in the shell's ${VAR:-default}.
local function env(name)
  local value = vim.env[name]
  return value ~= "" and value or nil
end

-- Plugins, treesitter parsers and mason packages live here, apart from the
-- main Neovim's. Tests point it at a dir that they prepare. bin/anvim and
-- scripts/install name the same dir.
M.dir = vim.fs.normalize(vim.fs.abspath(env("ANVIM_INSTALL_DIR") or vim.fn.stdpath("data")))

-- lazy.nvim's lockfile, which it rewrites after each install and update. The
-- repo's lockfile holds anvim's pins, and only scripts/update-plugins writes
-- it, through this variable.
M.lockfile = vim.fs.normalize(vim.fs.abspath(env("ANVIM_LOCKFILE") or M.dir .. "/lazy-lock.json"))

-- ANVIM_NO_INSTALL=1 turns off every install at start.
M.install = vim.env.ANVIM_NO_INSTALL ~= "1"

-- stylua: ignore
M.icons = {
  diagnostics = {
    Error = " ",
    Warn  = " ",
    Hint  = " ",
    Info  = " ",
  },
  git = {
    added    = " ",
    modified = " ",
    removed  = " ",
  },
}

return M
