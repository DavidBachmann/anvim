return {
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      -- The popup sits over the prompt. To keep off the cursor, which-key
      -- would move it below the cursor and shrink it to 4 lines.
      win = { no_overlap = false, width = { max = 70 } },
      spec = {
        { "<leader>j", icon = { icon = "⏺", color = "orange" } },
        { "<leader>c", group = "claude", icon = { icon = "⏺", color = "orange" } },
      },
    },
  },
}
