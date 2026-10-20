return {
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      sources = { per_filetype = { anvim_input = { "path", "buffer" } } },
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
