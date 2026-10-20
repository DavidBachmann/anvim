local config = require("anvim.config")
local follow = require("anvim.follow")
local input = require("anvim.input")
local layout = require("anvim.layout")
local readonly = require("anvim.readonly")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local stream = require("anvim.stream")
local transcript = require("anvim.transcript")
local windows = require("anvim.windows")

local M = {}

local api = vim.api

local highlights = {
  AnvimClaude = { fg = "#d77757" },
  AnvimPrompt = { link = "Special" },
  AnvimUser = { link = "CursorLine" },
  AnvimBullet = { link = "Normal" },
  AnvimToolName = { bold = true },
  AnvimToolPending = { link = "Comment" },
  AnvimToolOk = { link = "DiagnosticOk" },
  AnvimToolError = { link = "DiagnosticError" },
  AnvimResult = { link = "Comment" },
  AnvimModeEdits = { link = "DiagnosticHint" },
  AnvimModePlan = { link = "DiagnosticInfo" },
  AnvimModeBypass = { link = "DiagnosticError" },
  AnvimInsert = { link = "DiffAdd" },
  AnvimRead = { link = "Visual" },
}

local function set_highlights()
  for name, spec in pairs(highlights) do
    api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
  local del = api.nvim_get_hl(0, { name = "DiffDelete", link = false })
  api.nvim_set_hl(0, "AnvimDelete", { bg = del.bg, strikethrough = true, default = true })
  -- The blank row under the transcript takes the transcript's background.
  local sep = api.nvim_get_hl(0, { name = "WinSeparator", link = false })
  local nc = api.nvim_get_hl(0, { name = "NormalNC", link = false })
  api.nvim_set_hl(0, "AnvimSeparator", { fg = sep.fg, bg = nc.bg, default = true })
end

local function refresh_branch()
  vim.system({ "git", "branch", "--show-current" }, { cwd = state.cwd, text = true }, function(obj)
    vim.schedule(function()
      state.branch = obj.code == 0 and vim.trim(obj.stdout) or nil
      input.redraw()
    end)
  end)
end

local function wire()
  transcript.attach(sidecar)
  input.attach()
  readonly.attach(sidecar)
  follow.attach(sidecar)
  stream.attach()
  require("anvim.tools").attach()
  require("anvim.permission").attach()
  sidecar.on("init", function(ev)
    state.session_id = ev.session_id
    state.model = ev.model
    state.permission_mode = ev.permission_mode
    state.process = "ready"
    input.redraw()
  end)
  sidecar.on("status", function(ev)
    if ev.permission_mode then
      state.permission_mode = ev.permission_mode
      input.redraw()
    end
  end)
  sidecar.on("turn_end", refresh_branch)
  sidecar.on("exit", function()
    state.process = "exited"
  end)
end

function M.setup(opts)
  config.setup(opts)
  -- Wrap transcript lines at spaces and punctuation, not inside paths.
  vim.o.breakat = " \t;:,!?"
  set_highlights()
  api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })
  readonly.setup()
  layout.setup()
  windows.setup()
  api.nvim_create_user_command("Anvim", M.start, { desc = "Open the anvim layout and start Claude" })
  api.nvim_create_user_command("AnvimInterrupt", input.interrupt, { desc = "Interrupt Claude" })
  api.nvim_create_user_command("AnvimTranscript", windows.read, { desc = "Focus the transcript to yank and search" })
end

local started = false

function M.start()
  layout.open()
  if started then
    return
  end
  started = true
  state.cwd = vim.fn.getcwd()
  state.permission_mode = config.options.permission_mode
  wire()
  refresh_branch()
  sidecar.start({
    type = "start",
    cwd = state.cwd,
    model = config.options.model,
    permission_mode = config.options.permission_mode,
    append_system_prompt = config.options.append_system_prompt,
  })
  api.nvim_create_autocmd("VimLeavePre", { callback = sidecar.stop })
end

return M
