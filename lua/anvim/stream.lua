-- Streams Edit and Write tool calls into buffers while Claude generates them.
-- Edit: the old text is struck through and the new text grows after it, in
-- the real buffer. Write: the content grows in a preview buffer. When the tool
-- result arrives, the buffer reloads from disk and the change flashes.
local follow = require("anvim.follow")
local sidecar = require("anvim.sidecar")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.stream")

local TICK_MS = 16
local MIN_CHARS = 2
-- A delta that arrives this long after the previous one starts a new burst.
local BURST_MS = 25

---@class anvim.Preview
---@field id string
---@field name 'Edit'|'Write'
---@field path string?
---@field buf integer?
---@field head [integer, integer]? 0-based row and byte col of the next insert
---@field tick integer? changedtick after our last change
---@field queue string
---@field ticks integer ticks left to show the queue
---@field gap integer ms between the last two bursts
---@field last_data integer?
---@field input_done boolean
---@field waiting integer[] await_preview requests to answer when caught up
---@field marks integer[]
---@field cursor integer?
---@field held boolean
---@field dead boolean

---@type table<string, anvim.Preview>
local previews = {}
---@type uv.uv_timer_t?
local timer
local run

local has_busy = vim.fn.exists("+busy") == 1

-- Buffers that previews write into. While held, a buffer is busy and its
-- diagnostics are off, because the LSP server sees half-written code.
-- `User AnvimPreviewStart` and `AnvimPreviewEnd` let other plugins keep
-- their hands off it.
---@type table<integer, { n: integer, diagnostics: boolean }>
local held = {}

local function hold(p)
  local buf = p.buf
  if p.held or not (buf and api.nvim_buf_is_valid(buf)) then
    return
  end
  p.held = true
  local h = held[buf]
  if not h then
    h = { n = 0, diagnostics = vim.diagnostic.is_enabled({ bufnr = buf }) }
    held[buf] = h
    if h.diagnostics then
      vim.diagnostic.enable(false, { bufnr = buf })
    end
    if has_busy then
      vim.bo[buf].busy = vim.bo[buf].busy + 1
    end
    api.nvim_exec_autocmds("User", { pattern = "AnvimPreviewStart", data = { buf = buf }, modeline = false })
  end
  h.n = h.n + 1
end

local function release(p)
  local buf = p.buf
  local h = buf and held[buf]
  if not (p.held and h) then
    return
  end
  p.held = false
  h.n = h.n - 1
  if h.n > 0 then
    return
  end
  held[buf] = nil
  if api.nvim_buf_is_valid(buf) then
    if h.diagnostics then
      vim.diagnostic.enable(true, { bufnr = buf })
    end
    if has_busy then
      vim.bo[buf].busy = math.max(0, vim.bo[buf].busy - 1)
    end
    api.nvim_exec_autocmds("User", { pattern = "AnvimPreviewEnd", data = { buf = buf }, modeline = false })
  end
end

local function with_modifiable(buf, fn)
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = was
  vim.bo[buf].modified = false
  if not ok then
    error(err, 0)
  end
end

local function answer(p)
  for _, req in ipairs(p.waiting) do
    sidecar.send({ type = "preview_done", req = req })
  end
  p.waiting = {}
end

local function caught_up(p)
  return p.dead or (p.input_done and p.queue == "")
end

local function clear_marks(p)
  if p.buf and api.nvim_buf_is_valid(p.buf) then
    for _, mark in ipairs(p.marks) do
      api.nvim_buf_del_extmark(p.buf, ns, mark)
    end
    if p.cursor then
      api.nvim_buf_del_extmark(p.buf, ns, p.cursor)
    end
  end
  p.marks, p.cursor = {}, nil
end

local function kill(p)
  p.dead = true
  p.queue = ""
  clear_marks(p)
  answer(p)
end

---@return integer row, integer col 0-based position of a byte offset (1-based) in lines
local function position(lines, offset)
  local row, start = 0, 1
  for i, line in ipairs(lines) do
    if offset <= start + #line then
      return i - 1, offset - start
    end
    start = start + #line + 1
    row = i
  end
  -- Past the final newline: clamp to the end of the last line.
  return math.max(row - 1, 0), #(lines[row] or "")
end

