-- Session state that several views read: the footer, the transcript, follow mode.
local M = {
  session_id = nil, ---@type string?
  model = nil, ---@type string?
  permission_mode = "default",
  cwd = vim.fn.getcwd(),
  branch = nil, ---@type string?
  busy = false,
  thinking = false,
  turn_started = nil, ---@type integer? uv.now() at turn start
  last_turn = nil, ---@type { duration_ms: integer, cost_usd: number }?
  cost_usd = 0,
  -- Set while a permission prompt waits for the user: the hint that says how
  -- to answer.
  waiting = nil, ---@type string?
  ---@type 'starting'|'ready'|'exited'
  process = "starting",
}

return M
