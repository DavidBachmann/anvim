-- Follow mode: while the cursor is in the prompt, the code window shows where
-- Claude reads and writes. Elsewhere the user is in control, and the
-- statusline says where Claude is. Follow mode follows one agent: the main
-- agent, or the subagent that the user focused.
local agents = require("anvim.agents")
local bashread = require("anvim.bashread")
local input = require("anvim.input")
local layout = require("anvim.layout")
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.follow")

-- A Bash call can read several files. While following, the code window shows
-- them one by one. Each file stays step_ms, twice the time of a Read's flash,
-- so the eye finds the file and its range before the next one comes. Four
-- files take 2.4 s, and a call that reads more shows its first three and its
-- last. The specs shorten it.
M.step_ms = 800
local MAX_STEPS = 4

---@class anvim.Place
---@field path string
---@field line integer
---@field buf integer? A buffer to show instead of the file, such as a Write preview.
---@field behind integer Moves of its agent that the code window did not show.
---@field ended boolean? The main agent's turn ended after this move, or before it.

-- Each agent's place, by agent_id. The main agent's has the key "".
---@type table<string, anvim.Place>
local places = {}
-- The subagent Writes of files that do not exist yet, by tool id.
---@type table<string, { agent: string, path: string }>
local writes = {}
-- The greps of Bash calls that wait for their hits, by tool id.
---@type table<string, { agent: string?, spec: anvim.Grep }>
local greps = {}
-- The reads of Bash calls that the code window has yet to show, by agent key.
---@type table<string, { reads: anvim.Step[], timer: uv.uv_timer_t }>
local steps = {}
-- The tool calls that wait for their result, with their agent's key. A
-- call that starts while another waits belongs to its batch, which Claude
-- sent at once.
---@type table<string, string>
local waiting = {}
-- Whether each of the main agent's calls started in a batch. Its tool_use
-- comes after its input streamed, and a result of the batch can come first.
---@type table<string, boolean>
local batched = {}

---@type string? The agent_id of the agent that follow mode follows. nil is the main agent.
M.focus = nil
-- The focused agent's name and task, for the notice after its slot is gone.
local focus_name

-- The compose window is the prompt too.
function M.enabled()
  local win = api.nvim_get_current_win()
  return layout.wins.input ~= nil and (win == layout.wins.input or win == require("anvim.compose").win())
end

-- Whether the focused agent's moves move the code window.
function M.following()
  return M.enabled()
end

-- Whether the moves of agent `id`, or of the main agent for nil, move the code window.
---@param id string?
function M.shows(id)
  return id == M.focus and M.following()
end

---@alias anvim.Mode 'follow'|'review'

-- Follow mode is a mode of its own, next to Vim's: the cursor is in the
-- prompt or the compose window. Anywhere else, the user reviews code.
---@type anvim.Mode
local mode = "review"
-- Whether the last window that set the mode was the prompt.
local in_prompt = false

---@alias anvim.Gutter { number: boolean, relativenumber: boolean, statuscolumn: string, signcolumn: string }

local GUTTER = { "number", "relativenumber", "statuscolumn", "signcolumn" }

---@type anvim.Gutter?
local review
-- The code window's gutter in follow mode, for one buffer. It has absolute
-- line numbers, and is as wide as the review gutter, so the text stays in
-- place when the mode changes. Its width stays while the buffer stays, because
-- the number column grows at 1000 lines, and would push a growing Write
-- preview to the right. It is a 'statuscolumn' of anvim's own, because
-- snacks' statuscolumn can keep the old width for a frame.
---@type { win: integer, buf: integer, options: anvim.Gutter }?
local gutter
-- A click that leaves follow mode changes the gutter at SafeState, before
-- the redraw. Neovim maps a click to a column with the drawn grid only while
-- the window needs no redraw, and a change of the gutter options needs one.
local deferred = false
---@type { win: integer, view: vim.fn.winsaveview.ret }? The window and view at the last press.
local pressed
local left_mouse = vim.keycode("<LeftMouse>")

---@return anvim.Mode
function M.mode()
  return mode
