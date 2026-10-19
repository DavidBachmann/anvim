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
