local keys = require("anvim.keys")

local to_code = {
  function()
    vim.api.nvim_set_current_win(require("anvim.layout").code_win())
  end,
  desc = keys.desc("explorer", "n", "<C-l>"),
}

return {
  -- The explorer's list is a float, and from a float <C-w>h and <C-w>l go to
  -- the previous window, which can be the prompt. The explorer is at an edge
  -- of the screen, so the code window is its only neighbor. The global <C-h>
  -- and <C-l> remap to <C-w>h and <C-w>l but do not reach these keys, so map
  -- them too.
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
            -- its rows. A function, so that the side and the width are the
            -- current ones each time snacks lays the explorer out.
            layout = function()
              return {
                preset = "sidebar",
                preview = false,
                cycle = true,
                layout = {
                  backdrop = false,
                  width = require("anvim.tree").split_width(),
                  min_width = require("anvim.config").options.layout.tree.width,
                  height = 0,
                  position = require("anvim.layout").tree_side(),
                  border = "none",
                  box = "vertical",
                  { win = "list", border = "none" },
                },
              }
            end,
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
                  ["<c-w>h"] = to_code,
                  ["<c-h>"] = to_code,
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
