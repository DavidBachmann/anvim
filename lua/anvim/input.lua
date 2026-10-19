-- The prompt box under the transcript, and the footer line below it.
local config = require('anvim.config')
local sidecar = require('anvim.sidecar')
local state = require('anvim.state')
local transcript = require('anvim.transcript')

local M = {}

local api = vim.api

---@type integer?
local bufnr
---@type uv.uv_timer_t?
local spinner_timer
local spinner_frames = { '·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢' }

local mode_labels = {
  acceptEdits = { '⏵⏵ accept edits on', 'AnvimModeEdits' },
  plan = { '⏸ plan mode on', 'AnvimModePlan' },
  bypassPermissions = { '⏵⏵ bypass permissions on', 'AnvimModeBypass' },
}

function M.buf()
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, 'anvim://input')
  vim.bo[bufnr].filetype = 'markdown'
  local map = function(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = bufnr, desc = desc })
  end
  map({ 'i', 'n' }, '<CR>', M.submit, 'Send prompt')
  map('i', '<S-CR>', '<CR>', 'New line')
  map('i', '<M-CR>', '<CR>', 'New line')
  map('n', '<Esc>', M.interrupt, 'Interrupt Claude')
  map({ 'i', 'n' }, '<C-c>', M.interrupt, 'Interrupt Claude')
  map({ 'i', 'n' }, '<S-Tab>', M.cycle_mode, 'Cycle permission mode')
  return bufnr
end

function M.setup_win(win)
  local wo = vim.wo[win]
  wo.statuscolumn = "%#AnvimPrompt#%{v:lnum == 1 && v:virtnum == 0 ? '❯ ' : '  '}"
  wo.statusline = "%!v:lua.require'anvim.input'.footer()"
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.cursorline = false
  wo.wrap = true
  wo.linebreak = true
  wo.winfixheight = true
  wo.winfixbuf = true
end

function M.submit()
  local buf = M.buf()
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
  if text == '' then
    return
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  M.send(text)
end

function M.send(text)
  transcript.user(text)
  sidecar.send({ type = 'prompt', text = text })
  if not state.busy then
    M.set_busy(true)
  end
end

function M.interrupt()
  if state.busy then
    sidecar.send({ type = 'interrupt' })
  end
end

function M.modes()
  local modes = { 'default', 'acceptEdits', 'plan' }
  if config.options.permission_mode == 'bypassPermissions' then
    table.insert(modes, 'bypassPermissions')
  end
  return modes
end

function M.cycle_mode()
  local modes = M.modes()
  local next_mode = modes[1]
  for i, mode in ipairs(modes) do
    if mode == state.permission_mode then
      next_mode = modes[i % #modes + 1]
    end
  end
  state.permission_mode = next_mode
  sidecar.send({ type = 'set_permission_mode', mode = next_mode })
  M.redraw()
end

function M.redraw()
  vim.cmd('redrawstatus!')
end

function M.set_busy(busy)
  state.busy = busy
  if busy then
    state.turn_started = vim.uv.now()
    spinner_timer = spinner_timer or vim.uv.new_timer()
    spinner_timer:start(0, 120, vim.schedule_wrap(M.redraw))
  else
    state.turn_started = nil
    state.thinking = false
    if spinner_timer then
      spinner_timer:stop()
    end
    M.redraw()
  end
end

local function esc(s)
  return (tostring(s):gsub('%%', '%%%%'))
end

-- claude-opus-5-5 -> Opus 5.5
function M.model_label(model)
  if not model then
    return 'Claude'
  end
  local family, version = model:gsub('^claude%-', ''):match('^(%a+)%-([%d%-]+)')
  if not family then
    return model
  end
  version = version:gsub('%-%d%d%d%d%d%d%d%d$', ''):gsub('%-', '.')
  return family:sub(1, 1):upper() .. family:sub(2) .. ' ' .. version
end

local function status_width()
  local win = vim.g.statusline_winid
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_width(win) or vim.o.columns
end

-- The line between transcript and input: a rule, with the spinner while Claude works.
function M.activity()
  local text, width = '', 0
  if state.process == 'exited' then
    text, width = '%#AnvimToolError#sidecar exited ', 15
  elseif state.busy and state.turn_started then
    local frame = spinner_frames[math.floor(vim.uv.now() / 120) % #spinner_frames + 1]
    local secs = math.floor((vim.uv.now() - state.turn_started) / 1000)
    local verb = state.thinking and 'Thinking...' or 'Working...'
    local hint = ('(%ds · esc to interrupt)'):format(secs)
    text = ('%%#AnvimClaude#%s %s %%#Comment#%s '):format(frame, verb, hint)
    width = vim.fn.strdisplaywidth(('%s %s %s '):format(frame, verb, hint))
  elseif state.last_turn then
    local info = ('%.1fs · $%.2f '):format(state.last_turn.duration_ms / 1000, state.cost_usd)
    text, width = '%#Comment#' .. info, vim.fn.strdisplaywidth(info)
  end
  return text .. '%#WinSeparator#' .. ('─'):rep(math.max(0, status_width() - width))
end

function M.footer()
  local left = ('%%#AnvimClaude# anvim %%#Comment#%s %%#Normal#%s'):format(
    state.branch and ('git:(' .. esc(state.branch) .. ')') or '',
    esc(M.model_label(state.model or config.options.model))
  )
  local mode = mode_labels[state.permission_mode]
  if not mode then
    return left
  end
  local hint = status_width() >= 70 and ' %#Comment#(shift+tab to cycle)' or ''
  return ('%s%%=%%#%s#%s%s '):format(left, mode[2], mode[1], hint)
end

function M.attach()
  sidecar.on('turn_start', function()
    M.set_busy(true)
  end)
  sidecar.on('turn_end', function(ev)
    state.last_turn = { duration_ms = ev.duration_ms, cost_usd = ev.cost_usd }
    state.cost_usd = ev.cost_usd
    M.set_busy(false)
  end)
  sidecar.on('thinking_start', function()
    state.thinking = true
  end)
  sidecar.on('thinking_stop', function()
    state.thinking = false
  end)
  sidecar.on('exit', function()
    M.set_busy(false)
  end)
end

return M
