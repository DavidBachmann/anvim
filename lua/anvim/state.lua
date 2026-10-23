-- Session state that several views read: the statusline, the transcript, follow mode.
local M = {
  session_id = nil, ---@type string?
  model = nil, ---@type string?
  -- The effort level that the session uses, as Claude Code reports it. Nil for
  -- a model without effort, and until the sidecar reports it.
  effort = nil, ---@type string?
  permission_mode = "bypassPermissions",
  cwd = vim.fn.getcwd(),
  branch = nil, ---@type string?
  busy = false,
  thinking = false,
  turn_started = nil, ---@type integer? uv.now() at turn start
  last_turn = nil, ---@type { duration_ms: integer, cost_usd: number }?
  cost_usd = 0,
  -- Turns that this session has saved. Only such a session can be resumed.
  turns = 0,
  context = nil, ---@type { percent: number, tokens: integer, max: integer }?
  compacting = false,
  -- Set while a permission prompt waits for the user: the hint that says how
  -- to answer.
  waiting = nil, ---@type string?
  ---@type 'starting'|'ready'|'exited'
  process = "starting",
}

return M
