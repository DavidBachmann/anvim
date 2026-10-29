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
  -- Turns that this session has saved. Only such a session can be resumed.
  turns = 0,
  -- The chain entry that a /rewind resumed at. Until a turn saves, Claude
  -- Code still keeps the rewound prompts in the session's chain.
  resume_at = nil, ---@type string?
  context = nil, ---@type { percent: number, tokens: integer, max: integer }?
  -- The email of Claude Code's login, as the sidecar reports it at start.
  email = nil, ---@type string?
  -- The plan's 5-hour and weekly usage in percent.
  limits = nil, ---@type { session: number?, week: number? }?
  -- Whether Claude got the codex tool at this start, as the sidecar reports it.
  codex = nil, ---@type 'on'|'off'|'missing'|'logged_out'|nil
  -- The model and the effort that Codex's config.toml sets, as far as the sidecar could read them.
  codex_config = nil, ---@type { model: string?, effort: string? }?
  -- Codex's models, when the sidecar could read its model list.
  codex_models = nil, ---@type { slug: string, name: string, hidden: boolean, efforts: string[] }[]?
  compacting = false,
  -- Set while a permission prompt waits for the user: the hint that says how
  -- to answer.
  waiting = nil, ---@type string?
  ---@type 'starting'|'ready'|'exited'
  process = "starting",
}

return M
