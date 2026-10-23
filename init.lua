-- anvim: a read-only Neovim for watching Claude work. Start it with bin/anvim.
-- It boots lazy.nvim with anvim's own plugins from its own install dir.
-- scripts/install puts them there at the versions in the repo's lockfile.
-- Nothing of the main Neovim's config, plugins, parsers or tools is read or
-- written.
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

if vim.fn.has("nvim-0.12") == 0 then
  local version = vim.fn.matchstr(vim.fn.execute("version"), [[NVIM \zsv\S\+]])
  fail({ { ("anvim needs Neovim 0.12 or newer, and this is %s."):format(version), "ErrorMsg" } })
end

-- The base modules load before lazy.nvim does.
vim.opt.rtp:prepend(root)
local base = require("anvim.base")
require("anvim.base.options")
require("anvim.base.autocmds")

-- Not vim.fn.system(): a headless Neovim that waits in it hangs on Ctrl-C.
local function git(args)
  return vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
end

local lazypath = base.dir .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local out = git({ "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", lazypath })
  if out.code ~= 0 then
    fail({ { "Failed to clone lazy.nvim:\n", "ErrorMsg" }, { out.stderr, "WarningMsg" } })
  end
  -- The lockfile's commit, as for every other plugin.
  local ok, lock = pcall(vim.json.decode, table.concat(vim.fn.readfile(root .. "/lazy-lock.json"), "\n"))
  local commit = ok and lock["lazy.nvim"] and lock["lazy.nvim"].commit
  if commit then
    out = git({ "-C", lazypath, "checkout", "--quiet", commit })
    if out.code ~= 0 then
      vim.fn.delete(lazypath, "rf")
      fail({ { "Failed to check out lazy.nvim:\n", "ErrorMsg" }, { out.stderr, "WarningMsg" } })
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

-- The install scripts start Neovim with --cmd 'let g:anvim_sync = 1'. The
-- repo's pins then go into the lockfile before lazy.nvim reads it, and
-- lazy.nvim installs the missing plugins at those pins as it starts.
-- Otherwise it would load no missing plugin, with an error for each.
local sync = vim.g.anvim_sync == 1
if sync then
  require("anvim.base.install").write_pins()
end

require("lazy").setup({
  spec = spec,
  root = base.dir .. "/lazy",
  -- lazy.nvim writes its lockfile after every install and update, and adds
  -- the plugins of personal specs. So it lives in the install dir, and the
  -- repo's lockfile only feeds it (lua/anvim/base/install.lua).
  lockfile = base.lockfile,
  defaults = { lazy = false, version = false },
  -- For its window, an install at start loads the first colorscheme here that
  -- it can, and lazy.nvim adds habamax at the end. "default" ends the search
  -- before habamax, so tokyonight still loads below.
  install = { missing = base.install or sync, colorscheme = { "tokyonight", "default" } },
  -- The install scripts print their own progress lines, and the errors of
  -- lazy.nvim's tasks.
  headless = { process = false, log = false, task = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
  performance = {
    -- netrw's D, R, d and % delete, rename and create files. snacks' explorer
    -- opens directories instead.
    rtp = { disabled_plugins = { "gzip", "netrwPlugin", "tarPlugin", "tohtml", "tutor", "zipPlugin" } },
  },
})

-- The colorscheme picked with <leader>uC wins over one that a personal spec
-- set.
local picked = require("anvim.prefs").get("colorscheme")
if not (picked and pcall(vim.cmd.colorscheme, picked)) and not vim.g.colors_name then
  pcall(vim.cmd.colorscheme, "tokyonight")
end

-- bin/anvim sets it when its install failed, and the TUI's alternate screen
-- hides what the install printed.
if vim.env.ANVIM_INSTALL_FAILED == "1" then
  vim.env.ANVIM_INSTALL_FAILED = nil
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = function()
      vim.notify(
        ("The install failed, so anvim runs with the plugins it had. Run %s/scripts/install to see why."):format(root),
        vim.log.levels.WARN
      )
    end,
  })
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