end

-- The code window's gutter in review mode, as the config sets it. It is read
-- once, at start, from the code window's global values.
---@return anvim.Gutter
function M.review_options()
  if not review then
    review = api.nvim_win_call(layout.code_win(), function()
      local ret = {}
      for _, name in ipairs(GUTTER) do
        ret[name] = vim.go[name]
      end
      return ret
    end)
  end
  return review
end

-- The number column has room for 3 digits from the start, so a Write preview
-- of a new file can grow to 999 lines in a gutter that keeps its width.
local DIGITS = 3

-- The review gutter for the buffer in `win`, as Neovim sizes it for the
-- widest line number: its width, the columns that its numbers have, and the
-- least 'numberwidth' that gives them room for DIGITS digits. Another
-- 'statuscolumn' than snacks' counts as Neovim's own columns.
---@param win integer
---@return { width: integer, room: integer, numberwidth: integer }
local function review_gutter(win)
  local o = M.review_options()
  local buf = api.nvim_win_get_buf(win)
  local digits = 0
  if o.number or o.relativenumber then
    -- 'relativenumber' alone counts up to the window's height.
    digits = #tostring(o.number and api.nvim_buf_line_count(buf) or vim.fn.winheight(win))
    digits = math.max(digits, DIGITS)
  end
  local numberwidth = vim.wo[win].numberwidth
  local signs = o.signcolumn == "yes" and 1 or tonumber(o.signcolumn:match("^yes:(%d)")) or 0
  if signs == 0 and o.signcolumn:match("^auto") then
    signs = tonumber(o.signcolumn:match("^auto:(%d)")) or 1
  end
  -- 'foldcolumn' "auto" counts as no column.
  local folds = tonumber(vim.wo[win].foldcolumn) or 0
  local others, width, least = folds + 2 * signs, 0, DIGITS + 1
  if o.statuscolumn:find("snacks.statuscolumn", 1, true) then
    -- A sign on each side of the number, and a space after it.
    local shown = o.signcolumn ~= "no"
    local left = shown and vim.b[buf].snacks_statuscolumn_left ~= false and 2 or 0
    local right = shown and vim.b[buf].snacks_statuscolumn_right ~= false and 2 or 0
    -- Neovim draws a 'statuscolumn' at least as wide as its own columns.
    width = math.max(left + right + (digits > 0 and digits + 1 or 0), (digits > 0 and numberwidth or 0) + others)
    least = left + right + DIGITS + 1 - others
    others = left + right
  else
    width = (digits > 0 and math.max(digits, numberwidth - 1) + 1 or 0) + others
  end
  if digits == 0 then
    return { width = width, room = 0, numberwidth = 1 }
  end
  return { width = width, room = width - others - 1, numberwidth = least }
end

---@param win integer
function M.review_width(win)
  return review_gutter(win).width
end

-- Each line's absolute number, right-aligned, then a space and up to two sign
-- columns at the right, next to the text. The sign columns take the columns
-- that review mode does not give its numbers. Without numbers in review, the
-- gutter has blanks instead. A number that does not fit, a wrapped row and a
-- virtual line show a space. The expression gives ' ', not '', because Neovim
-- does not pad an empty item. Neovim draws the number in LineNr, or in
-- CursorLineNr on the cursor's line. A click on a 'statuscolumn' runs only its
-- click function, so that enters the window.
---@param width integer
---@param room integer
---@return anvim.Gutter
local function follow_options(width, room)
  local signs = math.min(math.floor((width - (room > 0 and room + 1 or 0)) / 2), 2)
  local field = width - 2 * signs
  local column = (" "):rep(field)
  if room > 0 then
    column = ("%%%d{v:virtnum == 0 && len(v:lnum) < %d ? v:lnum : ' '} "):format(field - 1, field)
  end
  column = column .. (signs > 0 and "%s" or "")
  return {
    number = false,
    relativenumber = false,
    statuscolumn = width > 0 and "%@v:lua.require'anvim.follow'.click_gutter@" .. column .. "%T" or "",
    signcolumn = signs > 0 and "yes:" .. signs or "no",
  }
