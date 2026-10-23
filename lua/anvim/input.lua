-- The prompt box under the transcript. Its winbar is the activity line. Under
-- the last prompt line, a rule closes the box, and the footer under the rule
-- shows the running agents.
local config = require("anvim.config")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.input")

---@type integer?
local bufnr
---@type integer?
local winid
---@type integer?
local footer_mark
---@type uv.uv_timer_t?
local spinner_timer
---@type [integer, integer]? Where typing stopped when the prompt window was left in insert mode.
local stopped
---@type integer? The prompt buffer's changedtick then. A change of the text since makes the place stale.
local stopped_tick
local spinner_frames = { "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" }

-- <Esc> in normal mode in the prompt stops Claude or answers a request only on
-- a second press. The first press arms it. The second acts when it comes after
-- the pause and before the time limit. A press inside the pause starts the
-- pause again, so a burst of presses never acts.
M.esc_pause_ms = 400
M.esc_limit_ms = 3000

---@class anvim.EscAction
---@field id any What the second press acts on: "stop", or a request.
---@field text string What the activity line says while armed.
---@field run fun()
---@field changed fun()? Runs when it arms and when it disarms.

-- `keys` counts the typed keys since the last press, that press excluded.
---@type { action: anvim.EscAction, at: number, keys: integer }?
local armed
local esc_ns = api.nvim_create_namespace("anvim.input.esc")
---@type uv.uv_timer_t?
local esc_timer

-- Each label and its highlight.
local mode_labels = {
  default = { "⏵ manual mode on", "AnvimModeManual" },
  acceptEdits = { "⏵⏵ accept edits on", "AnvimModeEdits" },
  plan = { "⏸ plan mode on", "AnvimModePlan" },
  bypassPermissions = { "⏵⏵ bypass permissions on", "AnvimModeBypass" },
  auto = { "⏵⏵ auto mode on", "AnvimModeAuto" },
}

function M.buf()
  if bufnr and api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].anvim_input then
    return bufnr
  end
  -- :bdelete keeps the buffer and its name, but clears its options and maps.
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr = api.nvim_create_buf(false, true)
  vim.b[bufnr].anvim_input = true
  api.nvim_buf_set_name(bufnr, "anvim://input")
  -- snacks.image would show the images of markdown links inline.
  vim.b[bufnr].snacks_image_attached = true
  vim.treesitter.language.register("markdown", "anvim_input")
  vim.bo[bufnr].filetype = "anvim_input"
  pcall(vim.treesitter.start, bufnr, "markdown")
  local keys = require("anvim.keys")
  local map = function(modes, lhs, rhs, opts)
    keys.set("prompt", modes, lhs, rhs, vim.tbl_extend("force", { buffer = bufnr }, opts or {}))
  end
  map("n", "<CR>", M.enter)
  -- With the completion menu open, <CR> takes its highlighted item. A slash
  -- command that needs no argument then goes out, as in Claude Code. A menu
  -- with no highlighted item closes, and the prompt goes out.
  map("i", "<CR>", function()
    local accept, send = require("anvim.completion").enter()
    local enter = "<Cmd>lua require('anvim.input').enter()<CR>"
    if accept then
      return "<C-y>" .. (send and enter or "")
    end
    return (vim.fn.pumvisible() == 1 and "<C-e>" or "") .. enter
  end, { expr = true })
  -- Neovim's own <CR> takes the menu's item, so the menu closes first.
  local function newline()
    return vim.fn.pumvisible() == 1 and "<C-e><CR>" or "<CR>"
  end
  map("i", "<S-CR>", newline, { expr = true })
  map("i", "<M-CR>", newline, { expr = true })
  map("n", "<Esc>", M.escape, { nowait = true })
  map({ "i", "n" }, "<C-c>", M.interrupt)
  map({ "i", "n" }, "<S-Tab>", M.cycle_mode)
  map({ "i", "n" }, "<C-g>", function()
    require("anvim.compose").open()
  end)
  -- The transcript takes no focus, so the prompt scrolls it.
  local function scroll(modes, list)
    for _, key in ipairs(list) do
      map(modes, key, function()
        require("anvim.windows").scroll(key)
      end)
    end
  end
  scroll("n", { "<C-u>", "<C-d>", "<C-b>", "<C-f>" })
  scroll({ "n", "i" }, { "<PageUp>", "<PageDown>" })
  keys.set("transcript", { "n", "i" }, "<LeftDrag>", function()
    return require("anvim.windows").drag_keys()
  end, { buffer = bufnr, expr = true })
  -- ? shows the keys. While typing, it does so as in Claude Code: only in an
  -- empty prompt while no request waits. Otherwise it is text.
  map("n", "?", function()
    require("anvim.keyview").open()
  end)
  map("i", "?", function()
    if M.shortcuts() then
      return "<Esc><Cmd>lua require('anvim.keyview').open({ insert = true })<CR>"
    end
    return "?"
  end, { expr = true })
  require("anvim.history").map(bufnr)
  local group = api.nvim_create_augroup("anvim.input", {})
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = bufnr, callback = M.render })
  -- Insert mode that ends in another window, as after a click there, sets
  -- the `^` mark of that window's buffer.
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      if api.nvim_get_mode().mode:sub(1, 1) == "i" then
        stopped, stopped_tick = api.nvim_win_get_cursor(0), vim.b[bufnr].changedtick
      end
      M.disarm()
    end,
  })
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      stopped = nil
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.show_footer()
    end,
  })
  return bufnr