-- Strikes through old_string and puts the insert head right after it.
local function place_edit(p, old)
  local lines = api.nvim_buf_get_lines(p.buf, 0, -1, false)
  local s, e = (table.concat(lines, "\n") .. "\n"):find(old, 1, true)
  if not s then
    kill(p)
    return
  end
  local srow, scol = position(lines, s)
  local erow, ecol = position(lines, e + 1)
  local mark_end = { erow, ecol }
  -- Like a diff: removed lines, then added lines. Start the new text on its own line.
  if ecol > 0 then
    with_modifiable(p.buf, function()
      api.nvim_buf_set_text(p.buf, erow, ecol, erow, ecol, { "", "" })
    end)
    if ecol == #lines[erow + 1] then
      mark_end = { erow + 1, 0 }
    end
    erow, ecol = erow + 1, 0
  end
  p.marks[#p.marks + 1] = api.nvim_buf_set_extmark(p.buf, ns, srow, scol, {
    end_row = mark_end[1],
    end_col = mark_end[2],
    end_right_gravity = false,
    hl_group = "AnvimDelete",
    hl_eol = true,
    priority = 200,
  })
  p.head = { erow, ecol }
  follow.track(p.path, srow + 1)
end

local function begin_insert(p)
  local row, col = p.head[1], p.head[2]
  p.marks[#p.marks + 1] = api.nvim_buf_set_extmark(p.buf, ns, row, col, {
    end_row = row,
    end_col = col,
    right_gravity = false,
    end_right_gravity = true,
    hl_group = "AnvimInsert",
    hl_eol = true,
    priority = 200,
  })
  p.tick = api.nvim_buf_get_changedtick(p.buf)
  run()
end

local function draw_cursor(p)
  local row, col = p.head[1], p.head[2]
  p.cursor = api.nvim_buf_set_extmark(p.buf, ns, row, col, {
    id = p.cursor,
    virt_text = { { "▍", "AnvimClaude" } },
    virt_text_pos = "inline",
    right_gravity = true,
  })
  local win = require("anvim.layout").wins.code
  if follow.shows() and win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == p.buf then
    api.nvim_win_set_cursor(win, { row + 1, col })
  end
end

