-- anvim: a read-only Neovim for watching Claude work. Start it with bin/anvim.
-- It boots LazyVim with the user's own config and plugins, then adds anvim.
local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

-- The user's main Neovim. anvim reads its config, plugins, parsers and tools,
-- and never writes them at startup. `:Lazy update` in anvim updates the shared
-- plugins and lockfile, as in the main Neovim. anvim's own state, cache and
-- logs stay under NVIM_APPNAME.
local home = assert(vim.env.HOME, "anvim needs $HOME")
local nvim_config = home .. "/.config/nvim"
local nvim_data = home .. "/.local/share/nvim"

-- The same imports and disabled runtime plugins as the user's lazy.lua.
local boot = dofile(root .. "/lua/anvim/boot.lua")
local lazy_lua = boot.read(nvim_config .. "/lua/config/lazy.lua")
local spec = { { "LazyVim/LazyVim", import = "lazyvim.plugins" } }
for _, name in ipairs(boot.imports(lazy_lua)) do
  if name ~= "lazyvim.plugins" then
    spec[#spec + 1] = { import = name }
  end
end
vim.list_extend(spec, {
  -- Share the parsers and tools, but leave installing them to the main Neovim.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.install_dir = nvim_data .. "/site"
      opts.ensure_installed = {}
    end,
  },
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.install_root_dir = nvim_data .. "/mason"
      opts.ensure_installed = {}
      opts.registry_cache = { refresh = false }
    end,
  },
  -- lua-language-server writes its logs and generated files into its own
  -- install dir, unless told otherwise.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        lua_ls = {
          cmd = {
            "lua-language-server",
            "--logpath=" .. vim.fn.stdpath("log") .. "/lua_ls",
            "--metapath=" .. vim.fn.stdpath("cache") .. "/lua_ls/meta",
          },
        },
      },
    },
  },
  { dir = root, name = "anvim", import = "anvim.plugins" },
})

-- LazyVim writes news and version state to lazyvim.json. anvim reads the
-- user's extras from a fresh copy, so it never writes the user's file.
local json = vim.fn.stdpath("state") .. "/lazyvim.json"
vim.fn.mkdir(vim.fs.dirname(json), "p")
os.remove(json)
vim.uv.fs_copyfile(nvim_config .. "/lazyvim.json", json)
vim.g.lazyvim_json = json

vim.opt.rtp:prepend(nvim_data .. "/lazy/lazy.nvim")
require("lazy").setup({
  spec = spec,
  root = nvim_data .. "/lazy",
  lockfile = nvim_config .. "/lazy-lock.json",
  defaults = { lazy = false, version = false },
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  performance = { rtp = { paths = { nvim_config }, disabled_plugins = boot.disabled_plugins(lazy_lua) } },
})
