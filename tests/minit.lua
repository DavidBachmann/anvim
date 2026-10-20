#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = ".tests"
-- lazy.nvim rewrites the helptags in its own dir after it installs plugins,
-- so the tests use their own copy in .tests, not the shared one.
vim.env.LAZY_PATH = vim.env.LAZY_PATH or vim.fn.fnamemodify(".tests/data/nvim/lazy/lazy.nvim", ":p")
-- The first run installs the test plugins. Later runs skip the update, so
-- they work offline. LAZY_OFFLINE=0 updates the plugins.
vim.env.LAZY_OFFLINE = vim.env.LAZY_OFFLINE or "1"

if vim.fn.isdirectory(vim.env.LAZY_PATH) == 1 then
  loadfile(vim.env.LAZY_PATH .. "/bootstrap.lua")()
else
  load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"), "bootstrap.lua")()
end

-- Setup lazy.nvim
require("lazy.minit").setup({
  spec = {
    { dir = vim.uv.cwd() },
    { "folke/snacks.nvim", opts = {} },
    { "nvim-mini/mini.icons", opts = {} },
  },
})