local function insert(p, text)
  if not api.nvim_buf_is_valid(p.buf) or api.nvim_buf_get_changedtick(p.buf) ~= p.tick then
    kill(p)
    return
  end
  local parts = vim.split(text, "\n", { plain = true })
  local row, col = p.head[1], p.head[2]
  with_modifiable(p.buf, function()
    api.nvim_buf_set_text(p.buf, row, col, row, col, parts)
  end)
  if #parts == 1 then
    p.head = { row, col + #parts[1] }
  else
    p.head = { row + #parts - 1, #parts[#parts] }
  end
  p.tick = api.nvim_buf_get_changedtick(p.buf)
  draw_cursor(p)
end

-- Cuts at most n bytes off the front of s without splitting a UTF-8 character.
local function take(s, n)
  if n >= #s then
    return s, ""
  end
  while n < #s and bit.band(s:byte(n + 1), 0xC0) == 0x80 do
    n = n + 1
  end
  return s:sub(1, n), s:sub(n + 1)
end

local function step()
  local active = false
  for _, p in pairs(previews) do
    if not p.dead and p.head and p.queue ~= "" then
      local n = math.max(MIN_CHARS, math.ceil(#p.queue / math.max(p.ticks, 1)))
      local chunk
      chunk, p.queue = take(p.queue, n)
      p.ticks = math.max(1, p.ticks - 1)
      insert(p, chunk)
    end
    if caught_up(p) then
      answer(p)
    else
      active = active or (p.head ~= nil and p.queue ~= "")
    end
  end
  if not active and timer then
    timer:stop()
  end
end

function run()
  timer = timer or vim.uv.new_timer()
  if not timer:is_active() then
    timer:start(0, TICK_MS, vim.schedule_wrap(step))
  end
end

local function on_delta(p, text)
  local now = vim.uv.now()
  if p.last_data and now - p.last_data > BURST_MS then
    p.gap = now - p.last_data
  end
  p.last_data = now
  p.queue = p.queue .. text
  -- Spread each burst over the expected gap until the next one.
  p.ticks = math.min(math.max(math.floor(p.gap / TICK_MS), 4), 45)
  run()
end

local function finish_input(p)
  p.input_done = true
  p.ticks = math.min(p.ticks, 6)
  run()
end

local function open_write_preview(p)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "anvim://write/" .. p.path)
  vim.b[buf].anvim_preview = p.path
  local ft = vim.filetype.match({ filename = p.path })
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].modifiable = false
  p.buf = buf
  hold(p)
  p.head = { 0, 0 }
  begin_insert(p)
  follow.track(p.path, 1, buf)
end

local stream_keys = { Edit = "new_string", Write = "content" }

function M.on_field(ev)
  local p = previews[ev.id]
  if not p or p.dead then
    return
  end
  if ev.key == "file_path" and ev.phase == "end" then
    p.path = ev.value
    if p.name == "Write" then
      open_write_preview(p)
    elseif vim.uv.fs_stat(p.path) then
      p.buf = follow.load(p.path)
      hold(p)
    else
      kill(p)
    end
  elseif p.name == "Edit" and ev.key == "old_string" and ev.phase == "end" then
    if p.buf then
      place_edit(p, ev.value)
      if p.head then
        begin_insert(p)
      end
    end
  elseif ev.key == stream_keys[p.name] then
    if ev.phase == "delta" then
      on_delta(p, ev.text)
    elseif ev.phase == "end" then
      finish_input(p)
    end
  end
end

function M.on_start(ev)
  if stream_keys[ev.name] then
    previews[ev.id] = {
      id = ev.id,
      name = ev.name,
      queue = "",
      ticks = 4,
      gap = 250,
      input_done = false,
      waiting = {},
      marks = {},
      held = false,
      dead = false,
    }
  end
end

function M.on_await(ev)
  local p = previews[ev.tool_use_id]
  if p and not caught_up(p) then
    table.insert(p.waiting, ev.req)
    finish_input(p)
  else
    sidecar.send({ type = "preview_done", req = ev.req })
  end
end

---@return integer[] 0-based rows that a structuredPatch added
function M.added_rows(patch)
  local rows = {}
  for _, hunk in ipairs(patch or {}) do
    local row = (hunk.newStart or 1) - 1
    for _, line in ipairs(hunk.lines or {}) do
      local c = line:sub(1, 1)
      if c == "+" then
        rows[#rows + 1] = row
        row = row + 1
      elseif c == " " then
        row = row + 1
      end
    end
  end
  return rows
end

local function reload(buf)
  if api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_call(buf, function()
      vim.cmd("silent! keepjumps edit!")
    end)
  end
end

local function finish_write(p, ev)
  local preview = p.buf
  if not ev.is_error and vim.uv.fs_stat(p.path) then
    local buf = follow.load(p.path)
    reload(buf)
    local showing = preview and vim.fn.win_findbuf(preview)[1]
    if showing then
      api.nvim_win_set_buf(showing, buf)
    end
    local rows = M.added_rows(type(ev.result) == "table" and ev.result.structuredPatch or nil)
    if #rows == 0 then
      for row = 0, math.min(api.nvim_buf_line_count(buf), 500) - 1 do
        rows[#rows + 1] = row
      end
    end
    follow.flash(buf, rows, "AnvimInsert")
    -- The preview goes, so a catch-up lands on the file.
    follow.track(p.path, (rows[1] or 0) + 1)
  end
  release(p)
  if preview and api.nvim_buf_is_valid(preview) then
    api.nvim_buf_delete(preview, { force = true })
  end
end

function M.on_result(ev)
  local p = previews[ev.id]
  if not p then
    return
  end
  previews[ev.id] = nil
  kill(p)
  if p.name == "Write" and p.path then
    finish_write(p, ev)
  elseif p.buf then
    reload(p.buf)
    release(p)
    local rows = M.added_rows(type(ev.result) == "table" and ev.result.structuredPatch or nil)
    follow.flash(p.buf, rows, "AnvimInsert")
    if rows[1] and p.path then
      follow.track(p.path, rows[1] + 1)
    end
  end
end

-- Ends every open preview as failed, when the turn ends or the sidecar exits.
function M.cancel_all()
  for id in pairs(previews) do
    M.on_result({ id = id, is_error = true })
  end
end

---@return boolean
function M.idle(id)
  local p = previews[id]
  return not p or caught_up(p)
end

function M.attach()
  sidecar.on("tool_start", M.on_start)
  sidecar.on("tool_field", M.on_field)
  sidecar.on("tool_input_end", function(ev)
    local p = previews[ev.id]
    if p then
      finish_input(p)
    end
  end)
  sidecar.on("await_preview", M.on_await)
  sidecar.on("tool_result", M.on_result)
  sidecar.on("turn_end", M.cancel_all)
  sidecar.on("exit", M.cancel_all)
end

return M
