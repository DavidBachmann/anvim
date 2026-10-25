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

-- A quickfix buffer enters with no 'buftype' yet, so it got the keys of a
-- file buffer, which go now.
local function unlock(buf)
  vim.b[buf].anvim_locked = nil
  for _, key in ipairs(require("anvim.layout").insert_keys) do
    pcall(vim.keymap.del, "n", key, { buffer = buf })
  end
  require("anvim.refs").unmap(buf)
  require("anvim.tabs").unmap(buf)
  api.nvim_clear_autocmds({ group = writes, buffer = buf })
end

function M.lock(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  elseif vim.bo[buf].buftype ~= "" then
    if vim.b[buf].anvim_locked then
      unlock(buf)
    end
  else
    vim.b[buf].anvim_locked = true
    vim.bo[buf].modifiable = false
    for _, key in ipairs(require("anvim.layout").insert_keys) do
      require("anvim.keys").set("code", "n", key, talk, { buffer = buf })
    end
    require("anvim.refs").map(buf)
    require("anvim.tabs").map(buf)
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

-- snacks sends an image file to the terminal once, and keeps its id and size
-- by path. A file that changed on disk, such as a PNG that Claude wrote
-- again, would reload with the old picture. So the reload forgets the image:
-- the terminal frees the old data, and the file goes again as a new image.
-- snacks forgets only all images at once, so the others go again when they
-- show next. snacks keeps the PNG that it converted from another format and
-- never checks it again, so the reload removes it too.
local function resend_images(group)
  local mtimes = {}
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*." .. table.concat(Snacks.config.image.formats, ",*."),
    callback = function(ev)
      local file = api.nvim_buf_get_name(ev.buf)
      local stat = vim.uv.fs_stat(file)
      -- Only the format. supports() would also check the terminal, and snacks
      -- keeps the first answer: here it comes before the terminal answers
      -- snacks's query, so snacks would never show an image.
      if not stat or not Snacks.config.image.enabled or not Snacks.image.supports_file(file) then
        return
      end
      local mtime = stat.mtime.sec .. "." .. stat.mtime.nsec
      local changed = mtimes[file] ~= nil and mtimes[file] ~= mtime
      mtimes[file] = mtime
      if changed then
        local img = Snacks.image.image.new(file)
        img:del()
        Snacks.image.terminal.request({ a = "d", d = "I", i = img.id })
        if vim.startswith(img.file, Snacks.image.config.cache .. "/") then
          os.remove(img.file)
        end
        Snacks.image.image.clear()
        Snacks.image.buf.attach(ev.buf)
      end
    end,
  })
end

function M.setup()
  vim.o.autoread = true
  vim.o.swapfile = false
  local group = api.nvim_create_augroup("anvim.readonly", {})
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter", "BufEnter" }, {
    group = group,
    callback = function(ev)
      M.lock(ev.buf)
    end,
  })
  resend_images(group)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    M.lock(buf)
  end
end

function M.attach(sidecar)
  sidecar.on("tool_result", M.reload)
  sidecar.on("turn_end", M.reload)
end

return M
