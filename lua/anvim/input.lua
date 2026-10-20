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

local mode_labels = {
  acceptEdits = { "⏵⏵ accept edits on", "AnvimModeEdits" },
  plan = { "⏸ plan mode on", "AnvimModePlan" },
  bypassPermissions = { "⏵⏵ bypass permissions on", "AnvimModeBypass" },
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
  map({ "i", "n" }, "<CR>", M.submit, "Send prompt")
  map("i", "<S-CR>", "<CR>", "New line")
  map("i", "<M-CR>", "<CR>", "New line")
  map("n", "<Esc>", M.interrupt, "Interrupt Claude")
  map({ "i", "n" }, "<C-c>", M.interrupt, "Interrupt Claude")
  map({ "i", "n" }, "<S-Tab>", M.cycle_mode, "Cycle permission mode")
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
  wo.winfixheight = true
  wo.winfixbuf = true
  M.render()
end

-- Starts insert mode where typing stopped. <Esc> leaves the cursor on the
-- character before that place, so a plain :startinsert lands one short.
-- With `at_cursor`, as after a click, insert mode starts at the cursor. While
-- a request waits for an answer, the prompt stays in normal mode.
---@param opts? { at_cursor: boolean? }
function M.resume(opts)
  local win = prompt_win()
  if win ~= api.nvim_get_current_win() or state.waiting then
    return
  end
  if opts and opts.at_cursor then
    vim.cmd.startinsert()
    return
  end
  local row, col = unpack(api.nvim_buf_get_mark(bufnr, "^"))
  local cursor = api.nvim_win_get_cursor(win)
  local line = api.nvim_get_current_line()
  if row == cursor[1] and col <= #line then
    local before = col > 0 and col - 1 + vim.str_utf_start(line, col) or 0
    if cursor[2] == col or cursor[2] == before then
      if col == #line then
        vim.cmd.startinsert({ bang = true })
        return
      end
      api.nvim_win_set_cursor(win, { row, col })
    end
  end
  vim.cmd.startinsert()
end

function M.submit()
  local buf = M.buf()
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  M.send(text)
end

function M.send(text)
  transcript.user(text)
  sidecar.send({ type = "prompt", text = text })
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

---@return string verb, integer secs
local function working()
  local verb = state.thinking and "Thinking..." or "Working..."
  return verb, math.floor((vim.uv.now() - state.turn_started) / 1000)
end

-- The line between transcript and prompt: a rule, with the spinner while Claude works.
function M.activity()
  local text, width = "", 0
  if state.process == "exited" then
    text, width = "%#AnvimToolError#sidecar exited ", 15
  elseif state.busy and state.turn_started then
    local frame = spinner_frames[math.floor(vim.uv.now() / 120) % #spinner_frames + 1]
    local verb, secs = working()
    local hint = ("(%ds · esc to interrupt)"):format(secs)
    text = ("%%#AnvimClaude#%s %s %%#Comment#%s "):format(frame, verb, hint)
    width = vim.fn.strdisplaywidth(("%s %s %s "):format(frame, verb, hint))
  elseif state.last_turn then
    local info = ("%.1fs · $%.2f "):format(state.last_turn.duration_ms / 1000, state.cost_usd)
    text, width = "%#Comment#" .. info, vim.fn.strdisplaywidth(info)
  end
  return text .. "%#WinSeparator#" .. ("─"):rep(math.max(0, win_width(vim.g.statusline_winid) - width))
end

-- A short busy label for the statusline, so it shows from any window.
function M.working()
  if not (state.busy and state.turn_started) then
    return ""
  end
  local verb, secs = working()
  return ("✻ %s %ds"):format((verb:gsub("%.+$", "")), secs)
end

---@param width integer
---@return [string, string?][] chunks
function M.footer(width)
  local branch = state.branch and ("git:(" .. state.branch .. ") ") or ""
  local model = M.model_label(state.model or config.options.model)
  local chunks = { { " anvim ", "AnvimClaude" }, { branch, "Comment" }, { model } }
  local mode = mode_labels[state.permission_mode]
  if mode then
    local left = vim.fn.strdisplaywidth(" anvim " .. branch .. model)
    local hint = " (shift+tab to cycle)"
    if left + 2 + vim.fn.strdisplaywidth(mode[1] .. hint .. " ") > width then
      hint = ""
    end
    local right = vim.fn.strdisplaywidth(mode[1] .. hint .. " ")
    vim.list_extend(chunks, {
      { (" "):rep(math.max(1, width - left - right)) },
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
  sidecar.on("turn_start", function()
    M.set_busy(true)
  end)
  sidecar.on("turn_end", function(ev)
    state.last_turn = { duration_ms = ev.duration_ms, cost_usd = ev.cost_usd }
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
