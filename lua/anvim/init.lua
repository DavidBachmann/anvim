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
  AnvimTodoActive = { bold = true },
}

local function set_highlights()
  for name, spec in pairs(highlights) do
    api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
  local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
  api.nvim_set_hl(0, "AnvimTodoDone", { fg = comment.fg, strikethrough = true, default = true })
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
  require("anvim.context").attach()
  require("anvim.trail").attach(sidecar)
  require("anvim.completion").attach(sidecar)
  require("anvim.sessions").attach()
  require("anvim.notify").attach(sidecar)
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
    end
    state.compacting = ev.status == "compacting"
    input.redraw()
  end)
  sidecar.on("turn_end", refresh_branch)
  sidecar.on("exit", function(ev)
    state.process = ev.restart and "starting" or "exited"
    state.compacting = false
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
  require("anvim.tree").setup()
  api.nvim_create_user_command("Anvim", M.start, { desc = "Open the anvim layout and start Claude" })
  api.nvim_create_user_command("AnvimInterrupt", input.interrupt, { desc = "Interrupt Claude" })
  api.nvim_create_user_command("AnvimTranscript", windows.read, { desc = "Focus the transcript to yank and search" })
  local sessions = require("anvim.sessions")
  api.nvim_create_user_command("AnvimSessions", sessions.pick, { desc = "Resume a session of this directory" })
  api.nvim_create_user_command("AnvimRestart", sessions.restart, { desc = "Restart Claude in this session" })
  api.nvim_create_user_command("AnvimModel", sessions.pick_model, { desc = "Choose Claude's model" })
  vim.keymap.set("n", "<leader>ks", sessions.pick, { desc = "Resume a session" })
  vim.keymap.set("n", "<leader>km", sessions.pick_model, { desc = "Choose the model" })
  vim.keymap.set("n", "<leader>ky", function()
    sessions.yank()
  end, { desc = "Yank Claude's last reply" })
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
  local resume = config.options.resume
  local sessions = require("anvim.sessions")
  sidecar.start(sessions.start_command({
    resume = resume ~= "pick" and resume or nil,
    continue = config.options.continue or nil,
    history = true,
  }))
  if resume == "pick" then
    vim.schedule(sessions.pick)
  end
  api.nvim_create_autocmd("VimLeavePre", { callback = sidecar.stop })
end

return M
