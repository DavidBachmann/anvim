local M = {}

---@class anvim.Config
M.defaults = {
  ---@type string? Model id or alias. Nil uses the Claude Code default.
  model = nil,
  ---@type 'low'|'medium'|'high'|'xhigh'|'max'|nil Nil uses your Claude Code settings, else the model's level.
  effort = nil,
  ---@type 'default'|'acceptEdits'|'plan'|'bypassPermissions'
  permission_mode = "default",
  ---@type string? A session id to resume at start, or "pick" to choose one.
  resume = nil,
  -- Resume the latest session in the working directory at start.
  continue = false,
  bun = "bun",
  ---@type string[]? Replaces the sidecar command, e.g. to replay a recording.
  sidecar_cmd = nil,
  layout = {
    ---@type number Columns, or a fraction of the screen width.
    claude_width = 0.36,
    -- Rows for the prompt and its footer. The window grows with the prompt.
    input_height = { min = 2, max = 12 },
    -- The explorer's columns. With focus, its list widens over the code
    -- window to fit its rows, up to max_width (columns, or a fraction of the
    -- screen width).
    tree = { width = 24, max_width = 0.4 },
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

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- bin/anvim checks --effort, but a personal spec or a stale ANVIM_EFFORT
  -- can name anything.
  local effort = M.options.effort
  if effort == "" then
    M.options.effort = nil
  elseif effort ~= nil and not vim.tbl_contains(M.effort_levels, effort) then
    M.options.effort = nil
    vim.schedule(function()
      local levels = "low, medium, high, xhigh or max"
      vim.notify(
        ("anvim: the effort %s is unknown, so Claude uses the default. Use %s."):format(vim.inspect(effort), levels),
        vim.log.levels.WARN
      )
    end)
  end
end

return M
