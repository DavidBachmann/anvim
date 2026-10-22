-- Autocmds as in LazyVim, without the ones for editing.
local function augroup(name)
  return vim.api.nvim_create_augroup("anvim.base." .. name, { clear = true })
end

-- Reload a file that changed on disk.
vim.api.nvim_create_autocmd({ "FocusGained", "TermClose", "TermLeave" }, {
  group = augroup("checktime"),
  callback = function()
    if vim.o.buftype ~= "nofile" then
      vim.cmd("checktime")
    end
  end,
})

vim.api.nvim_create_autocmd("TextYankPost", {
  group = augroup("highlight_yank"),
  callback = function()
    if vim.fn.has("nvim-0.13") == 1 then
      vim.hl.hl_op()
    else
      vim.hl.on_yank()
    end
  end,
})

-- The command line's completion menu shows as the user types a command, but
-- not a search.
vim.api.nvim_create_autocmd("CmdlineChanged", {
  group = augroup("cmdline_complete"),
  pattern = ":",
  callback = function()
    vim.fn.wildtrigger()
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = augroup("close_with_q"),
  pattern = { "checkhealth", "gitsigns-blame", "help", "lspinfo", "notify", "qf", "startuptime" },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
    vim.schedule(function()
      require("anvim.keys").set("global", "n", "q", function()
        vim.cmd("close")
        pcall(vim.api.nvim_buf_delete, event.buf, { force = true })
      end, {
        buffer = event.buf,
        silent = true,
      })
    end)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = augroup("man_unlisted"),
  pattern = { "man" },
  callback = function(event)
    vim.bo[event.buf].buflisted = false
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = augroup("json_conceal"),
  pattern = { "json", "jsonc", "json5" },
  callback = function()
    vim.opt_local.conceallevel = 0
  end,
})
