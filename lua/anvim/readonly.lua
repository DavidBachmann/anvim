-- The user reads; Claude writes. File buffers are never modifiable, and they
-- reload when Claude changes the file on disk.
local M = {}

local api = vim.api

local function talk()
  require("anvim.layout").focus_input()
end

function M.lock(buf)
  if api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
    vim.bo[buf].modifiable = false
    for _, key in ipairs({ "i", "a" }) do
      vim.keymap.set("n", key, talk, { buffer = buf, desc = "Talk to Claude" })
    end
  end
end

function M.reload()
  vim.cmd("silent! checktime")
end

function M.setup()
  vim.o.autoread = true
  vim.o.swapfile = false
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter", "BufEnter" }, {
    group = api.nvim_create_augroup("anvim.readonly", {}),
    callback = function(ev)
      M.lock(ev.buf)
    end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    M.lock(buf)
  end
end

function M.attach(sidecar)
  sidecar.on("tool_result", M.reload)
  sidecar.on("turn_end", M.reload)
end

return M
