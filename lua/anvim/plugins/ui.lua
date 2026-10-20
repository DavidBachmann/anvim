local function claude_color()
  return { fg = Snacks.util.color("AnvimClaude") }
end

return {
  -- The global statusline shows where Claude is and whether it works, from any window.
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("anvim.lualine", {}),
        pattern = "AnvimStatus",
        callback = function()
          require("lualine").refresh({ place = { "statusline" } })
        end,
      })
      local follow = require("anvim.follow")
      local input = require("anvim.input")
      local components = {
        {
          input.working,
          cond = function()
            return input.working() ~= ""
          end,
          color = claude_color,
        },
        {
          function()
            return (follow.status():gsub("%%", "%%%%"))
          end,
          cond = function()
            return follow.status() ~= ""
          end,
          color = claude_color,
          separator = "",
        },
        {
          function()
            return "(<leader>j)"
          end,
          cond = function()
            return follow.agent ~= nil and not follow.enabled()
          end,
          color = function()
            return { fg = Snacks.util.color("Comment") }
          end,
          padding = { left = 0, right = 1 },
        },
      }
      for i, component in ipairs(components) do
        table.insert(opts.sections.lualine_x, i, component)
      end
      table.insert(opts.sections.lualine_c, {
        function()
          return "(writing)"
        end,
        cond = function()
          return vim.b.anvim_preview ~= nil
        end,
        color = function()
          return { fg = Snacks.util.color("Comment") }
        end,
      })
      -- The Claude column has no file, so its statusline drops the path and position.
      local claude = vim.deepcopy(opts.sections)
      claude.lualine_c, claude.lualine_y = {}, {}
      opts.extensions = opts.extensions or {}
      table.insert(opts.extensions, { filetypes = { "anvim_input", "anvim_transcript" }, sections = claude })
    end,
  },

  -- Keep buffer tabs over the code column, like the tree's offset on the left.
  {
    "akinsho/bufferline.nvim",
    optional = true,
    opts = function(_, opts)
      table.insert(opts.options.offsets, { filetype = "anvim_transcript", text = "Claude", text_align = "left" })
    end,
  },

  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>j", icon = { icon = "⏺", color = "orange" } },
        { "<leader>k", group = "claude", icon = { icon = "⏺", color = "orange" } },
      },
    },
  },
}
