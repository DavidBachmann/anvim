local M = {}

---@class anvim.Config
M.defaults = {
  ---@type string? Model id or alias. Nil uses the Claude Code default.
  model = nil,
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
  },
  input = {
    -- Start insert mode whenever the cursor enters the prompt.
    auto_insert = true,
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

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
