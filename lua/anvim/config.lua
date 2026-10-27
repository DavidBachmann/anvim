local M = {}

---@class anvim.Config
M.defaults = {
  ---@type string? Model id or alias. Nil uses the Claude Code default.
  model = nil,
  ---@type 'low'|'medium'|'high'|'xhigh'|'max'|nil Nil uses your Claude Code settings, else the model's level.
  effort = nil,
  ---@type 'default'|'acceptEdits'|'plan'|'bypassPermissions'
  permission_mode = "bypassPermissions",
  ---@type string? A session id to resume at start, or "pick" to choose one.
  resume = nil,
  -- Resume the latest session in the working directory at start.
  continue = false,
  ---@type string? The account to start with: default, or <name> for the config dir ~/.claude-<name>.
  account = nil,
  -- Run Claude's Bash commands in Claude Code's sandbox: they can write only in the project, a temp dir and
  -- the npm, bun and go build caches.
  sandbox = true,
  ---@type boolean? Claude in Chrome, as Claude Code's --chrome and --no-chrome. Nil follows its "Enabled by default".
  chrome = nil,
  -- Give Claude the codex tool, which starts OpenAI Codex agents. It needs the codex CLI with a login.
  codex = false,
  -- For anvim's own development: Claude gets the mcp__anvim__screenshot and mcp__anvim__reload tools.
  debug = false,
  bun = "bun",
  ---@type string? A recording that ANVIM_RECORD saved. The sidecar plays it instead of a live session.
  replay = nil,
  ---@type number How fast the replay plays: 2 is twice the recorded speed.
  replay_speed = 1,
  ---@type string[]? Replaces the sidecar command.
  sidecar_cmd = nil,
  layout = {
    ---@type number Columns, or a fraction of the screen width.
    claude_width = 0.36,
    ---@type number The tool pane's rows, or a fraction of the code column's height.
    pane_height = 0.25,
    -- Rows for the prompt, the rule under it and its footer. The window grows
    -- with the prompt.
    input_height = { min = 3, max = 12 },
    -- The explorer's columns. With focus, its list widens over the code
    -- window to fit its rows, up to max_width (columns, or a fraction of the
    -- screen width). With auto-minimize off (<leader>ue), the split itself
    -- fits the rows.
    tree = { width = 30, max_width = 0.4 },
  },
  input = {
    -- Start insert mode whenever the cursor enters the prompt, except at
    -- start. Off, only insert commands start it, in the prompt or in a file
    -- buffer.
    auto_insert = false,
  },
  append_system_prompt = table.concat({
    "The user reads code in anvim, a read-only Neovim viewer, while you work.",
    "They cannot edit files themselves; you make every change.",
    "Make each file change with Edit or Write, also a small one.",
    "anvim streams those edits into the user's view, but it cannot show a change that a Bash command makes.",
    "Use sed, perl or a script only for one change across many files.",
    "They point at code as @path#L12-30 (1-based, inclusive).",
    "The mcp__anvim__ tools work in their editor.",
    "When you explain code or say where something is, call show_user so they see it, with a short note.",
    "For code symbols, use the lsp_ tools before grep. They ask the language servers that run in the editor.",
    "To find where a symbol is used, locate it with lsp_workspace_symbols, then call lsp_references.",
  }, " "),
}

---@type anvim.Config
M.options = vim.deepcopy(M.defaults)

M.effort_levels = { "low", "medium", "high", "xhigh", "max" }

-- Whether the user named the permission mode: --mode, ANVIM_MODE or a spec
-- of their own. Only anvim's own default falls back without a sandbox.
M.mode_chosen = false
local DEFAULT_REASON = "it is anvim's default, and the sandbox is on"
-- Why the session starts in its mode, for :checkhealth.
M.mode_reason = DEFAULT_REASON
-- The sidecar found no sandbox at this start, and fell back to default mode.
M.fell_back = false

-- No sandbox runs, so a mode that nobody chose becomes default mode. In
-- bypass mode, nothing would limit or ask before a Bash command.
---@param why string
function M.fall_back(why)
  M.options.permission_mode = "default"
  M.mode_reason = why
end

-- The sidecar's fallback lasts for one start. The next start asks for
-- anvim's own default again, so the sidecar checks the sandbox again.
---@return boolean reset Whether a fallback ended.
function M.end_fallback()
  if not M.fell_back then
    return false
  end
  M.fell_back = false
  M.options.permission_mode = M.defaults.permission_mode
  M.mode_reason = DEFAULT_REASON
  return true
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local mode = (opts or {}).permission_mode
  M.mode_chosen = mode ~= nil and mode ~= ""
  M.fell_back = false
  if M.mode_chosen then
    M.mode_reason = "you chose it"
  else
    M.options.permission_mode = M.defaults.permission_mode
    M.mode_reason = DEFAULT_REASON
    if M.options.sandbox == false then
      M.fall_back("the sandbox is off, and no mode was chosen")
    end
  end
  -- bin/anvim checks --effort, but a personal spec or a stale ANVIM_EFFORT
  -- can name anything.
  local effort = M.options.effort
  if effort == "" then
    M.options.effort = nil
  elseif effort ~= nil and not vim.tbl_contains(M.effort_levels, effort) then
    M.options.effort = nil
    vim.schedule(function()
      local n = #M.effort_levels
      local levels = table.concat(M.effort_levels, ", ", 1, n - 1) .. " or " .. M.effort_levels[n]
      vim.notify(
        ("anvim: the effort %s is unknown, so Claude uses the default. Use %s."):format(vim.inspect(effort), levels),
        vim.log.levels.WARN
      )
    end)
  end
end

return M
