local to_code = {
  function()
    vim.api.nvim_set_current_win(require("anvim.layout").code_win())
  end,
  desc = "Go to the code window",
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
  -- LazyVim's <C-l> remaps to <C-w>l but does not reach this key, so map it too.
  -- `@` puts a reference to the files under the cursor or selected in the prompt.
  {
    "folke/snacks.nvim",
    optional = true,
    opts = {
      picker = {
        sources = {
          explorer = {
            -- Narrow, to leave the columns to the code. With focus, the tree
            -- widens over the code window to fit its rows.
            layout = {
              layout = {
                width = require("anvim.config").options.layout.tree.width,
                min_width = require("anvim.config").options.layout.tree.width,
              },
            },
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
                  ["@"] = { "anvim_reference", desc = "Point Claude at the file" },
                },
              },
            },
          },
        },
      },
    },
  },

  -- hbac closes old buffers when new ones open. It must not close one that
  -- Claude is streaming into.
  {
    "axkirillov/hbac.nvim",
    optional = true,
    init = function()
      local group = vim.api.nvim_create_augroup("anvim.hbac", {})
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "AnvimPreviewStart",
        callback = function(ev)
          local buf = ev.data.buf
          if package.loaded["hbac"] and not require("hbac.state").is_pinned(buf) then
            require("hbac.state").set_pin(buf, true)
            vim.b[buf].anvim_hbac_pin = true
          end
        end,
      })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "AnvimPreviewEnd",
        callback = function(ev)
          local buf = ev.data.buf
          if vim.b[buf].anvim_hbac_pin then
            vim.b[buf].anvim_hbac_pin = nil
            require("hbac.state").set_pin(buf, false)
          end
        end,
      })
    end,
  },
}
