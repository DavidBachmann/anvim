-- Streams Edit and Write tool calls into buffers while Claude generates them.
-- Edit: the old text is struck through and the new text grows after it, in
-- the real buffer. Write: the content grows in a preview buffer. When the tool
-- result arrives, the buffer reloads from disk and the change flashes.
-- A subagent's edits arrive whole. While the user follows that agent, its
-- preview types the new text in the same way.
local agents = require("anvim.agents")
local follow = require("anvim.follow")
local sidecar = require("anvim.sidecar")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.stream")

local TICK_MS = 16
local MIN_CHARS = 2
-- A delta that arrives this long after the previous one starts a new burst.
local BURST_MS = 25
-- A typed preview goes at about the speed of the main agent's streamed
-- input, and takes at most TYPE_MAX_MS, so that it holds its agent briefly.
local TYPE_BYTES_PER_S = 500
local TYPE_MAX_MS = 2000
local FLASH_MAX = 500

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
---@field agent string? The subagent whose whole edit this preview types.
---@field deadline number? hrtime in ms when a typed preview must have caught up, from its first tick
---@field group string? The cursor's color
---@field before string[]? The text before the preview, for the flash when a result has no patch
---@field scrolled_back boolean? scroll_back() ran after the catch-up

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
  p.before = lines
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
  follow.track(p.path, srow + 1, nil, p.agent)
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

-- The code window, while it shows the preview and the user follows its agent.
local function following(p)
  local win = require("anvim.layout").wins.code
  if follow.shows(p.agent) and win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == p.buf then
    return win
  end
end

local function draw_cursor(p)
  local row, col = p.head[1], p.head[2]
  p.cursor = api.nvim_buf_set_extmark(p.buf, ns, row, col, {
    id = p.cursor,
    virt_text = { { "▍", p.group or "AnvimClaude" } },
    virt_text_pos = "inline",
    right_gravity = true,
  })
  local win = following(p)
  if win then
    api.nvim_win_set_cursor(win, { row + 1, col })
  end
end

