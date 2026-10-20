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
local spinner_frames = { "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" }

-- Each label, its highlight, and a short form for a narrow column.
local mode_labels = {
  acceptEdits = { "⏵⏵ accept edits on", "AnvimModeEdits", "⏵⏵ accept edits" },
  plan = { "⏸ plan mode on", "AnvimModePlan", "⏸ plan" },
  bypassPermissions = { "⏵⏵ bypass permissions on", "AnvimModeBypass", "⏵⏵ bypass" },
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
  -- A chat prompt reads better without auto-closed quotes and brackets.
  vim.b[bufnr].minipairs_disable = true
  local map = function(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = bufnr, desc = desc })
  end
  -- While a permission prompt waits, these keys answer it.
  local or_answer = function(key, fn)
    return function()
      if not require("anvim.permission").key(key) then
        fn()
      end
    end
  end
  map({ "i", "n" }, "<CR>", or_answer("<CR>", M.submit), "Send prompt")
  map("i", "<S-CR>", "<CR>", "New line")
  map("i", "<M-CR>", "<CR>", "New line")
  map("n", "<Esc>", or_answer("<Esc>", M.interrupt), "Interrupt Claude")
  map({ "i", "n" }, "<C-c>", M.interrupt, "Interrupt Claude")
  map({ "i", "n" }, "<S-Tab>", M.cycle_mode, "Cycle permission mode")
  map({ "i", "n" }, "<C-x>", function()
    require("anvim.context").clear()
  end, "Unpin the selection")
  map({ "i", "n" }, "<C-g>", function()
    require("anvim.compose").open()
  end, "Write the prompt in a large window")
  -- The transcript takes no focus, so the prompt scrolls it.
  local function scroll(modes, keys)
    for _, key in ipairs(keys) do
      map(modes, key, function()
        require("anvim.windows").scroll(key)
      end, "Scroll the transcript")
    end
  end
  scroll("n", { "<C-u>", "<C-d>", "<C-b>", "<C-f>" })
  scroll({ "n", "i" }, { "<PageUp>", "<PageDown>" })
  vim.keymap.set({ "n", "i" }, "<LeftDrag>", function()
    return require("anvim.windows").drag_keys()
  end, { buffer = bufnr, expr = true, desc = "Select in the transcript" })
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

-- The model on the left and the mode on the right. After the model, the chip
-- says what the next prompt shows Claude. In a narrow column, the hint goes
-- first, then the branch, which the statusline shows too. Then the mode gets
-- its short label, the chip's file name gets shorter, and last the chip goes.
---@param width integer
---@return [string, string?][] chunks
function M.footer(width)
  local w = api.nvim_strwidth
  local branch = state.branch and ("git:(" .. state.branch .. ") ") or ""
  local model = M.model_label(state.model or config.options.model)
  local mode = state.waiting and { "⏺ Claude is waiting for you", "AnvimClaude" }
    or mode_labels[state.permission_mode]
  local hint = state.waiting and "" or " (shift+tab to cycle)"
  local context = require("anvim.context")
  local chip = context.chip()
  -- Columns to spare between the left side and the right side.
  local function free()
    local right = mode and 2 + w(mode[1] .. hint .. " ") or 0
    return width - w(" anvim " .. branch .. model) - (chip and w("  " .. chip[1]) or 0) - right
  end
  if free() < 0 then
    hint = ""
  end
  if free() < 0 then
    branch = ""
  end
  if mode and mode[3] and free() < 0 then
    mode = { mode[3], mode[2] }
  end
  if chip and free() < 0 then
    chip = context.chip(w(chip[1]) + free())
  end
  local chunks = { { " anvim ", "AnvimClaude" }, { branch, "Comment" }, { model } }
  if chip then
    vim.list_extend(chunks, { { "  " }, chip })
  end
  if mode then
    vim.list_extend(chunks, {
      { (" "):rep(math.max(1, free() + 2)) },
      { mode[1], mode[2] },
      { hint, "Comment" },
      { " " },
    })
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
    virt_lines = { M.footer(win_width(win)) },
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
end

return M