end

-- The prompt window. Other windows can show the prompt buffer for a moment,
-- for example a split that a plugin is about to switch to another buffer.
---@return integer?
local function prompt_win()
  if winid and api.nvim_win_is_valid(winid) and api.nvim_win_get_buf(winid) == bufnr then
    return winid
  end
end

function M.setup_win(win)
  winid = win
  local wo = vim.wo[win]
  wo.statuscolumn = "%#AnvimPrompt#%{v:lnum == 1 && v:virtnum == 0 ? '❯ ' : '  '}"
  wo.winbar = "%!v:lua.require'anvim.input'.activity()"
  wo.winhighlight = "Normal:AnvimNormal,NormalNC:AnvimNormal,WinBar:AnvimNormal,WinBarNC:AnvimNormal"
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.cursorline = false
  wo.wrap = true
  wo.linebreak = true
  -- A reference ends in a space, which 'list' would mark.
  wo.list = false
  wo.spell = false
  wo.winfixheight = true
  wo.winfixbuf = true
  -- When insert mode ends in another window, the cursor keeps its place after
  -- the last character, so `i` goes on where typing stopped.
  local ve = vim.go.virtualedit
  wo.virtualedit = ve:find("onemore", 1, true) and ve or ve == "" and "onemore" or ve .. ",onemore"
  M.render()
end

