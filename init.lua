-- anvim: a read-only Neovim for watching Claude work. Start it with bin/anvim.
-- It boots lazy.nvim with anvim's own plugins, which it installs into its own
-- dir at the versions in the repo's lockfile. Nothing of the main Neovim's
-- config, plugins, parsers or tools is read or written.
local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

-- Shows the error, and exits once the user has read it.
local function fail(chunks)
  local ui = #vim.api.nvim_list_uis() > 0
  chunks[#chunks + 1] = { ui and "\nPress any key to exit..." or "\n" }
  vim.api.nvim_echo(chunks, true, {})
  if ui then
    vim.fn.getchar()
  end
  os.exit(1)
end

-- Without it, stdpath() names the main Neovim's dirs, and anvim would install
-- its plugins there and import the main Neovim's specs.
if vim.env.NVIM_APPNAME ~= "anvim" then
  fail({ { "anvim needs NVIM_APPNAME=anvim. Start it with bin/anvim.", "ErrorMsg" } })
end

-- The base modules load before lazy.nvim does.
vim.opt.rtp:prepend(root)
local base = require("anvim.base")
require("anvim.base.options")
require("anvim.base.autocmds")

local lazypath = base.dir .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local out =
    vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", lazypath })
  if vim.v.shell_error ~= 0 then
    fail({ { "Failed to clone lazy.nvim:\n", "ErrorMsg" }, { out, "WarningMsg" } })
  end
  -- The lockfile's commit, as for every other plugin.
  local ok, lock = pcall(vim.json.decode, table.concat(vim.fn.readfile(root .. "/lazy-lock.json"), "\n"))
  local commit = ok and lock["lazy.nvim"] and lock["lazy.nvim"].commit
  if commit then
    out = vim.fn.system({ "git", "-C", lazypath, "checkout", "--quiet", commit })
    if vim.v.shell_error ~= 0 then
      vim.fn.delete(lazypath, "rf")
      fail({ { "Failed to check out lazy.nvim:\n", "ErrorMsg" }, { out, "WarningMsg" } })
    end
  end
end
vim.opt.rtp:prepend(lazypath)

-- lazy.nvim resets the runtimepath before it reads the spec, and finds the
-- imports below in the dirs of the plugins declared before them.
local spec = {
  { "folke/lazy.nvim" },
  { dir = root, name = "anvim" },
  { import = "anvim.base.plugins" },
  { import = "anvim.plugins" },
}
-- Personal specs, such as a colorscheme, in ~/.config/anvim/lua/plugins.
if vim.uv.fs_stat(vim.fn.stdpath("config") .. "/lua/plugins") then
  spec[#spec + 1] = { import = "plugins" }
end

require("lazy").setup({
  spec = spec,
  root = base.dir .. "/lazy",
  lockfile = root .. "/lazy-lock.json",
  defaults = { lazy = false, version = false },
  -- For its window, an install at start loads the first colorscheme here that
  -- it can, and lazy.nvim adds habamax at the end. "default" ends the search
  -- before habamax, so tokyonight still loads below.
  install = { missing = base.install, colorscheme = { "tokyonight", "default" } },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
  performance = {
    -- netrw's D, R, d and % delete, rename and create files. snacks' explorer
    -- opens directories instead.
    rtp = { disabled_plugins = { "gzip", "netrwPlugin", "tarPlugin", "tohtml", "tutor", "zipPlugin" } },
  },
})

-- A personal spec may have set a colorscheme already.
if not vim.g.colors_name then
  pcall(vim.cmd.colorscheme, "tokyonight")
end

-- The keys use snacks, and load with the other plugins that wait for the UI.
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("anvim.base.keymaps", { clear = true }),
  pattern = "VeryLazy",
  once = true,
  callback = function()
    require("anvim.base.keymaps")
  end,
})