end

-- As a click on Neovim's own number and sign columns, a click on the gutter
-- puts the cursor on that line. Neovim moved the cursor of the window that
-- the click came from, such as the prompt, so its view comes back first.
function M.click_gutter(_, _, button)
  local pos = vim.fn.getmousepos()
  if button == "l" and pos.winid ~= 0 and api.nvim_win_is_valid(pos.winid) and pos.line > 0 then
    local p = pressed
    if p and p.win == api.nvim_get_current_win() and p.win ~= pos.winid then
      vim.fn.winrestview(p.view)
    end
    api.nvim_set_current_win(pos.winid)
    api.nvim_win_set_cursor(pos.winid, { pos.line, 0 })
  end
end

---@param win integer
---@return anvim.Gutter
local function follow_gutter(win)
  local buf = api.nvim_win_get_buf(win)
  if not (gutter and gutter.win == win and gutter.buf == buf) then
    local columns = review_gutter(win)
    gutter = { win = win, buf = buf, options = follow_options(columns.width, columns.room) }
  end
  return gutter.options
end

-- Code wraps as the user chose, and text always wraps. The window's global
-- value is the choice, so a float that opens from the code window, such as a
-- picker's preview, wraps as code does. A wrapped row has no line number,
-- so a mark starts each wrapped row of code. An empty local
-- 'showbreak' would show the global one, and "NONE" shows none.
---@param win integer
local function apply_wrap(win)
  local wraps = layout.wraps()
  if api.nvim_get_option_value("wrap", { win = win, scope = "global" }) ~= wraps then
    api.nvim_set_option_value("wrap", wraps, { win = win, scope = "global" })
  end
  local text = layout.text_filetypes[vim.bo[api.nvim_win_get_buf(win)].filetype] == true
  for name, value in pairs({ wrap = wraps or text, showbreak = text and "NONE" or "↪ " }) do
    if vim.wo[win][0][name] ~= value then
      vim.wo[win][0][name] = value
    end
  end
end

-- Sets the gutter of the mode, and the code window's own options. These set
-- the window's global values too, so a buffer that no window has shown gets
-- them. Any other buffer brings back the options of its last window, so
-- BufWinEnter applies them again.
---@param win integer?
function M.apply(win)
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  if mode ~= "follow" then
    gutter = nil
  end
  -- Only this buffer in this window, so a window that opens from the code
  -- window with another buffer keeps the config's value.
  local numberwidth = review_gutter(win).numberwidth
  if vim.wo[win][0].numberwidth < numberwidth then
    vim.wo[win][0].numberwidth = numberwidth
  end
  for name, value in pairs(mode == "follow" and follow_gutter(win) or M.review_options()) do
    if vim.wo[win][name] ~= value then
      vim.wo[win][name] = value
    end
  end
  -- 'winbar' is global-local, so it has no global value of the window's own,
  -- and only BufWinEnter gives a new buffer its winbar.
  for name, value in pairs(layout.code_options) do
    if vim.wo[win][name] ~= value then
      vim.wo[win][name] = value
    end
  end
  apply_wrap(win)
  -- snacks sets these local values only when it places the image, and a
  -- later gutter would shift the image and cut its right edge.
  if vim.bo[api.nvim_win_get_buf(win)].filetype == "image" then
    Snacks.util.wo(win, Snacks.image.config.wo or {})
  end
end

-- A float that opened on top, such as a picker, the key view or
-- vim.ui.select, keeps the mode of the window it opened from. A float that
-- sits on a split belongs to that split, as the explorer's list does. So
-- follow the `relative = "win"` anchors down to the window under them.
local function on_top(win)
  for _ = 1, 10 do
    local config = api.nvim_win_get_config(win)
    if config.relative == "" then
      return false
    elseif config.relative ~= "win" or not (config.win and api.nvim_win_is_valid(config.win)) then
      return true
    end
    win = config.win
  end
  return true
end
M.on_top = on_top

