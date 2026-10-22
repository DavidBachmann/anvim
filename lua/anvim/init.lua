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
  AnvimThinking = { link = "Comment" },
  AnvimModeManual = { link = "DiagnosticOk" },
  AnvimModeEdits = { link = "DiagnosticHint" },
  AnvimModePlan = { link = "DiagnosticInfo" },
  AnvimModeBypass = { link = "DiagnosticError" },
  AnvimModeAuto = { link = "DiagnosticWarn" },
  AnvimInsert = { link = "DiffAdd" },
  AnvimRead = { link = "Visual" },
  AnvimTodoActive = { bold = true },
  AnvimAsk = { link = "Title" },
  AnvimChoice = { link = "Special" },
  -- What a second <Esc> in the prompt does: the activity line's text, and the choice.
  AnvimDanger = { link = "DiagnosticError" },
  AnvimShow = { link = "Visual" },
  AnvimNote = { link = "DiagnosticInfo" },
  AnvimSelection = { link = "Visual" },
  AnvimChip = { link = "Comment" },
  AnvimChipSelection = { link = "AnvimClaude" },
  -- The Claude column's background is the tree's. The explorer's list maps
  -- NormalFloat to SnacksPickerList.
  AnvimNormal = { link = "SnacksPickerList" },
  -- The activity line's rule. WinSeparator can fade into the tree's background.
  AnvimRule = { link = "LineNr" },
  -- The code window's winbar. Without a background of its own, it has the code's.
  AnvimWinBar = { link = "Comment" },
  AnvimWinBarWriting = { link = "AnvimClaude" },
  -- Far apart from each other and from AnvimClaude in the usual colorschemes.
  AnvimAgent1 = { link = "MiniIconsAzure" },
  AnvimAgent2 = { link = "MiniIconsPurple" },
  AnvimAgent3 = { link = "MiniIconsYellow" },
  AnvimAgent4 = { link = "MiniIconsBlue" },
}

---@type table<string, vim.api.keyset.get_highlight> The groups as anvim computed them last.
local derived = {}

-- A group computed from the colorscheme's colors. With a default, it would
-- keep the old colors after a colorscheme that does no :hi clear, such as
-- tokyonight on its first load. A group that someone else set stays.
local function set_derived(name, spec)
  local now = api.nvim_get_hl(0, { name = name })
  if next(now) == nil or vim.deep_equal(now, derived[name]) then
    api.nvim_set_hl(0, name, spec)
    derived[name] = api.nvim_get_hl(0, { name = name })
  end
end

local function set_highlights()
  for name, spec in pairs(highlights) do
    api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
  local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
  set_derived("AnvimTodoDone", { fg = comment.fg, strikethrough = true })
  local del = api.nvim_get_hl(0, { name = "DiffDelete", link = false })
  set_derived("AnvimDelete", { bg = del.bg, strikethrough = true })
  -- The completion menu's border, as the other floats draw theirs. A
  -- colorscheme's own stays.
  if vim.deep_equal(api.nvim_get_hl(0, { name = "PmenuBorder" }), { link = "Pmenu" }) then
    api.nvim_set_hl(0, "PmenuBorder", { link = "FloatBorder" })
  end
  -- snacks defines the list's groups only when the explorer opens. Until then,
  -- these links, which are snacks' own, resolve AnvimNormal.
  api.nvim_set_hl(0, "SnacksPickerList", { link = "SnacksPicker", default = true })
  api.nvim_set_hl(0, "SnacksPicker", { link = "NormalFloat", default = true })
  -- The blank row under the transcript takes the transcript's background. With
  -- a default, it would keep the previous colorscheme's colors.
  local sep = api.nvim_get_hl(0, { name = "WinSeparator", link = false })
  local column = api.nvim_get_hl(0, { name = "AnvimNormal", link = false })
  api.nvim_set_hl(0, "AnvimSeparator", { fg = sep.fg, bg = column.bg })
  require("anvim.statusline").highlights()
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
  require("anvim.bashread").attach(sidecar)
  require("anvim.agents").attach(sidecar)
  require("anvim.agentlog").attach(sidecar)
  transcript.attach(sidecar)
  input.attach()
  readonly.attach(sidecar)
  follow.attach(sidecar)
  require("anvim.overview").attach(sidecar)
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
  -- No sandbox runs, so the sidecar started anvim's own default in default
  -- mode, or switched it there. It is the start mode until the next start,
  -- so the footer shows no label, and Shift-Tab and plan approval offer no
  -- bypass.
  sidecar.on("start_mode", function(ev)
    config.fall_back("the sandbox cannot start, and no mode was chosen")
    config.fell_back = true
    state.permission_mode = ev.mode
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
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("anvim.highlights", {}),
    callback = set_highlights,
  })
  require("anvim.statusline").setup()
  readonly.setup()
  layout.setup()
  windows.setup()
  require("anvim.tree").setup()
  api.nvim_create_user_command("Anvim", M.start, { desc = "Open the anvim layout and start Claude" })
  api.nvim_create_user_command("AnvimStop", input.interrupt, { desc = "Stop Claude" })
  api.nvim_create_user_command("AnvimTranscript", windows.read, { desc = "Focus the transcript to yank and search" })
  local sessions = require("anvim.sessions")
  api.nvim_create_user_command("AnvimSessions", sessions.pick, { desc = "Resume a session of this directory" })
  api.nvim_create_user_command("AnvimRestart", sessions.restart, { desc = "Restart Claude in this session" })
  api.nvim_create_user_command("AnvimModel", sessions.pick_model, { desc = "Choose Claude's model" })
  local keys = require("anvim.keys")
  keys.set("claude", "n", "<leader>cs", sessions.pick)
  keys.set("claude", "n", "<leader>cm", sessions.pick_model)
  keys.set("claude", "n", "<leader>cy", sessions.yank)
  keys.set("claude", "n", "<leader>cR", sessions.restart)
  keys.set("global", "n", "<leader>?", function()
    require("anvim.keyview").open()
  end)
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
