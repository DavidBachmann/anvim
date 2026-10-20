-- The user reads; Claude writes. File buffers are never modifiable, and they
-- reload when Claude changes the file on disk.
local M = {}

local api = vim.api
local writes = api.nvim_create_augroup("anvim.readonly.write", {})

local function talk()
  require("anvim.layout").focus_input()
end

local function refuse()
  vim.notify("anvim is read-only", vim.log.levels.WARN)
end

function M.lock(buf)
  if api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
    vim.bo[buf].modifiable = false
    for _, key in ipairs(require("anvim.layout").insert_keys) do
      vim.keymap.set("n", key, talk, { buffer = buf, desc = "Talk to Claude" })
    end
    require("anvim.refs").map(buf)
    -- A *Cmd autocmd replaces the write, so BufWritePre hooks such as format
    -- on save never run.
    local events = { "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }
    local name = api.nvim_buf_get_name(buf)
    api.nvim_clear_autocmds({ group = writes, buffer = buf, event = events })
    api.nvim_create_autocmd(events, {
      group = writes,
      buffer = buf,
      callback = function()
        -- :saveas renames the buffer before it writes.
        if name ~= "" and api.nvim_buf_get_name(buf) ~= name then
          api.nvim_buf_set_name(buf, name)
        end
        refuse()
      end,
    })
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