-- A split that shows the buffer of a float on top counts as that float, as
-- the explorer's new split does for a moment on a resize from the Agent
-- Overview.
-- The layout's own windows never count, because a picker's preview can show
-- the code window's file, and the Overview the pane's log.
local function float_copy(win)
  local wins = layout.wins
  if win == wins.code or win == wins.input or win == wins.transcript or win == wins.pane or win == wins.todos then
    return false
  end
  for _, other in ipairs(vim.fn.win_findbuf(api.nvim_win_get_buf(win))) do
    if other ~= win and api.nvim_win_get_config(other).relative ~= "" and on_top(other) then
      return true
    end
  end
  return false
end

-- Computes the mode. When it changed, sets the code window's gutter and fires
-- `User AnvimMode`. It never redraws, so window events can call it.
function M.update()
  local win = api.nvim_get_current_win()
  -- A split that shows the prompt's buffer is the prompt for a moment. snacks
  -- makes the explorer's split so, inside nvim_win_call(), and the cursor
  -- goes back to the prompt without autocmds.
  local prompt = M.enabled() or vim.b[api.nvim_win_get_buf(win)].anvim_input == true
  if prompt or not (on_top(win) or float_copy(win)) then
    in_prompt = prompt
  end
  local new = in_prompt and "follow" or "review"
  if new ~= mode then
    mode = new
    if new == "review" and require("anvim.windows").clicked() then
      deferred = true
    else
      M.apply(layout.wins.code)
    end
    api.nvim_exec_autocmds("User", { pattern = "AnvimMode", modeline = false })
  end
end

-- The focused agent's place.
---@return anvim.Place?
function M.place()
  return places[M.focus or ""]
end

-- Every agent's place, by agent_id, and "" for the main agent. Callers only read it.
---@return table<string, anvim.Place>
function M.places()
  return places
end

-- The focused subagent, while it runs. nil for the main agent.
---@return anvim.Agent?
function M.focused()
  local agent = M.focus and agents.get(M.focus)
  return agent and agent.status == "running" and agent or nil
end

-- The focused agent's color.
---@return string group
function M.group()
  local agent = M.focused()
  if agent then
    return agents.group(agent.slot)
  end
  return agents.group(0)
end

