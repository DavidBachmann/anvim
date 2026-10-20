-- The prompt box under the transcript. Its winbar is the activity line, and
-- the footer is a virtual line under the last prompt line.
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
-- Whether the footer shows the follow status. When it does not fit, the
-- statusline shows it.
local follows = false
local spinner_frames = { "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" }

-- Each label, its highlight, and a short form for a narrow column.
local mode_labels = {
  default = { "⏵ manual mode on", "AnvimModeManual", "⏵ manual" },
  acceptEdits = { "⏵⏵ accept edits on", "AnvimModeEdits", "⏵⏵ accept edits" },
  plan = { "⏸ plan mode on", "AnvimModePlan", "⏸ plan" },
  bypassPermissions = { "⏵⏵ bypass permissions on", "AnvimModeBypass", "⏵⏵ bypass" },
  auto = { "⏵⏵ auto mode on", "AnvimModeAuto", "⏵⏵ auto" },
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
  vim.treesitter.language.register("markdown", "anvim_input")
  vim.bo[bufnr].filetype = "anvim_input"
  pcall(vim.treesitter.start, bufnr, "markdown")
  local keys = require("anvim.keys")
  local map = function(modes, lhs, rhs, opts)
    keys.set("prompt", modes, lhs, rhs, vim.tbl_extend("force", { buffer = bufnr }, opts or {}))
  end
  -- While a permission prompt waits, these keys answer it.
  local or_answer = function(key, fn)
    return function()
      if not require("anvim.permission").key(key) then
        fn()
      end
    end
  end
  map({ "i", "n" }, "<CR>", or_answer("<CR>", M.submit))
  map("i", "<S-CR>", "<CR>")
  map("i", "<M-CR>", "<CR>")
  map("n", "<Esc>", or_answer("<Esc>", M.interrupt))
  map({ "i", "n" }, "<C-c>", M.interrupt)
  map({ "i", "n" }, "<S-Tab>", M.cycle_mode)
  map({ "i", "n" }, "<C-x>", function()
    require("anvim.context").clear()
  end)
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
  wo.winhighlight = "WinBar:Normal,WinBarNC:NormalNC"
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
  M.render()
end

-- Where typing stopped, as a 1-based row and a byte column. <Esc> leaves the
-- cursor on the character before that place, so the `^` mark tells it, while
-- the cursor is still there. Otherwise it is the cursor.
---@param win integer? Another window than the prompt, such as the compose window.
---@return integer row, integer col
function M.insert_pos(win)
  win = win or assert(prompt_win(), "no prompt window")
  local buf = api.nvim_win_get_buf(win)
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

-- While the prompt is empty and no request waits, ? shows the keys, and the
-- footer says so when it shows no mode label.
function M.shortcuts()
  if state.waiting or not (bufnr and api.nvim_buf_is_loaded(bufnr)) then
    return false
  end
  local lines = api.nvim_buf_get_lines(bufnr, 0, 2, false)
  return #lines == 1 and lines[1] == ""
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
end

function M.send(text)
  -- Marks from show_user last until the user's next prompt. A turn that a
  -- background agent's end starts has none.
  require("anvim.tools").clear()
  local context, label = require("anvim.context").prompt(text)
  transcript.user(text, label)
  sidecar.send({ type = "prompt", text = text, context = context })
  if not state.busy then
    M.set_busy(true)
  end
end

function M.interrupt()
  if state.busy then
    sidecar.send({ type = "interrupt" })
  end
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
---@return string verb, integer secs
local function working()
  local active = transcript.todo_active()
  local verb = state.compacting and "Compacting..."
    or active and (active:gsub("%.+$", "") .. "...")
    or state.thinking and "Thinking..."
    or "Working..."
  return verb, math.floor((vim.uv.now() - state.turn_started) / 1000)
end

-- The line between transcript and prompt: a rule, with the spinner while Claude works.
function M.activity()
  local text, width = "", 0
  if state.process == "exited" then
    local info = "sidecar exited · :AnvimRestart "
    text, width = "%#AnvimToolError#" .. info, api.nvim_strwidth(info)
  elseif state.waiting then
    -- In a narrow column, keep the start of the hint, which says what to do.
    local hint, room = state.waiting, win_width(vim.g.statusline_winid) - 4
    if api.nvim_strwidth(hint) > room then
      hint = vim.fn.strcharpart(hint, 0, math.max(room - 3, 0)) .. "..."
    end
    text = ("%%#AnvimClaude#⏺ %s "):format((hint:gsub("%%", "%%%%")))
    width = api.nvim_strwidth("⏺ " .. hint .. " ")
  elseif state.busy and state.turn_started then
    local frame = spinner_frames[math.floor(vim.uv.now() / 120) % #spinner_frames + 1]
    local verb, secs = working()
    local hint = ("(%ds · esc to interrupt)"):format(secs)
    text = ("%%#AnvimClaude#%s %s %%#Comment#%s "):format(frame, (verb:gsub("%%", "%%%%")), hint)
    width = vim.fn.strdisplaywidth(("%s %s %s "):format(frame, verb, hint))
  elseif state.last_turn or state.context then
    local parts = {}
    if state.last_turn then
      parts[1] = ("%.1fs · $%.2f"):format(state.last_turn.duration_ms / 1000, state.cost_usd)
    end
    if state.context and tonumber(state.context.percent) then
      parts[#parts + 1] = ("%d%%%% context"):format(state.context.percent)
    end
    local info = table.concat(parts, " · ") .. " "
    text, width = "%#Comment#" .. info, api.nvim_strwidth((info:gsub("%%%%", "%%")))
  end
  return text .. "%#WinSeparator#" .. ("─"):rep(math.max(0, win_width(vim.g.statusline_winid) - width))
end

-- A short busy label for the statusline, so it shows from any window.
function M.working()
  if not (state.busy and state.turn_started) then
    return ""
  end
  local verb, secs = working()
  return ("✻ %s %ds"):format((verb:gsub("%.+$", ""):gsub("%%", "%%%%")), secs)
end

-- The mode's label, while the mode differs from the one the session started
-- in, as Claude Code shows none for its default mode. Plan mode always shows,
-- because it changes what Claude may do.
local function mode_label()
  local mode = state.permission_mode
  if mode == "plan" or mode ~= config.options.permission_mode then
    return mode_labels[mode]
  end
end

-- The model and its effort on the left. After them, the chip says what the
-- next prompt shows Claude, and a dot in each running agent's color follows,
-- with their count. The focused agent's dot is ◉. On the right, the follow
-- status says where Claude is, in the focused agent's color, then the mode's
-- label with its hint, or "? for shortcuts". In a narrow column, the hints go
-- first, then the branch, which the statusline shows too, then the agents'
-- count, the effort and the model. Then the follow status and the mode get
-- their short forms, the dots go, and the follow status goes to the
-- statusline. The chip, which says what Claude gets, goes last: first its
-- file name gets shorter.
---@param width integer
---@return [string, string?][] chunks, boolean follows The chunks show the follow status.
function M.footer(width)
  local w = api.nvim_strwidth
  local branch = state.branch and ("git:(" .. state.branch .. ") ") or ""
  local model = M.model_label(state.model or config.options.model)
  local effort = state.effort and (" · " .. state.effort) or ""
  local mode = state.waiting and { "⏺ Claude is waiting for you", "AnvimClaude", "⏺ waiting" } or mode_label()
  local hint = mode and not state.waiting and " (shift+tab to cycle)" or ""
  local shortcuts = not mode and M.shortcuts() and "? for shortcuts" or ""
  local follow = require("anvim.follow")
  local status = follow.status()
  local jump = follow.place() and not follow.following() and " (<leader>j)" or ""
  local context = require("anvim.context")
  local chip = context.chip()
  local agents = require("anvim.agents")
  local running = agents.running()
  local dots = {} ---@type [string, string][]
  for _, agent in ipairs(running) do
    if agent.slot then
      dots[#dots + 1] = { agent.id == follow.focus and "◉" or "⏺", agents.group(agent.slot) }
    end
  end
  local count = #dots > 0 and (" %d agent%s"):format(#running, #running == 1 and "" or "s") or ""
  -- The right side: the follow status, then the mode or the shortcuts hint.
  local function right()
    local place = status ~= "" and w(status .. jump) or 0
    local tail = mode and w(mode[1] .. hint) or w(shortcuts)
    return place + tail + (place > 0 and tail > 0 and 2 or 0)
  end
  -- Columns to spare between the left side and the right side.
  local function free()
    local r = right()
    local left = w(" anvim " .. branch .. model .. effort) + (chip and w("  " .. chip[1]) or 0)
    left = left + (#dots > 0 and 2 + #dots * w("⏺") + w(count) or 0)
    return width - left - (r > 0 and r + 3 or 0)
  end
  if free() < 0 then
    shortcuts = ""
  end
  if free() < 0 then
    hint = ""
  end
  if free() < 0 then
    jump = ""
  end
  if free() < 0 then
    branch = ""
  end
  if free() < 0 then
    count = ""
  end
  if free() < 0 then
    effort = ""
  end
  if free() < 0 then
    model = ""
  end
  if status ~= "" and free() < 0 then
    status = follow.status(true)
  end
  if mode and mode[3] and free() < 0 then
    mode = { mode[3], mode[2] }
  end
  if free() < 0 then
    dots = {}
  end
  if free() < 0 then
    status = ""
  end
  if chip and free() < 0 then
    chip = context.chip(w(chip[1]) + free())
  end
  local chunks = { { " anvim ", "AnvimClaude" }, { branch, "Comment" }, { model .. effort } }
  if chip then
    vim.list_extend(chunks, { { "  " }, chip })
  end
  if #dots > 0 then
    vim.list_extend(chunks, { { "  " }, unpack(dots) })
    chunks[#chunks + 1] = { count, "AnvimChip" }
  end
  if right() > 0 then
    chunks[#chunks + 1] = { (" "):rep(math.max(1, free() + 2)) }
    if status ~= "" then
      vim.list_extend(chunks, { { status, follow.group() }, { jump, "Comment" } })
    end
    local tail = mode and { { mode[1], mode[2] }, { hint, "Comment" } } or { { shortcuts, "Comment" } }
    if status ~= "" and w(tail[1][1]) > 0 then
      chunks[#chunks + 1] = { "  " }
    end
    vim.list_extend(chunks, tail)
    chunks[#chunks + 1] = { " " }
  end
  return chunks, status ~= ""
end

-- Whether the footer shows the follow status, as drawn.
function M.follows()
  return follows
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
  local chunks, shown = M.footer(win_width(win))
  footer_mark = api.nvim_buf_set_extmark(bufnr, ns, last, 0, {
    id = footer_mark,
    virt_lines = { chunks },
    virt_lines_leftcol = true,
  })
  if shown ~= follows then
    follows = shown
    api.nvim_exec_autocmds("User", { pattern = "AnvimStatus", modeline = false })
  end
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
