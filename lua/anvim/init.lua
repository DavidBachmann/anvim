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
  AnvimTime = { link = "Comment" },
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
  AnvimChip = { link = "Comment" },
  -- The footer's agent count while j has selected it.
  AnvimChipSelected = { link = "PmenuSel" },
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

-- The terminal's background, from its answer to anvim's OSC 11 query.
---@type integer?
local term_bg

-- An OSC 11 answer, such as "\27]11;rgb:1919/1717/2424", as a color. A
-- channel has 1 to 4 hex digits, which scale to 8 bits as Neovim scales them.
local function parse_osc11(seq)
  local r, g, b = seq:match("^\27%]11;rgba?:(%x+)/(%x+)/(%x+)")
  if not (r and #r <= 4 and #g <= 4 and #b <= 4) then
    return
  end
  local color = 0
  for _, c in ipairs({ r, g, b }) do
    color = color * 256 + math.floor(tonumber(c, 16) / (16 ^ #c - 1) * 255 + 0.5)
  end
  return color
end

-- Takes tokyonight moon's #222436 near Rose Pine's #191724.
local function darken(color)
  local r, g, b = bit.rshift(color, 16), bit.band(bit.rshift(color, 8), 255), bit.band(color, 255)
  return math.floor(r * 0.7 + 0.5) * 65536 + math.floor(g * 0.7 + 0.5) * 256 + math.floor(b * 0.7 + 0.5)
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
  -- nvim_get_hl() goes through the current window's 'winhighlight'. The
  -- Claude column maps Normal and WinSeparator, so read them in the code window.
  local code = layout.wins.code
  local function get(name)
    local function hl()
      return api.nvim_get_hl(0, { name = name, link = false })
    end
    return code and api.nvim_win_is_valid(code) and api.nvim_win_call(code, hl) or hl()
  end
  -- The Claude column has the explorer's background, which the explorer's list
  -- takes from SnacksPickerList, and the code's text. Some colorschemes, such as
  -- Neovim's own catppuccin, give floats the text color of comments, and the
  -- times in the transcript would not stand out.
  set_derived("AnvimNormal", { fg = get("Normal").fg, bg = get("SnacksPickerList").bg })
  -- The blank row under the transcript takes the transcript's background. With
  -- a default, it would keep the previous colorscheme's colors.
  local column = api.nvim_get_hl(0, { name = "AnvimNormal", link = false })
  api.nvim_set_hl(0, "AnvimSeparator", { fg = get("WinSeparator").fg, bg = column.bg })
  -- The tool pane has the terminal's background, so it matches chrome such as
  -- cmux's sidebar. Until the terminal answers, it darkens the code's. Its
  -- bar has the code's, so the bar's tab stands apart from the calls.
  local normal = get("Normal")
  local bg = term_bg or (normal.bg and darken(normal.bg))
  set_derived("AnvimPane", { fg = normal.fg, bg = bg })
  set_derived("AnvimPaneWinBar", vim.tbl_extend("force", get("AnvimWinBar"), { bg = normal.bg }))
  -- The tab bar's current tab, which stands out from the dim tabs.
  set_derived("AnvimTabCurrent", { fg = normal.fg, bg = get("CursorLine").bg, bold = true })
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
  require("anvim.processes").attach(sidecar)
  require("anvim.agents").attach(sidecar)
  require("anvim.agentlog").attach(sidecar)
  transcript.attach(sidecar)
  require("anvim.todos").attach(sidecar)
  input.attach()
  readonly.attach(sidecar)
  follow.attach(sidecar)
  require("anvim.overview").attach(sidecar)
  stream.attach()
  require("anvim.tools").attach()
  require("anvim.permission").attach()
  require("anvim.trail").attach(sidecar)
  require("anvim.files").attach(sidecar)
  require("anvim.completion").attach(sidecar)
  require("anvim.sessions").attach()
  require("anvim.rewind").attach()
  require("anvim.settings").attach()
  require("anvim.notify").attach(sidecar)
  require("anvim.images").attach()
  sidecar.on("init", function(ev)
    state.session_id = ev.session_id
    state.model = ev.model
    state.permission_mode = ev.permission_mode
    state.process = "ready"
    input.redraw()
  end)
  -- No sandbox runs, so the sidecar started anvim's own default in default
  -- mode, or switched it there. It is the start mode until the next start,
  -- so the statusline shows no label, and Shift-Tab and plan approval offer no
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

---@return integer?
function M.term_bg()
  return term_bg
end

function M.setup(opts)
  config.setup(opts)
  -- Wrap transcript lines at spaces and punctuation, not inside paths.
  vim.o.breakat = " \t;:,!?"
  set_highlights()
  local group = api.nvim_create_augroup("anvim.highlights", {})
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  -- Neovim asks for the background before anvim runs and keeps only
  -- 'background', so ask again. Only a terminal UI gets the query.
  api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(ev)
      local bg = parse_osc11(ev.data.sequence)
      if bg then
        term_bg = bg
        set_highlights()
      end
    end,
  })
  api.nvim_ui_send("\27]11;?\7")
  require("anvim.markdown").setup()
  require("anvim.statusline").setup()
  readonly.setup()
  layout.setup()
  windows.setup()
  require("anvim.tree").setup()
  require("anvim.tabs").setup()
  api.nvim_create_user_command("Anvim", M.start, { desc = "Open the anvim layout and start Claude" })
  api.nvim_create_user_command("AnvimStop", input.interrupt, { desc = "Stop Claude" })
  api.nvim_create_user_command("AnvimTranscript", windows.read, { desc = "Focus the transcript to yank and search" })
  local sessions = require("anvim.sessions")
  api.nvim_create_user_command("AnvimSessions", sessions.pick, { desc = "Resume a session of this directory" })
  -- restart() takes a notice, not the command's table.
  api.nvim_create_user_command("AnvimRestart", function()
    sessions.restart()
  end, { desc = "Restart Claude in this session" })
  api.nvim_create_user_command("AnvimModel", sessions.pick_model, { desc = "Choose Claude's model" })
  api.nvim_create_user_command("AnvimAccount", function(cmd)
    require("anvim.accounts").command(cmd.args)
  end, { nargs = "*", desc = "Switch the Claude account, or add one" })
  local keys = require("anvim.keys")
  keys.set("claude", "n", "<leader>cs", sessions.pick)
  keys.set("claude", "n", "<leader>cm", sessions.pick_model)
  keys.set("claude", "n", "<leader>cy", sessions.yank)
  keys.set("claude", "n", "<leader>cR", sessions.restart)
  local processes = require("anvim.processes")
  keys.set("claude", "n", "<leader>cp", processes.open)
  api.nvim_create_user_command("AnvimProcesses", processes.open, { desc = "Show the running processes" })
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
  require("anvim.reload").attach()
  refresh_branch()
  local resume = config.options.resume
  local sessions = require("anvim.sessions")
  -- Claude starts once the account is known, which a picker can ask first.
  require("anvim.accounts").start(function()
    sidecar.start(sessions.start_command({
      resume = resume ~= "pick" and resume or nil,
      continue = config.options.continue or nil,
      history = true,
    }))
    if resume == "pick" then
      vim.schedule(sessions.pick)
    end
  end)
  api.nvim_create_autocmd("VimLeavePre", { callback = sidecar.stop })
  -- Neovim quits when the terminal of its stdio UI closes. After :restart,
  -- the terminal attaches over a socket, and Neovim 0.12 would run on alone
  -- with Claude. So anvim quits once no UI is left.
  api.nvim_create_autocmd("UILeave", {
    callback = function()
      vim.schedule(function()
        if #api.nvim_list_uis() == 0 and vim.v.exiting == vim.NIL then
          vim.cmd("qall!")
        end
      end)
    end,
  })
end

return M
