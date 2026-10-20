-- anvim's base editor: the options, keys and plugins under the anvim layout.
local M = {}

-- Plugins, treesitter parsers and mason packages live here, apart from the
-- main Neovim's. Tests point it at a dir that they prepare.
M.dir = vim.fs.normalize(vim.fs.abspath(vim.env.ANVIM_INSTALL_DIR or vim.fn.stdpath("data")))

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
