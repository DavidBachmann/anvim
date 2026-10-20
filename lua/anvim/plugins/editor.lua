local keys = require("anvim.keys")

local to_code = {
  function()
    vim.api.nvim_set_current_win(require("anvim.layout").code_win())
  end,
  desc = keys.desc("explorer", "n", "<C-l>"),
}

return {
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      sources = {
        per_filetype = {
          anvim_input = function()
            return require("anvim.completion").providers()
          end,
        },
        providers = { anvim = { name = "anvim", module = "anvim.completion" } },
      },
    },
  },

  -- Enter on a slash command in the prompt completes it and sends it, as in
  -- Claude Code. Other items, such as @ files, are only completed, and so is
  -- every item in the compose window, which shares the prompt's filetype.
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      local function send_command(cmp)
        local item = vim.b.anvim_input and cmp.get_selected_item()
        local data = item and item.data
        if type(data) == "table" and data.anvim_command and data.send then
          return cmp.accept({
            callback = function()
              if not require("anvim.permission").key("<CR>") then
                require("anvim.input").submit()
              end
            end,
          })
        end
      end
      opts.keymap = opts.keymap or {}
      local enter = opts.keymap["<CR>"]
      if enter == nil and opts.keymap.preset == "enter" then
        enter = { "accept", "fallback" }
      end
      if enter then
        opts.keymap["<CR>"] = vim.list_extend({ send_command }, enter)
      end
    end,
  },

  -- The explorer's list is a float, and from a float <C-w>l goes to the
  -- previous window, which can be the prompt. To its right is the code window.
  -- The global <C-l> remaps to <C-w>l but does not reach this key, so map it too.
  -- `@` puts a reference to the files under the cursor or selected in the prompt.
  {
    "folke/snacks.nvim",
    optional = true,
    opts = {
      picker = {
        sources = {
          explorer = {
            -- snacks takes a layout that has a [1] as it is, and merges no
            -- preset into it. So this one has the list only, without the input
            -- window of the sidebar preset. Narrow, to leave the columns to the
            -- code. With focus, the tree widens over the code window to fit
            -- its rows.
            layout = {
              preset = "sidebar",
              preview = false,
              layout = {
                backdrop = false,
                width = require("anvim.config").options.layout.tree.width,
                min_width = require("anvim.config").options.layout.tree.width,
                height = 0,
                position = "left",
                border = "none",
                box = "vertical",
                { win = "list", border = "none" },
              },
            },
            -- The agents' dots on the files they write to.
            format = function(item, picker)
              return require("anvim.tree").format(item, picker)
            end,
            actions = {
              anvim_reference = function(picker)
                require("anvim.refs").files(vim.tbl_map(function(item)
                  return { path = item.file, dir = item.dir }
                end, picker:selected({ fallback = true })))
              end,
            },
            win = {
              list = {
                keys = {
                  ["<c-w>l"] = to_code,
                  ["<c-l>"] = to_code,
                  ["@"] = { "anvim_reference", desc = keys.desc("explorer", "n", "@") },
                  -- Claude changes the files. These keys add, delete, rename,
                  -- copy, move and paste them.
                  a = false,
                  d = false,
                  r = false,
                  c = false,
                  m = false,
                  p = false,
                  -- <c-c> changes the cwd, and anvim's relative paths need it
                  -- to stay.
                  ["<c-c>"] = false,
                },
              },
            },
          },
          -- The logs confirm with git_checkout, which checks out the commit,
          -- or the file as it was there, without a prompt. Enter goes to the
          -- commit in the preview instead.
          git_log = { confirm = "focus_preview" },
          git_log_file = { confirm = "focus_preview" },
          git_log_line = { confirm = "focus_preview" },
          -- <c-r> restores files and hunks. <Tab> stays: it only stages.
          git_status = { win = { input = { keys = { ["<c-r>"] = false } } } },
          git_diff = { win = { input = { keys = { ["<c-r>"] = false } } } },
        },
      },
    },
  },
}