-- Puts the prompt's cursor where typing stopped in another window, such as
-- the compose window, so the next insert command goes on there.
---@param at [integer, integer]
function M.stop_at(at)
  local win = prompt_win()
  if win then
    local row = math.max(1, math.min(at[1], api.nvim_buf_line_count(bufnr)))
    local line = api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    api.nvim_win_set_cursor(win, { row, math.min(at[2], #line) })
    stopped, stopped_tick = api.nvim_win_get_cursor(win), vim.b[bufnr].changedtick
  end
end

-- Where typing stopped, as a 1-based row and a byte column. <Esc> leaves the
-- cursor on the character before that place, so the `^` mark tells it, while
-- the cursor is still there. Insert mode that ended in another window leaves
-- the cursor at that place. Otherwise it is the cursor.
---@param win integer? Another window than the prompt, such as the compose window.
---@return integer row, integer col
function M.insert_pos(win)
  win = win or assert(prompt_win(), "no prompt window")
  local buf = api.nvim_win_get_buf(win)
  local fresh = stopped and stopped_tick == vim.b[buf].changedtick
  if buf == bufnr and fresh and vim.deep_equal(api.nvim_win_get_cursor(win), stopped) then
    return stopped[1], stopped[2]
  end
  local row, col = unpack(api.nvim_buf_get_mark(buf, "^"))
  local cursor = api.nvim_win_get_cursor(win)
  local line = api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
  if row == cursor[1] and col <= #line then
    local before = col > 0 and col - 1 + vim.str_utf_start(line, col) or 0
    if cursor[2] == col or cursor[2] == before then
      return row, col
    end
  end
  return cursor[1], cursor[2]
end

-- Starts insert mode where typing stopped, or at `at`. With `at_cursor`, as
-- after a click, insert mode starts at the cursor. While a request waits for
-- an answer, the prompt stays in normal mode.
---@param opts? { at_cursor: boolean?, at: [integer, integer]? }
function M.resume(opts)
  local win = prompt_win()
  if win ~= api.nvim_get_current_win() or state.waiting then
    return
  end
  if opts and opts.at_cursor then
    vim.cmd.startinsert()
    return
  end
  local row, col = unpack(opts and opts.at or { M.insert_pos() })
  local line = api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  api.nvim_win_set_cursor(win, { row, math.min(col, #line) })
  vim.cmd.startinsert({ bang = col >= #line })
end

-- While the prompt is empty and no request waits, ? shows the keys.
function M.shortcuts()
  if state.waiting or not (bufnr and api.nvim_buf_is_loaded(bufnr)) then
    return false
  end
  local lines = api.nvim_buf_get_lines(bufnr, 0, 2, false)
  return #lines == 1 and lines[1] == ""
end

-- <CR> answers a waiting permission request, or sends the prompt.
function M.enter()
  if not require("anvim.permission").key() then
    M.submit()
  end
end

function M.submit()
  local buf = M.buf()
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  require("anvim.history").add(text)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  if not require("anvim.sessions").command(text) then
    M.send(text)
  end
  -- A send ends insert mode. A picker that a slash command opened has the
  -- cursor now, and keeps its insert mode.
  if api.nvim_get_current_win() == prompt_win() and api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd.stopinsert()
  end
end

function M.send(text)
  -- Marks from show_user last until the user's next prompt. A turn that a
  -- background agent's end starts has none.
  require("anvim.tools").clear()
  require("anvim.agents").prompt_sent()
  require("anvim.trail").prompt(text)
  transcript.user(text)
  local images = require("anvim.images").take(text)
  sidecar.send({ type = "prompt", text = text, images = #images > 0 and images or nil })
  if not state.busy then
    M.set_busy(true)
  end
end

function M.interrupt()
  require("anvim.reload").cancel()
  if state.busy then
    sidecar.send({ type = "interrupt" })
  end
end

-- The action that a second <Esc> takes, while armed.
---@return anvim.EscAction?
function M.armed()
  return armed and armed.action
end

-- Another key, leaving the prompt, the end of the time limit, a change of the
-- busy state and a request that opens, closes or changes disarm it. So the
-- second press always does what the activity line said. This marks the winbar
-- for the next redraw and draws nothing now, so window events can call it.
function M.disarm()
  local was = armed
  if not was then
    return
  end
  armed = nil
  vim.on_key(nil, esc_ns)
  if esc_timer then
    esc_timer:stop()
  end
  if was.action.changed then
    was.action.changed()
  end
  require("anvim.statusline").refresh()
end

local function start_limit()
  local a = assert(armed)
  esc_timer = esc_timer or assert(vim.uv.new_timer())
  esc_timer:start(
    M.esc_limit_ms,
    0,
    vim.schedule_wrap(function()
      if armed == a then
        M.disarm()
      end
    end)
  )
end

local function ms()
  return vim.uv.hrtime() / 1e6
end

-- <Esc> in normal mode: a waiting request gets its answer, and otherwise a
-- busy Claude stops, but only on a second press (see M.esc_pause_ms).
function M.escape()
  -- The map hides the global <Esc>, which clears the search highlight.
  vim.cmd.nohlsearch()
  local action = require("anvim.permission").escape()
  if action == true then
    M.disarm()
    return
  end
  if not action then
    if not state.busy then
      M.disarm()
      return
    end
    action = { id = "stop", text = "esc again to stop Claude", run = M.interrupt }
  end
  local now, a = ms(), armed
  -- Keys fed without the typed flag count for nothing, so `keys` can be 0.
  if a and a.action.id == action.id and a.keys <= 1 and now - a.at <= M.esc_limit_ms then
    if now - a.at >= M.esc_pause_ms then
      M.disarm()
      action.run()
    else
      a.at, a.keys = now, 0
      start_limit()
    end
    return
  end
  M.disarm()
  armed = { action = action, at = now, keys = 0 }
  vim.on_key(function(_, typed)
    -- Keys from :normal, such as the steps of snacks.scroll, have no typed form.
    if typed ~= "" and armed then
      armed.keys = armed.keys + 1
      -- A press of <Esc> resets the count before this runs.
      vim.schedule(function()
        if armed and armed.keys > 0 then
          M.disarm()
        end
      end)
    end
  end, esc_ns)
  start_limit()
  if action.changed then
    action.changed()
  end
  require("anvim.statusline").refresh()
end

function M.modes()
  local modes = { "default", "acceptEdits", "plan" }
  if config.options.permission_mode == "bypassPermissions" then
    table.insert(modes, "bypassPermissions")
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
  sidecar.send({ type = "set_permission_mode", mode = next_mode })
  M.redraw()
end

-- Redraws everything that shows session state. Statusline plugins can listen
-- for `User AnvimStatus` to refresh.
function M.redraw()
  M.render()
  vim.cmd.redrawstatus({ bang = true })
  api.nvim_exec_autocmds("User", { pattern = "AnvimStatus", modeline = false })
end

function M.set_busy(busy)
  M.disarm()
  state.busy = busy
  if busy then
    state.turn_started = vim.uv.now()
    spinner_timer = spinner_timer or vim.uv.new_timer()
    spinner_timer:start(
      0,
      120,
      vim.schedule_wrap(function()
        vim.cmd.redrawstatus({ bang = true })
      end)
    )
  else
    state.turn_started = nil
    state.thinking = false
    if spinner_timer then
      spinner_timer:stop()
    end
  end
  M.redraw()
end

-- claude-opus-5-5 -> Opus 5.5
function M.model_label(model)
  if not model then
    return "Claude"
  end
  local family, version = model:gsub("^claude%-", ""):match("^(%a+)%-([%d%-]+)")
  if not family then
    return model
  end
  version = version:gsub("%-%d%d%d%d%d%d%d%d$", ""):gsub("%-", ".")
  return family:sub(1, 1):upper() .. family:sub(2) .. " " .. version
end

local function win_width(win)
  return win and api.nvim_win_is_valid(win) and api.nvim_win_get_width(win) or vim.o.columns
end

-- As in Claude Code, the todo item in progress names what Claude does.
---@return string verb, integer ms
local function working()
  local active = transcript.todo_active()
  local verb = state.compacting and "Compacting..."
    or active and (active:gsub("%.+$", "") .. "...")
    or state.thinking and "Thinking..."
    or "Working..."
  return verb, vim.uv.now() - state.turn_started
end

-- In a narrow column, keep the start of a text, which says what to do.
-- `spare` columns stay for the rest of the line.
local function fit(text, spare)
  local room = win_width(vim.g.statusline_winid) - spare
  if api.nvim_strwidth(text) > room then
    return vim.trim(vim.fn.strcharpart(text, 0, math.max(room - 3, 0))) .. "..."
  end
  return text
end

-- The line between transcript and prompt: a rule, with the spinner while Claude works.
function M.activity()
  local text, width = "", 0
  if state.process == "exited" then
    local info = "sidecar exited · :AnvimRestart "
    text, width = "%#AnvimToolError#" .. info, api.nvim_strwidth(info)
  elseif armed then
    local say = fit(armed.action.text, 1) .. " "
    text, width = "%#AnvimDanger#" .. say:gsub("%%", "%%%%"), api.nvim_strwidth(say)
  elseif state.waiting then
    -- The hint depends on the window that has the cursor.
    local hint = fit(require("anvim.permission").hint() or state.waiting, 4)
    text = ("%%#AnvimClaude#⏺ %s "):format((hint:gsub("%%", "%%%%")))
    width = api.nvim_strwidth("⏺ " .. hint .. " ")
  elseif state.busy and state.turn_started then
    local frame = spinner_frames[math.floor(vim.uv.now() / 120) % #spinner_frames + 1]
    local verb, elapsed = working()
    local hint = ("(%s · esc twice to stop)"):format(transcript.duration(elapsed, true))
    text = ("%%#AnvimClaude#%s %s %%#Comment#%s "):format(frame, (verb:gsub("%%", "%%%%")), hint)
    width = vim.fn.strdisplaywidth(("%s %s %s "):format(frame, verb, hint))
  elseif config.options.input.turn_stats and (state.last_turn or state.context) then
    local parts = {}
    if state.last_turn then
      parts[1] = ("%s · $%.2f"):format(transcript.duration(state.last_turn.duration_ms), state.cost_usd)
    end
    if state.context and tonumber(state.context.percent) then
      parts[#parts + 1] = ("%d%%%% context"):format(state.context.percent)
    end
    local info = table.concat(parts, " · ") .. " "
    text, width = "%#Comment#" .. info, api.nvim_strwidth((info:gsub("%%%%", "%%")))
  end
  return text .. "%#AnvimRule#" .. ("─"):rep(math.max(0, win_width(vim.g.statusline_winid) - width))
end

-- The mode's label and its group, while the mode differs from the one the
-- session started in, as Claude Code shows none for its default mode. Plan
-- mode always shows, because it changes what Claude may do.
---@return [string, string]?
function M.mode_label()
  local mode = state.permission_mode
  if mode == "plan" or mode ~= config.options.permission_mode then
    return mode_labels[mode]
  end
end

-- A dot in each running agent's color, with their count, under the prompt
-- text. The focused agent's dot is ◉.
---@return [string, string?][]
function M.footer()
  local follow, agents = require("anvim.follow"), require("anvim.agents")
  local running = agents.running()
  local chunks = { { "  " } } ---@type [string, string?][]
  for _, agent in ipairs(running) do
    if agent.slot then
      chunks[#chunks + 1] = { agent.id == follow.focus and "◉" or "⏺", agents.group(agent.slot) }
    end
  end
  if #chunks > 1 then
    chunks[#chunks + 1] = { (" %d agent%s"):format(#running, #running == 1 and "" or "s"), "AnvimChip" }
  end
  return chunks
end

-- Neovim keeps the cursor line at the bottom of the window, which hides the
-- footer under the last line. On the last line, scroll the footer into view.
function M.show_footer()
  local win = prompt_win()
  local last = win and api.nvim_buf_line_count(bufnr)
  if not win or api.nvim_win_get_cursor(win)[1] ~= last then
    return
  end
  local rows = api.nvim_win_get_height(win) - (vim.wo[win].winbar ~= "" and 1 or 0)
  local top = last
  while top > 1 and api.nvim_win_text_height(win, { start_row = top - 2 }).all <= rows do
    top = top - 1
  end
  if vim.fn.line("w0", win) < top then
    api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = top })
    end)
  end
end

-- Places the footer under the last line, and fits the window to the prompt:
-- its lines plus the footer, within the configured height.
function M.render()
  if not (bufnr and api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  local win = prompt_win()
  local last = api.nvim_buf_line_count(bufnr) - 1
  footer_mark = api.nvim_buf_set_extmark(bufnr, ns, last, 0, {
    id = footer_mark,
    virt_lines = { { { ("─"):rep(win_width(win)), "AnvimRule" } }, M.footer() },
    virt_lines_leftcol = true,
  })
  if win then
    local limits = config.options.layout.input_height
    local rows = api.nvim_win_text_height(win, {}).all
    local height = math.max(limits.min, math.min(rows, limits.max)) + (vim.wo[win].winbar ~= "" and 1 or 0)
    if api.nvim_win_get_height(win) ~= height then
      local cmdheight = vim.o.cmdheight
      api.nvim_win_set_height(win, height)
      -- With no window above or below, the rows go to the command line.
      if vim.o.cmdheight ~= cmdheight then
        vim.o.cmdheight = cmdheight
      end
    end
    M.show_footer()
  end
end

function M.attach()
  -- A turn that a prompt started counts its time from the send.
  sidecar.on("turn_start", function()
    if not state.busy then
      M.set_busy(true)
    end
  end)
  sidecar.on("turn_end", function(ev)
    -- A slash command such as /clear ends a turn that asked no model.
    if (ev.num_turns or 0) > 0 then
      state.last_turn = { duration_ms = ev.duration_ms, cost_usd = ev.cost_usd }
    end
    state.cost_usd = ev.cost_usd
    M.set_busy(false)
  end)
  sidecar.on("thinking_start", function()
    state.thinking = true
  end)
  sidecar.on("thinking_stop", function()
    state.thinking = false
  end)
  sidecar.on("exit", function()
    M.set_busy(false)
  end)
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = api.nvim_create_augroup("anvim.input.resize", {}),
    callback = M.render,
  })
  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup("anvim.input.agents", {}),
    pattern = "AnvimAgents",
    callback = M.render,
  })
end

return M
