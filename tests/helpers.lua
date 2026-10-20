-- Shared setup for the specs. mini.test runs every spec file in one Neovim,
-- so anvim and its replay sidecar start once, on first use.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- A temp project with the fixture file, and a recording rewritten to point at it.
-- Neovim deletes its temp dir on exit. VimLeavePre is no place for cleanup:
-- under `nvim -l` it fires when the script ends, before the cases run.
M.tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(M.tmp, "p")
local fixtures = M.root .. "/tests/fixtures"
vim.fn.writefile(vim.fn.readfile(fixtures .. "/matchparen.lua"), M.tmp .. "/matchparen.lua")
local recording = M.tmp .. "/session.jsonl"
local frames = vim.fn.readfile(fixtures .. "/edit-session.jsonl")
for i, frame in ipairs(frames) do
  frames[i] = frame:gsub("/ANVIM_FIXTURE", M.tmp)
end
vim.fn.writefile(frames, recording)

---@type integer?
local start_win

-- Starts anvim in the temp project with the replay sidecar, once.
---@return integer win The window that had focus after start.
function M.start()
  if start_win then
    return start_win
  end
  vim.cmd.cd(M.tmp)
  local anvim = require("anvim")
  anvim.setup({
    permission_mode = "bypassPermissions",
    sidecar_cmd = { "bun", M.root .. "/sidecar/src/replay.ts", recording, "50" },
  })
  anvim.start()
  vim.wait(100)
  start_win = vim.api.nvim_get_current_win()
  assert(
    vim.wait(5000, function()
      return require("anvim.state").process == "ready"
    end),
    "sidecar not ready"
  )
  return start_win
end

function M.buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function M.contains(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern) then
      return true
    end
  end
  error(("no line matches %q in:\n%s"):format(pattern, table.concat(lines, "\n")), 2)
end

function M.field(id, name, key, phase, x)
  require("anvim.sidecar").dispatch({
    type = "tool_field",
    id = id,
    name = name,
    key = key,
    phase = phase,
    text = phase == "delta" and x or nil,
    value = phase == "end" and x or nil,
  })
end

function M.hl_groups(buf, ns_name)
  local groups = {}
  local ns = vim.api.nvim_get_namespaces()[ns_name]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local group = mark[4].hl_group or mark[4].line_hl_group
    if group then
      groups[group] = (groups[group] or 0) + 1
    end
  end
  return groups
end

-- Captures what the plugin sends to the sidecar while fn runs.
function M.capture_sends(fn)
  local sidecar = require("anvim.sidecar")
  local sent, send = {}, sidecar.send
  sidecar.send = function(msg)
    sent[#sent + 1] = msg
  end
  local ok, err = pcall(fn, sent)
  sidecar.send = send
  if not ok then
    error(err, 0)
  end
end

return M
