-- The colorschemes that <leader>uC lists with Neovim's own. Each loads only
-- when picked. init.lua loads tokyonight when nothing was picked and no
-- plugin set a colorscheme.
return {
  {
    "folke/tokyonight.nvim",
    lazy = true,
    opts = { style = "moon" },
  },
  -- Neovim ships a catppuccin of its own, which :colorscheme catppuccin
  -- loads until this plugin has loaded. A variant, such as catppuccin-mocha,
  -- loads the plugin.
  { "catppuccin/nvim", name = "catppuccin", lazy = true },
  { "rose-pine/neovim", name = "rose-pine", lazy = true },
  { "rebelot/kanagawa.nvim", lazy = true },
  { "EdenEast/nightfox.nvim", lazy = true },
  { "ellisonleao/gruvbox.nvim", lazy = true },
  { "miikanissi/modus-themes.nvim", lazy = true },
}
