local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

-- ANVIM_REPLAY=<recording> plays a session that ANVIM_RECORD saved, at no API cost.
local replay = vim.env.ANVIM_REPLAY

-- LazyVim equalizes the splits on VimResized with :tabdo. In 0.12.5, :tabdo
-- from a 'winfixbuf' window such as the prompt splits that window, or moves
-- the cursor out of it. So run it from the code window.
local function resize_splits()
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("lazyvim_resize_splits", { clear = true }),
    callback = function()
      local function equalize()
        local tab = vim.fn.tabpagenr()
        vim.cmd("tabdo wincmd =")
        vim.cmd("tabnext " .. tab)
      end
      local code = require("anvim.layout").wins.code
      if code and vim.api.nvim_win_is_valid(code) then
        vim.api.nvim_win_call(code, equalize)
      else
        equalize()
      end
    end,
  })
end

return {
  {
    dir = root,
    name = "anvim",
    lazy = false,
    opts = {
      model = vim.env.ANVIM_MODEL,
      permission_mode = "bypassPermissions",
      sidecar_cmd = replay and { "bun", root .. "/sidecar/src/replay.ts", replay, vim.env.ANVIM_REPLAY_SPEED or "1" },
    },
    config = function(_, opts)
      local anvim = require("anvim")
      anvim.setup(opts)
      if vim.fn.has("nvim-0.13") == 0 then
        resize_splits()
        vim.api.nvim_create_autocmd("User", {
          group = vim.api.nvim_create_augroup("anvim.lazyvim", {}),
          pattern = "LazyVimAutocmds",
          callback = resize_splits,
        })
      end
      if vim.v.vim_did_enter == 1 then
        anvim.start()
      else
        vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = anvim.start })
      end
    end,
  },

  -- The main Neovim shows LazyVim's news. In anvim it would cover the layout.
  { "LazyVim/LazyVim", opts = { news = { lazyvim = false, neovim = false } } },
  { "folke/snacks.nvim", opts = { dashboard = { enabled = false } } },
  { "folke/persistence.nvim", enabled = false },
}
