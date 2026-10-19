-- Headless tests. Run: nvim --clean --headless -l test/run.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(root)

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(('%s\nexpected: %s\nactual:   %s'):format(msg or 'not equal', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function contains(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern) then
      return true
    end
  end
  error(('no line matches %q in:\n%s'):format(pattern, table.concat(lines, '\n')), 2)
end

-- A temp project with the fixture file, and a recording rewritten to point at it.
local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, 'p')
local fixtures = root .. '/test/fixtures'
vim.fn.writefile(vim.fn.readfile(fixtures .. '/matchparen.lua'), tmp .. '/matchparen.lua')
local recording = tmp .. '/session.jsonl'
local lines = vim.fn.readfile(fixtures .. '/edit-session.jsonl')
for i, line in ipairs(lines) do
  lines[i] = line:gsub('/ANVIM_FIXTURE', tmp)
end
vim.fn.writefile(lines, recording)
vim.cmd.cd(tmp)

local anvim = require('anvim')
local input = require('anvim.input')
local layout = require('anvim.layout')
local readonly = require('anvim.readonly')
local state = require('anvim.state')
local transcript = require('anvim.transcript')

anvim.setup({
  permission_mode = 'bypassPermissions',
  sidecar_cmd = { 'bun', root .. '/sidecar/src/replay.ts', recording, '50' },
})

test('model labels', function()
  eq('Opus 5.5', input.model_label('claude-opus-5-5'))
  eq('Sonnet 4.5', input.model_label('claude-sonnet-4-5-20250929'))
  eq('opus', input.model_label('opus'))
  eq('Claude', input.model_label(nil))
end)

test('layout has code, transcript and input windows', function()
  anvim.start()
  vim.wait(100)
  for _, role in ipairs({ 'code', 'transcript', 'input' }) do
    assert(vim.api.nvim_win_is_valid(layout.wins[role]), role .. ' window missing')
  end
  eq(transcript.buf(), vim.api.nvim_win_get_buf(layout.wins.transcript))
  eq(input.buf(), vim.api.nvim_win_get_buf(layout.wins.input))
  eq(layout.wins.input, vim.api.nvim_get_current_win())
end)

test('a replayed turn renders like Claude Code', function()
  vim.wait(5000, function()
    return state.process == 'ready'
  end)
  input.send('Add a comment')
  assert(state.busy, 'busy right after send')
  assert(input.activity():find('Working'), 'activity line shows the spinner')
  assert(input.footer():find('bypass permissions'), 'footer shows the mode')
  assert(
    vim.wait(10000, function()
      return not state.busy
    end),
    'turn did not end'
  )
  local out = vim.api.nvim_buf_get_lines(transcript.buf(), 0, -1, false)
  eq('❯ Add a comment', out[1])
  contains(out, '^⏺ Read%(matchparen%.lua%)$')
  contains(out, '^  ⎿  Read %d+ lines$')
  contains(out, '^⏺ Edit%(matchparen%.lua%)$')
  contains(out, '^  ⎿  Added %d+ lines?, removed %d+ lines?$')
  contains(out, '^⏺ %a')
  eq('Opus 5.5', input.model_label(state.model))
  assert(not vim.bo[transcript.buf()].modifiable, 'transcript is read-only')
  eq(vim.fn.bufnr(tmp .. '/matchparen.lua'), vim.api.nvim_win_get_buf(layout.wins.code), 'code window followed')
end)

local sidecar = require('anvim.sidecar')
local follow = require('anvim.follow')

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function field(id, name, key, phase, x)
  sidecar.dispatch({
    type = 'tool_field',
    id = id,
    name = name,
    key = key,
    phase = phase,
    text = phase == 'delta' and x or nil,
    value = phase == 'end' and x or nil,
  })
end

local function hl_groups(buf, ns_name)
  local groups = {}
  local ns = vim.api.nvim_get_namespaces()[ns_name]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local group = mark[4].hl_group or mark[4].line_hl_group
    if group then
      groups[group] = (groups[group] or 0) + 1
    end
  end
  return groups
end

-- Captures what the plugin sends to the sidecar while fn runs.
local function capture_sends(fn)
  local sent, send = {}, sidecar.send
  sidecar.send = function(msg)
    sent[#sent + 1] = msg
  end
  local ok, err = pcall(fn, sent)
  sidecar.send = send
  if not ok then
    error(err, 0)
  end
end

test('an Edit streams into the real buffer while following', function()
  local file = tmp .. '/stream.lua'
  vim.fn.writefile({ 'local a = 1', 'local b = 2', 'return a' }, file)
  layout.focus_input()
  capture_sends(function(sent)
    sidecar.dispatch({ type = 'tool_start', id = 'e1', name = 'Edit' })
    field('e1', 'Edit', 'file_path', 'start')
    field('e1', 'Edit', 'file_path', 'end', file)
    field('e1', 'Edit', 'old_string', 'start')
    field('e1', 'Edit', 'old_string', 'end', 'local b = 2')
    local buf = vim.fn.bufnr(file)
    eq(buf, vim.api.nvim_win_get_buf(layout.wins.code), 'code window shows the edited file')
    field('e1', 'Edit', 'new_string', 'start')
    field('e1', 'Edit', 'new_string', 'delta', 'local b = 3\nlocal c')
    field('e1', 'Edit', 'new_string', 'delta', ' = 4')
    field('e1', 'Edit', 'new_string', 'end', 'local b = 3\nlocal c = 4')
    sidecar.dispatch({ type = 'await_preview', req = 7, tool_use_id = 'e1' })
    assert(
      vim.wait(2000, function()
        return #sent > 0
      end),
      'preview_done was not sent'
    )
    eq({ type = 'preview_done', req = 7 }, sent[1])
    eq({ 'local a = 1', 'local b = 2', 'local b = 3', 'local c = 4', 'return a' }, buf_lines(buf))
    local groups = hl_groups(buf, 'anvim.stream')
    eq(1, groups.AnvimDelete, 'old text is struck through')
    eq(1, groups.AnvimInsert, 'new text is marked')
    assert(not vim.bo[buf].modifiable and not vim.bo[buf].modified, 'buffer stays read-only and unmodified')

    vim.fn.writefile({ 'local a = 1', 'local b = 3', 'local c = 4', 'return a' }, file)
    sidecar.dispatch({
      type = 'tool_result',
      id = 'e1',
      is_error = false,
      text = 'ok',
      result = {
        structuredPatch = {
          { newStart = 1, lines = { ' local a = 1', '-local b = 2', '+local b = 3', '+local c = 4', ' return a' } },
        },
      },
    })
    eq({ 'local a = 1', 'local b = 3', 'local c = 4', 'return a' }, buf_lines(buf))
    eq({}, hl_groups(buf, 'anvim.stream'), 'preview marks are gone')
    eq(2, hl_groups(buf, 'anvim.follow').AnvimInsert, 'added lines flash')
    eq(2, vim.api.nvim_win_get_cursor(layout.wins.code)[1], 'cursor on the first added line')
  end)
end)

test('a Write streams into a paced preview, then shows the file', function()
  local file = tmp .. '/new_file.lua'
  local content = ('-- x\n'):rep(150)
  layout.focus_input()
  capture_sends(function()
    sidecar.dispatch({ type = 'tool_start', id = 'w1', name = 'Write' })
    field('w1', 'Write', 'file_path', 'end', file)
    field('w1', 'Write', 'content', 'start')
    field('w1', 'Write', 'content', 'delta', content)
    vim.wait(20)
    local preview = vim.api.nvim_win_get_buf(layout.wins.code)
    eq(file, vim.b[preview].anvim_preview)
    eq('lua', vim.bo[preview].filetype)
    local shown = #table.concat(buf_lines(preview), '\n')
    assert(shown > 0 and shown < #content, ('the preview is paced, but showed %d of %d bytes'):format(shown, #content))
    field('w1', 'Write', 'content', 'end', content)
    assert(
      vim.wait(2000, function()
        return require('anvim.stream').idle('w1')
      end),
      'preview never caught up'
    )
    eq(151, #buf_lines(preview))
    vim.fn.writefile(vim.split(content, '\n', { plain = true }), file, 'b')
    sidecar.dispatch({ type = 'tool_result', id = 'w1', is_error = false, text = 'ok', result = { type = 'create' } })
    local buf = vim.api.nvim_win_get_buf(layout.wins.code)
    eq(file, vim.api.nvim_buf_get_name(buf))
    eq(150, #buf_lines(buf))
    assert(not vim.api.nvim_buf_is_valid(preview), 'preview buffer was deleted')
  end)
end)

test('when not following, the statusline points at Claude and focus catches up', function()
  local file = tmp .. '/stream.lua'
  vim.api.nvim_set_current_win(layout.wins.code)
  local before = vim.api.nvim_win_get_buf(layout.wins.code)
  sidecar.dispatch({ type = 'tool_use', id = 'r1', name = 'Read', input = { file_path = file, offset = 3 } })
  eq(before, vim.api.nvim_win_get_buf(layout.wins.code), 'code window stays put')
  local status = follow.status(layout.wins.code)
  assert(status:find('Claude at stream.lua:3', 1, true), status)
  layout.focus_input()
  eq(vim.fn.bufnr(file), vim.api.nvim_win_get_buf(layout.wins.code), 'focusing the input catches up')
  eq(3, vim.api.nvim_win_get_cursor(layout.wins.code)[1])
  assert(follow.status(layout.wins.code):find('following', 1, true))
end)

test('file buffers are read-only and reload on change', function()
  local file = tmp .. '/matchparen.lua'
  vim.api.nvim_win_call(layout.code_win(), function()
    vim.cmd.edit(file)
  end)
  local buf = vim.fn.bufnr(file)
  assert(not vim.bo[buf].modifiable, 'file buffer is modifiable')
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, { 'x' })
  assert(not ok, 'edit was allowed')
  vim.fn.writefile({ '-- changed by Claude' }, file)
  vim.wait(50)
  readonly.reload()
  eq({ '-- changed by Claude' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  assert(not vim.bo[buf].modifiable, 'reload made the buffer modifiable')
end)

local failed = 0
for _, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  io.stdout:write(('%s %s\n'):format(ok and 'ok  ' or 'FAIL', t.name))
  if not ok then
    failed = failed + 1
    io.stdout:write('  ' .. tostring(err):gsub('\n', '\n  ') .. '\n')
  end
end
io.stdout:write(('%d/%d passed\n'):format(#tests - failed, #tests))
require('anvim.sidecar').stop()
vim.fn.delete(tmp, 'rf')
os.exit(failed == 0 and 0 or 1)
