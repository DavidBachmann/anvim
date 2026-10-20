local function claude_color()
  return { fg = Snacks.util.color("AnvimClaude") }
end

return {
  -- The global statusline shows whether Claude works or waits, from any
  -- window. The prompt's footer says where Claude is, and the statusline does
  -- when the footer's column is too narrow for it.
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
      local permission = require("anvim.permission")
      local components = {
        {
          function()
            return "⏺ Claude is waiting"
          end,
          cond = function()
            return permission.waiting() and vim.api.nvim_get_current_win() ~= require("anvim.layout").wins.input
          end,
          color = claude_color,
        },
        {
          input.working,
          cond = function()
            return input.working() ~= "" and not permission.waiting()
          end,
          color = claude_color,
        },
        {
          function()
            return (follow.status(true):gsub("%%", "%%%%"))
          end,
          cond = function()
            return not input.follows() and follow.status() ~= ""
          end,
          color = function()
            return { fg = Snacks.util.color(follow.group()) }
          end,
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
      -- The Claude column and the key view have no file, so their statusline
      -- drops the path and position.
      local claude = vim.deepcopy(opts.sections)
      claude.lualine_c, claude.lualine_y = {}, {}
      opts.extensions = opts.extensions or {}
      table.insert(
        opts.extensions,
        { filetypes = { "anvim_input", "anvim_transcript", "anvim_keys" }, sections = claude }
      )
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

  -- noice shows LSP progress at the bottom right, over the prompt's footer, for
  -- seconds while a server loads. The bottom left is the explorer's.
  {
    "folke/noice.nvim",
    optional = true,
    opts = {
      lsp = { progress = { view = "anvim_progress" } },
      views = { anvim_progress = { view = "mini", align = "message-left", position = { col = 0 } } },
    },
  },

  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>j", icon = { icon = "⏺", color = "orange" } },
        { "<leader>c", group = "claude", icon = { icon = "⏺", color = "orange" } },
      },
    },
  },
}