---@return integer buf
function M.load(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

-- The explorer's reveal moves its root up to a folder that holds the file,
-- such as the home folder for a file in ~/.claude. So a file outside the
-- root shows in the code window only.
local function reveal_in_tree(path)
  local ok, snacks = pcall(require, "snacks")
  local explorer = ok and snacks.picker and snacks.picker.get({ source = "explorer" })[1]
  if explorer and vim.fs.relpath(explorer:cwd(), path) then
    pcall(snacks.explorer.reveal, { file = path })
  end
end

-- Shows buf in the code window with the cursor at line (1-based) and col
-- (0-based). Without a line, the cursor goes where the window last had it
-- in buf.
---@param line integer?
function M.show(buf, line, col)
  local win = layout.code_win()
  if api.nvim_win_get_buf(win) ~= buf then
    vim.bo[buf].buflisted = vim.bo[buf].buftype == ""
    api.nvim_win_set_buf(win, buf)
    -- From a non-nested autocmd, the new buffer gets no BufWinEnter.
    M.apply(win)
    local name = vim.b[buf].anvim_preview or api.nvim_buf_get_name(buf)
    if name ~= "" then
      reveal_in_tree(name)
    end
  end
  if line then
    line = math.max(1, math.min(line, api.nvim_buf_line_count(buf)))
    api.nvim_win_set_cursor(win, { line, col or 0 })
  end
end

---@param quiet boolean? Only record the place.
local function move(path, line, buf, id, quiet)
  local old = places[id or ""]
  local place = { path = path, line = line or 1, buf = buf, behind = old and old.behind or 0 }
  places[id or ""] = place
  -- Steps and previews that a turn's end flushes still move the main agent.
  if not id and not state.busy then
    place.ended = true
  end
  -- The tree marks each agent's file, and a move within the file changes no mark.
  if not old or old.path ~= path or old.ended ~= place.ended then
    agents.files_changed()
  end
  if M.shows(id) and not quiet then
    place.behind = 0
    M.show(buf or M.load(path), place.line)
  else
    place.behind = place.behind + 1
    if id == M.focus then
      input.redraw()
    end
  end
end

local function stop_steps(key)
  local s = steps[key]
  steps[key] = nil
  if s and not s.timer:is_closing() then
    s.timer:stop()
    s.timer:close()
  end
  return s
end

-- Records an agent's place, and moves the code window there when following
-- that agent. A newer move ends the steps through a Bash call's reads.
---@param buf integer? A buffer to show instead of the file itself, such as a Write preview.
---@param id string? The agent's agent_id. nil is the main agent.
function M.track(path, line, buf, id)
  stop_steps(id or "")
  move(path, line, buf, id)
end

-- The focused agent's place: the buffer that it writes into while that
-- lives, as a Write preview of a file that may not exist yet, else the file.
-- Without either, the agent stays ahead.
local function catch_up()
  local place = M.place()
  local buf = place and place.buf
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = place and vim.uv.fs_stat(place.path) and M.load(place.path)
  end
  if buf then
    place.behind = 0
    M.show(buf, place.line)
  end
end

-- Moves the code window to the focused agent's latest place.
function M.jump()
  catch_up()
  input.redraw()
end

-- When following, the code window catches up with the focused agent, as on
-- entering the prompt.
function M.resume()
  local place = M.place()
  if M.following() and place and place.behind > 0 then
    catch_up()
  end
  input.redraw()
end

-- Follow mode follows agent `id`, or the main agent for nil, and catches up
-- with it at once. Elsewhere the statusline points at its place.
---@param id string?
function M.set_focus(id)
  local agent = id and agents.get(id)
  if id and not (agent and agent.status == "running") then
    return
  end
  M.focus, focus_name = id, agent and agents.label(agent, true)
  local place = M.place()
  if place and M.following() then
    catch_up()
  elseif place then
    place.behind = math.max(place.behind, 1)
  end
  agents.changed()
end

function M.empty_slot(slot)
  vim.notify(("No agent in slot %d"):format(slot), vim.log.levels.INFO, { title = "anvim", timeout = 1500 })
end

-- Calls `fn` with the id of the agent in `slot`, or nil for slot 0, the main
-- agent. An empty slot says so.
local function with_slot(slot, fn)
  local agent = slot > 0 and agents.in_slot(slot)
  if slot > 0 and not agent then
    M.empty_slot(slot)
    return
  end
  fn(agent and agent.id or nil)
end

-- Follows the agent in `slot` as the Agent Overview's <CR> does.
function M.follow_slot(slot)
  with_slot(slot, M.follow)
end

-- How an agent's end reads in a notice.
local ended = { completed = "finished", failed = "failed", stopped = "was stopped" }

-- Closes the Agent Overview and follows agent `id`, or the main agent for
-- nil. Follow mode needs the cursor in the prompt, so it goes there in normal
-- mode, unless it is in the compose window. An agent that ended by then hands
-- the view to the main agent.
---@param id string?
function M.follow(id)
  require("anvim.overview").close()
  -- The end of an agent that has the focus already says so in the transcript.
  local focused = id ~= nil and id == M.focus
  vim.schedule(function()
    if not M.enabled() then
      layout.focus_input({ insert = false })
    end
    local agent = id and agents.get(id)
    local running = agent and agent.status == "running"
    if agent and not running and not focused then
      local text = ("%s %s · following Claude"):format(agents.label(agent, true), ended[agent.status] or "ended")
      vim.notify(text, vim.log.levels.INFO, { title = "anvim" })
    end
    M.set_focus(running and id or nil)
  end)
end

-- Focus goes back to the main agent when the focused agent ends, or when the
-- sidecar that ran it exits. /clear and a resumed session start over, so they
-- say nothing.
local function on_agents(ev)
  for key in pairs(places) do
    if key ~= "" and not agents.get(key) then
      places[key] = nil
      stop_steps(key)
    end
  end
  local agent = M.focus and agents.get(M.focus)
  if not M.focus or (agent and agent.status == "running") then
    focus_name = agent and agents.label(agent, true)
    return
  end
  M.focus = nil
  local cleared = ev.data and ev.data.cleared
  local why = agent and (ended[agent.status] or "ended")
    or (cleared == "exit" or cleared == "restart") and "stopped with the sidecar"
  local text = why and ("%s %s · focus is back on Claude"):format(focus_name, why)
  if text and cleared then
    -- After the transcript's own exit notice, so the cause comes first.
    vim.schedule(function()
      require("anvim.transcript").notice("info", text)
    end)
  elseif text then
    require("anvim.transcript").notice("info", text)
  end
  -- From the event loop: a file that this non-nested handler loads would get
  -- no BufReadPost, so no filetype and no read-only lock.
  local place = M.place()
  if place and place.behind > 0 then
    vim.schedule(M.resume)
  end
  agents.changed()
end

-- A new session starts with no places and no focus.
function M.forget()
  for key in pairs(steps) do
    stop_steps(key)
  end
  local any = next(places) ~= nil
  places, writes, greps, waiting, batched, M.focus, focus_name = {}, {}, {}, {}, {}, nil, nil
  if any then
    agents.files_changed()
  end
end

-- The main agent's place stays for the statusline, but its mark in the tree goes
-- with the turn, as its written files do.
local function end_main()
  local place = places[""]
  if place and not place.ended then
    place.ended = true
    agents.files_changed()
  end
end

-- snacks.image shows the file, so its rows are not the file's lines. The
-- name decides, because the image may not have loaded yet.
local function image(buf)
  return Snacks.config.image.enabled and Snacks.image.supports_file(api.nvim_buf_get_name(buf))
end

---@param rows integer[] 0-based rows
function M.flash(buf, rows, group, ms)
  if image(buf) then
    return
  end
  local marks = {}
  for _, row in ipairs(rows) do
    if row < api.nvim_buf_line_count(buf) then
      marks[#marks + 1] = api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = group, priority = 150 })
    end
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      for _, mark in ipairs(marks) do
        api.nvim_buf_del_extmark(buf, ns, mark)
      end
    end
  end, ms or 1200)
end

-- Scrolls the cursor line, where a move put it, to the top of the code
-- window, and flashes the `lines` that show.
---@param lines integer[] 1-based
local function flash_view(lines)
  local win = layout.code_win()
  api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  local top, bottom = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local rows = {}
  for _, line in ipairs(lines) do
    if line >= top and line <= bottom then
      rows[#rows + 1] = line - 1
    end
  end
  M.flash(api.nvim_win_get_buf(win), rows, "AnvimRead", 400)
end

---@class anvim.Step: anvim.Read
---@field lines integer[]? The lines to flash instead of the range, such as a grep's hits.

---@param read anvim.Step
---@param id string? The agent's agent_id. nil is the main agent.
local function on_read(read, id)
  if not vim.uv.fs_stat(read.path) then
    return
  end
  local first = read.first or 1
  move(read.path, first, nil, id)
  if M.shows(id) and read.lines then
    flash_view(read.lines)
  elseif M.shows(id) then
    local lines = {}
    for line = first, math.min(read.last or math.huge, first + vim.fn.winheight(layout.code_win()) - 1) do
      lines[#lines + 1] = line
    end
    flash_view(lines)
  end
end

-- The first n - 1 steps and the last one.
local function trim(list, n)
  if #list > n then
    return vim.list_extend(vim.list_slice(list, 1, n - 1), { list[#list] })
  end
  return list
end

-- The rest of the steps count at once, so the agent's place is the last of
-- them. While following, the code window catches up from the event loop,
-- unless a newer move came first.
---@param id string?
local function finish_steps(id)
  local s = stop_steps(id or "")
  local last = s and s.reads[#s.reads]
  if last then
    move(last.path, last.first or 1, nil, id, true)
    vim.schedule(M.resume)
  end
end

local function step(id)
  local s = steps[id or ""]
  if not M.shows(id) then
    finish_steps(id)
    return
  end
  local read = table.remove(s.reads, 1)
  if #s.reads == 0 then
    stop_steps(id or "")
  end
  on_read(read, id)
end

-- Each read counts as a Read. While following, the code window steps
-- through them, and the reads of a call in the same batch wait for their
-- turn.
---@param reads anvim.Step[]
---@param id string?
local function on_reads(reads, id)
  local s = steps[id or ""]
  if s then
    s.reads = trim(vim.list_extend(s.reads, reads), MAX_STEPS - 1)
    return
  elseif not M.shows(id) or #reads < 2 then
    for _, read in ipairs(reads) do
      on_read(read, id)
    end
    return
  end
  reads = trim(reads, MAX_STEPS)
  on_read(reads[1], id)
  s = { reads = vim.list_slice(reads, 2), timer = assert(vim.uv.new_timer()) }
  steps[id or ""] = s
  s.timer:start(
    M.step_ms,
    M.step_ms,
    vim.schedule_wrap(function()
      -- A tick that waited in the queue may belong to steps that ended.
      if steps[id or ""] == s then
        step(id)
      end
    end)
  )
end

-- A grep's first hit shows, and the hits in its file flash where they show.
---@param hits anvim.Hit[]
---@param id string?
local function on_hits(hits, id)
  local lines = {}
  for _, hit in ipairs(hits) do
    if hit.path == hits[1].path then
      lines[#lines + 1] = hit.line
    end
  end
  on_reads({ { path = hits[1].path, first = hits[1].line, lines = lines } }, id)
end

local function busy(key)
  for _, k in pairs(waiting) do
    if k == key then
      return true
    end
  end
  return false
end

-- A subagent's edits arrive whole, so its place is the edit's line. A Write of
-- a new file shows once the file exists. A typed preview of the edit keeps
-- the place itself, whichever of the hook and the tool_use comes first.
local function on_agent_edit(agent, ev)
  local path = ev.input.file_path or ev.input.notebook_path
  if type(path) ~= "string" or require("anvim.stream").typed(ev.id) then
    return
  elseif not vim.uv.fs_stat(path) then
    writes[ev.id] = { agent = agent.id, path = path }
    return
  end
  M.track(path, ev.name == "Edit" and agents.edit_line(path, ev.input) or 1, nil, agent.id)
end

local edit_tools = { Edit = true, Write = true, NotebookEdit = true }

-- Where Claude is, as plain text for the statusline. A focused subagent
-- takes Claude's name.
---@param short boolean? Without the words, for a narrow screen.
---@param for_mode anvim.Mode? The mode to say it for. Without it, the current window decides.
function M.status(short, for_mode)
  local place = M.place()
  local where = place
    and ("%s:%d%s"):format(
      require("anvim.paths").display(place.path),
      place.line,
      place.behind > 0 and (" +%d"):format(place.behind) or ""
    )
  local agent = M.focused()
  local name = agent and agents.name(agent) or "Claude"
  local claude = where and (short and where or name .. " at " .. where) or (agent and name)
  if for_mode == "follow" or (for_mode == nil and M.enabled()) then
    return agent and (short and "◉ " .. name or "◉ following " .. agents.label(agent)) or "◉ following"
  end
  return claude and "⏺ " .. claude or ""
end

-- A background agent works on after the turn.
local function runs_on(id)
  local agent = id and agents.get(id)
  return agent and agent.background and agent.status == "running"
end

function M.attach(sidecar)
  sidecar.on("tool_use", function(ev)
    local agent = agents.of(ev)
    if not agent and (ev.agent_id or ev.parent_id) then
      return
    end
    local id = agent and agent.id
    -- A call after the results of the last batch moves on, so the rest of
    -- the steps count now.
    local batch = batched[ev.id]
    batched[ev.id] = nil
    if batch == nil then
      batch = busy(id or "")
    end
    if not batch then
      finish_steps(id)
    end
    waiting[ev.id] = id or ""
    if ev.name == "Read" or ev.name == "Bash" then
      on_reads(bashread.reads(ev), id)
      local spec = bashread.grep_of(ev)
      greps[ev.id] = spec and { agent = id, spec = spec }
    elseif agent and edit_tools[ev.name] then
      on_agent_edit(agent, ev)
    end
  end)
  -- The main agent's next call streams before its tool_use comes.
  sidecar.on("tool_start", function(ev)
    batched[ev.id] = busy("")
    if not batched[ev.id] then
      finish_steps(nil)
    end
  end)
  -- The next sidecar knows none of these calls.
  sidecar.on("exit", function()
    for key in pairs(steps) do
      stop_steps(key)
    end
    waiting, greps, batched = {}, {}, {}
    end_main()
  end)
  sidecar.on("tool_result", function(ev)
    waiting[ev.id] = nil
    local write = writes[ev.id]
    writes[ev.id] = nil
    if write and not ev.is_error and vim.uv.fs_stat(write.path) and agents.get(write.agent) then
      M.track(write.path, 1, nil, write.agent)
    end
    local grep = greps[ev.id]
    greps[ev.id] = nil
    if grep and (not grep.agent or agents.get(grep.agent)) then
      -- A live result has the output without the errors. A subagent's has
      -- only the text.
      local result = type(ev.result) == "table" and ev.result or {}
      local text = type(result.stdout) == "string" and result.stdout or ev.text
      local hits = type(text) == "string" and bashread.hits(grep.spec, text) or {}
      if hits[1] then
        on_hits(hits, grep.agent)
      end
    end
  end)
  sidecar.on("turn_end", function()
    end_main()
    for id, write in pairs(writes) do
      if not runs_on(write.agent) then
        writes[id] = nil
      end
    end
    for id, grep in pairs(greps) do
      if not runs_on(grep.agent) then
        greps[id] = nil
      end
    end
    batched = {}
    for id, key in pairs(waiting) do
      if not runs_on(key) then
        waiting[id] = nil
      end
    end
    for key in pairs(steps) do
      if not runs_on(key) then
        finish_steps(key ~= "" and key or nil)
      end
    end
  end)
  local group = api.nvim_create_augroup("anvim.follow", {})
  -- The catch-up waits for the event loop. A file that it loads inside the
  -- window's autocmds can miss its filetype: a non-nested autocmd blocks
  -- BufReadPost, and in one order of the stack tests did_filetype() was
  -- already 1 for the new buffer, nested or not. And :redrawstatus inside a
  -- window command, such as a split that anvim is about to fold back, would
  -- show a frame too early.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      M.update()
      vim.schedule(M.resume)
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      M.apply(layout.wins.code)
    end,
  })
  -- A buffer can get its filetype after the code window shows it.
  api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      local win = layout.wins.code
      if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == ev.buf then
        apply_wrap(win)
      end
    end,
  })
  -- A click on a 'statuscolumn' moves the cursor of the current window
  -- before its click function runs, so remember that window's view.
  vim.on_key(function(key)
    if key == left_mouse then
      local win = api.nvim_get_current_win()
      pressed = { win = win, view = api.nvim_win_call(win, vim.fn.winsaveview) }
    end
  end, ns)
  -- Other moves of the cursor without autocmds come before the redraw too.
  api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      M.update()
      if deferred then
        deferred = false
        M.apply(layout.wins.code)
      end
    end,
  })
  M.review_options()
  M.update()
  api.nvim_create_autocmd("User", { group = group, pattern = "AnvimAgents", callback = on_agents })
  local keys = require("anvim.keys")
  keys.set("claude", "n", "<leader>j", M.jump)
  keys.set("claude", "n", "<leader>cj", M.jump)
  for slot = 0, agents.slots do
    keys.set("claude", "n", "<leader>c" .. slot, function()
      M.follow_slot(slot)
    end)
  end
  -- f on the agent count, from any window. With no agent running, it is
  -- Neovim's own.
  keys.set("claude", "n", "<C-f>", function()
    return #agents.running() > 0 and "<Cmd>lua require('anvim.input').follow_next()<CR>" or "<C-f>"
  end, { expr = true })
end

return M
