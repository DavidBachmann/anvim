local M = {}

---@class anvim.Config
M.defaults = {
  ---@type string? Model id or alias. Nil uses the Claude Code default.
  model = nil,
  ---@type 'default'|'acceptEdits'|'plan'|'bypassPermissions'
  permission_mode = 'default',
  bun = 'bun',
  ---@type string[]? Replaces the sidecar command, e.g. to replay a recording.
  sidecar_cmd = nil,
  layout = {
    tree_width = 32,
    ---@type number Columns, or a fraction of the screen width.
    claude_width = 0.36,
    input_height = 6,
  },
  append_system_prompt = table.concat({
    'The user reads code in anvim, a read-only Neovim viewer, while you work.',
    'They cannot edit files themselves; you make every change.',
    'They point at code as @path#L12-30 (1-based, inclusive).',
  }, ' '),
}

---@type anvim.Config
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

return M