-- Without wrap, the cursor at the end of a long line scrolls the view right.
-- Once the preview has caught up, the cursor goes to the start of its line,
-- so the view shows the left edge of the edit until the result, which moves
-- the cursor to column 0 too. In review mode, the view is the user's.
local function scroll_back(p)
  local win = following(p)
  if win and not vim.wo[win].wrap then
    api.nvim_win_set_cursor(win, { api.nvim_win_get_cursor(win)[1], 0 })
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
  local now = vim.uv.hrtime() / 1e6
  for _, p in pairs(previews) do
    if not p.dead and p.head and p.queue ~= "" then
      if p.agent then
        -- The rest spreads over the time left. Once the user stops following
        -- the agent, it goes in at once. The time starts after the file has
        -- loaded, so the pace stays steady.
        p.deadline = p.deadline or now + math.min(#p.queue * 1000 / TYPE_BYTES_PER_S, TYPE_MAX_MS)
        p.ticks = follow.shows(p.agent) and math.floor((p.deadline - now) / TICK_MS) or 0
      end
      local n = math.max(MIN_CHARS, math.ceil(#p.queue / math.max(p.ticks, 1)))
      local chunk
      chunk, p.queue = take(p.queue, n)
      p.ticks = math.max(1, p.ticks - 1)
      insert(p, chunk)
    end
    if caught_up(p) then
      answer(p)
      if not (p.dead or p.scrolled_back) then
        p.scrolled_back = true
        scroll_back(p)
      end
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

local function file_lines(path)
  -- bufnr() also matches part of a name, such as a.lua in a.lua.orig.
  local buf = vim.fn.bufnr(path)
  if buf > 0 and api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) == path then
    return api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

local function open_write_preview(p)
  p.before = file_lines(p.path)
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
  follow.track(p.path, 1, buf, p.agent)
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

---@return anvim.Preview
local function new(id, name)
  return {
    id = id,
    name = name,
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

function M.on_start(ev)
  if stream_keys[ev.name] then
    previews[ev.id] = new(ev.id, ev.name)
  end
end

-- A subagent's edit comes whole, in the hook's input, which can come before
-- or after its tool_use. Only the edits of the agent that the user follows
-- get a preview and wait for it.
---@return anvim.Preview?
local function type_edit(ev)
  local input = type(ev.input) == "table" and ev.input or {}
  local path, text = input.file_path, stream_keys[ev.name] and input[stream_keys[ev.name]]
  if not (follow.shows(ev.agent_id) and type(path) == "string" and type(text) == "string") then
    return
  elseif ev.name == "Edit" and not (type(input.old_string) == "string" and vim.uv.fs_stat(path)) then
    return
  end
  local p = new(ev.tool_use_id, ev.name)
  local agent = agents.get(ev.agent_id)
  p.agent, p.path, p.group = ev.agent_id, path, agents.group(agent and agent.slot)
  p.queue, p.input_done = text, true
  previews[p.id] = p
  if p.name == "Write" then
    open_write_preview(p)
  else
    p.buf = follow.load(path)
    hold(p)
    place_edit(p, input.old_string)
    if p.head then
      begin_insert(p)
    end
  end
  return p
end

function M.on_await(ev)
  local p = previews[ev.tool_use_id]
  if not p and ev.agent_id then
    local ok, res = pcall(type_edit, ev)
    if ok then
      p = res
    else
      -- The agent must not wait for a preview that broke.
      sidecar.log(("typed preview failed: %s"):format(res))
      if previews[ev.tool_use_id] then
        M.on_result({ id = ev.tool_use_id, is_error = true })
      end
    end
  end
  if p and not caught_up(p) then
    table.insert(p.waiting, ev.req)
    finish_input(p)
  else
    sidecar.send({ type = "preview_done", req = ev.req })
  end
end

-- Whether the tool call has a typed preview, which keeps its agent's place.
function M.typed(id)
  local p = previews[id]
  return p ~= nil and p.agent ~= nil and not p.dead
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

-- 0-based rows of after that a diff from before adds, the first FLASH_MAX of them.
local function diff_rows(before, after)
  local function text(lines)
    return #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
  end
  local rows = {}
  for _, h in ipairs(vim.text.diff(text(before), text(after), { result_type = "indices" })) do
    for row = h[3] - 1, h[3] + h[4] - 2 do
      if #rows == FLASH_MAX then
        return rows
      end
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- The rows that an edit added, from its patch. A subagent's result has no
-- patch, so a diff of the text before the preview and after the reload
-- finds them.
local function added(p, buf, ev)
  local rows = M.added_rows(type(ev.result) == "table" and ev.result.structuredPatch or nil)
  if #rows == 0 and p.before and not ev.is_error then
    rows = diff_rows(p.before, api.nvim_buf_get_lines(buf, 0, -1, false))
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
    local rows = added(p, buf, ev)
    follow.flash(buf, rows, "AnvimInsert")
    -- The preview goes, so a catch-up lands on the file.
    follow.track(p.path, (rows[1] or 0) + 1, nil, p.agent)
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
    local rows = added(p, p.buf, ev)
    follow.flash(p.buf, rows, "AnvimInsert")
    if rows[1] and p.path then
      follow.track(p.path, rows[1] + 1, nil, p.agent)
    end
  end
end

-- Ends every open preview as failed, when the sidecar exits.
function M.cancel_all()
  for id in pairs(previews) do
    M.on_result({ id = id, is_error = true })
  end
end

-- A background agent's preview outlives the main turn. agents.lua handles
-- turn_end first, so a foreground agent has ended by now.
local function turn_end()
  for id, p in pairs(previews) do
    local agent = p.agent and agents.get(p.agent)
    if not (agent and agent.status == "running") then
      M.on_result({ id = id, is_error = true })
    end
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
  sidecar.on("turn_end", turn_end)
  sidecar.on("exit", M.cancel_all)
end

return M
