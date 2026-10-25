-- The colorschemes that <leader>uC lists with Neovim's own. Each loads only
-- when picked. init.lua loads tokyonight when nothing was picked and no
-- plugin set a colorscheme.
return {
  {
    "folke/tokyonight.nvim",
    lazy = true,
    opts = { style = "moon" },
  },
  -- Neovim ships a catppuccin of its own, and lazy.nvim loads no plugin for a
  -- colorscheme that Neovim already has. Neovim's gives floats the text color
  -- of comments, so :colorscheme catppuccin loads this plugin first, and the
  -- plugin's colors come before Neovim's in 'runtimepath'.
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = true,
    init = function()
      vim.api.nvim_create_autocmd("ColorSchemePre", {
        pattern = "catppuccin",
        once = true,
        callback = function()
          require("lazy").load({ plugins = { "catppuccin" } })
        end,
      })
    end,
  },
  { "rose-pine/neovim", name = "rose-pine", lazy = true },
  { "rebelot/kanagawa.nvim", lazy = true },
  { "EdenEast/nightfox.nvim", lazy = true },
  { "ellisonleao/gruvbox.nvim", lazy = true },
  { "miikanissi/modus-themes.nvim", lazy = true },
}
