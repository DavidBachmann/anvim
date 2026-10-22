-- The window rules of the anvim tab. The transcript takes no focus, except in
-- read mode. Only the code window shows files. Closed windows come back.
local config = require("anvim.config")
local input = require("anvim.input")
local layout = require("anvim.layout")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api
local wins = layout.wins
local ns = api.nvim_create_namespace("anvim.windows")
local left_mouse = vim.keycode("<LeftMouse>")
local left_drag = vim.keycode("<LeftDrag>")

---@type integer? The window that the cursor left last.
local left
---@type integer? The window the cursor was in before the prompt, for <C-w>p.
local before_prompt
---@type string? The last key, to tell mouse clicks from window commands.
local last_key
---@type vim.fn.getmousepos.ret? A click in the transcript that moved on to the prompt.
local press
---@type vim.fn.getmousepos.ret? Where the current drag started.
local drag_start
---@type { buf: integer, view: vim.fn.winsaveview.ret }? The code window just before the last split.
local before_split
---@type table<integer, { buf: integer, lnum: integer, col: integer }> Windows that the last command made, as Neovim made them.
local born = {}
local pending = false
local scheduled = false
local checking = false
---@type integer? The window where anvim ended insert mode. Its cursor stays where the click put it.
local keep_cursor
---@type [integer, integer]?
local kept
---@type boolean The code window had the cursor when it closed.
local refocus_code = false
local notified = false
-- Set when a command is about to quit Neovim. A quit that fails reaches
-- SafeState, which clears it.
local quitting = false

local function valid(win)
  return win ~= nil and win ~= 0 and api.nvim_win_is_valid(win)
end

local function in_tab()
  return layout.tab ~= nil and api.nvim_get_current_tabpage() == layout.tab
end

local function reading(win)
  return vim.w[win].anvim_read == true
end

-- Whether the command that runs is a mouse click.
function M.clicked()
  return last_key == left_mouse
end

-- Moves the cursor without autocmds.
function M.hop(win)
  vim.cmd(("noautocmd call nvim_set_current_win(%d)"):format(win))
end
local hop = M.hop

-- Read mode lets the cursor into the transcript, to yank and search. Leaving
-- the window ends it.
function M.read()
  local win = wins.transcript
  if valid(win) then
    vim.w[win].anvim_read = true
    vim.cmd.stopinsert()
    api.nvim_set_current_win(win)
  end
end

-- The window before `win` in <C-w>W order, leaving out the Claude column.
local function window_before(win)
  local list = vim.tbl_filter(function(w)
    return api.nvim_win_get_config(w).relative == ""
  end, api.nvim_tabpage_list_wins(0))
  local at = vim.fn.index(list, win) + 1
  for i = 1, #list - 1 do
    local w = list[(at - i - 1) % #list + 1]
    if w ~= wins.input and w ~= wins.transcript then
      return w
    end
  end
  return wins.input
end

-- Moves the cursor from the transcript on to the prompt. Neovim has already
-- made the transcript the previous window, so hop back first, and <C-w>p
-- still goes where the user came from.
local function leave_transcript()
  local prompt = wins.input
  if not valid(prompt) then
    return
  end
  local mouse = vim.fn.getmousepos()
  if last_key == left_mouse and mouse.winid == wins.transcript then
    press = mouse
  end
  local from = left == prompt and before_prompt or left
  if valid(from) and from ~= wins.transcript then
    hop(from)
  end
  if left ~= prompt then
    api.nvim_set_current_win(prompt)
  elseif last_key == "W" then
    -- <C-w>W goes on to the window before the transcript.
    hop(prompt)
    api.nvim_set_current_win(window_before(wins.transcript))
  else
    -- Other moves from the prompt, such as <C-w>k, stay in the prompt.
    hop(prompt)
  end
end

local function enter_input()
  if (left == wins.transcript or not valid(left)) and valid(before_prompt) then
    -- From read mode, or from a window that closed, such as the compose
    -- window. <C-w>p cannot go back there, so make the window before the
    -- prompt the previous one.
    hop(before_prompt)
    hop(wins.input)
  elseif
    valid(left)
    and left ~= wins.input
    and api.nvim_win_get_config(left).relative == ""
    and api.nvim_win_get_tabpage(left) == layout.tab
  then
    before_prompt = left
  end
  if not config.options.input.auto_insert then
    return
  end
  if last_key == left_mouse and vim.fn.getmousepos().winid == wins.input then
    -- The click moves the cursor after WinEnter, so insert where it lands.
    input.resume({ at_cursor = true })
  elseif checking then
    -- A :startinsert from SafeState waits for the next command. One from the
    -- event loop starts at once.
    vim.schedule(input.resume)
  else
    input.resume()
  end
end

-- Insert mode follows a click or an API call into another window. Where the
-- buffer cannot change, it only gives E21 for each key, so it ends. A terminal
-- goes on to terminal mode, as Neovim does.
local function stop_insert()
  local mode = api.nvim_get_mode().mode
  local buf = api.nvim_get_current_buf()
  local insert = mode:match("^n?i") or mode:match("^R")
  if not insert or vim.bo[buf].modifiable or vim.bo[buf].buftype == "terminal" then
    return
  end
  vim.cmd.stopinsert()
  if not mode:match("^n") then
    keep_cursor = api.nvim_get_current_win()
  end
end

-- The prompt's <LeftDrag>. A drag that starts in the transcript, where the
-- press moved the cursor to the prompt, selects text in the transcript.
function M.drag_keys()
  if not press then
    return "<LeftDrag>"
  end
  drag_start, press = press, nil
  local stop = api.nvim_get_mode().mode:sub(1, 1) == "i" and "<Esc>" or ""
  return stop .. "<Cmd>lua require('anvim.windows').drag()<CR>v<LeftDrag>"
end

-- Puts the cursor where the drag started, in read mode.
function M.drag()
  local from, win = drag_start, wins.transcript
  drag_start = nil
  if from and from.line > 0 and valid(win) then
    M.read()
    local line = api.nvim_buf_get_lines(transcript.buf(), from.line - 1, from.line, false)[1] or ""
    api.nvim_win_set_cursor(win, { from.line, math.min(from.column - 1, math.max(#line - 1, 0)) })
  end
end

-- The windows of such a buffer, such as the transcript, stop scrolling at its
-- end, as a chat does. snacks.scroll animates toward the view that its own
-- WinScrolled handler sees, which is past the end if it runs before ours, so
-- it leaves these buffers alone.
function M.stop_at_end(buf)
  vim.b[buf].anvim_stop_at_end = true
  vim.b[buf].snacks_scroll = false
end

-- Neovim scrolls a window until its last line is at the top. Past the end,
-- the view goes back to where the last row is at the bottom row, or the
-- whole text shows from line 1. The view only moves back toward line 1, so
-- the cursor stays in view.
function M.clamp(win)
  local rows = vim.fn.winheight(win)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local opts = { start_row = view.topline - 1, start_vcol = view.skipcol, max_height = rows }
  if view.topfill + api.nvim_win_text_height(win, opts).all >= rows then
    return
  end
  -- The first line from which the rest fits.
  local top = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  while top > 1 and api.nvim_win_text_height(win, { start_row = top - 2 }).all <= rows do
    top = top - 1
  end
  local fill = api.nvim_win_text_height(win, { start_row = top - 1, end_row = top - 1, end_vcol = 0 }).fill
  if view.topline ~= top or view.topfill ~= fill or view.skipcol ~= 0 then
    api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = top, topfill = fill, skipcol = 0 })
    end)
  end
end

function M.scroll(key)
  local win = wins.transcript
  if valid(win) then
    api.nvim_win_call(win, function()
      vim.cmd.normal({ vim.keycode(key), bang = true })
    end)
  end
end

-- The view of an extra window. When nothing moved it since Neovim made it, as
-- after <C-w>s, use the code window's view from before the split instead:
-- 'splitkeep' and 'scrolloff' moved the cursors of both windows.
local function extra_view(win, buf)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local new = born[win]
  if new and new.buf == buf and new.lnum == view.lnum and new.col == view.col then
    if before_split and before_split.buf == buf then
      return before_split.view
    end
  end
  return view
end

-- Closes an extra window and shows its buffer in the code window, at the same
-- place. The view moves only after the close, because 'splitkeep' shifts the
-- code window's view while the two share the column.
local function fold(win)
  local code = layout.code_win()
  local buf, diff = api.nvim_win_get_buf(win), vim.wo[win].diff
  local view = extra_view(win, buf)
  if api.nvim_get_current_win() == win then
    api.nvim_set_current_win(code)
  end
  api.nvim_win_close(win, true)
  api.nvim_win_call(code, function()
    vim.cmd("normal! m'")
    api.nvim_win_set_buf(code, buf)
    vim.fn.winrestview(view)
    if diff or vim.wo.diff then
      vim.cmd.diffoff()
    end
  end)
  if not notified then
    notified = true
    vim.notify("anvim keeps one code window, so files open there", vim.log.levels.INFO)
  end
end

---@return 'code'|'copy'|nil kind A second window that shows code, or a copy of the prompt, the compose window or the transcript.
local function extra(win)
  if win == wins.code or api.nvim_win_get_config(win).relative ~= "" or vim.w[win].snacks_win then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  if buf == input.buf() or vim.bo[buf].filetype == "anvim_input" then
    return win ~= wins.input and "copy" or nil
  elseif buf == transcript.buf() then
    return win ~= wins.transcript and "copy" or nil
  elseif layout.is_code(buf) then
    return "code"
  end
end

local function fix()
  layout.repair()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local kind = valid(win) and extra(win)
    if kind == "code" then
      fold(win)
    elseif kind == "copy" then
      local current = api.nvim_get_current_win() == win
      api.nvim_win_close(win, true)
      if current then
        api.nvim_set_current_win(wins.input)
      end
    end
  end
  if refocus_code and valid(wins.code) then
    api.nvim_set_current_win(wins.code)
  end
  refocus_code = false
  local current = api.nvim_get_current_win()
  if current == wins.transcript and not reading(current) then
    leave_transcript()
  end
end

-- Runs once the command that changed the windows is done: at SafeState, which
-- comes before the redraw, or from the event loop for API calls.
local function check()
  if not pending or quitting or not in_tab() then
    return
  end
  pending = false
  checking = true
  local ok, err = pcall(fix)
  checking = false
  born = {}
  if not ok then
    error(err, 0)
  end
end

local function mark()
  pending = true
  if not scheduled then
    scheduled = true
    vim.schedule(function()
      scheduled = false
      check()
    end)
  end
end

function M.setup()
  local group = api.nvim_create_augroup("anvim.windows", {})
  -- WinScrolled comes before the redraw, in normal and in insert mode, so no
  -- frame shows a view past the end. It names every window that scrolled,
  -- such as the transcript under the wheel while the prompt has the cursor.
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      for id in pairs(vim.v.event) do
        local win = tonumber(id)
        if win and api.nvim_win_is_valid(win) and vim.b[api.nvim_win_get_buf(win)].anvim_stop_at_end then
          M.clamp(win)
        end
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "TabEnter" }, { group = group, callback = mark })
  api.nvim_create_autocmd("WinNewPre", {
    group = group,
    callback = function()
      local code = wins.code
      if in_tab() and valid(code) then
        before_split = { buf = api.nvim_win_get_buf(code), view = api.nvim_win_call(code, vim.fn.winsaveview) }
      end
    end,
  })
  api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      local cursor = api.nvim_win_get_cursor(win)
      born[win] = { buf = api.nvim_win_get_buf(win), lnum = cursor[1], col = cursor[2] }
      mark()
    end,
  })
  -- Nested, so that moving the cursor fires WinEnter.
  api.nvim_create_autocmd("SafeState", {
    group = group,
    nested = true,
    callback = function()
      quitting = false
      check()
    end,
  })
  -- When the code window closes, the tree, if it shows, takes its columns,
  -- and the explorer flushes a redraw from its own WinResized handler, before
  -- SafeState. anvim defines this one before it opens the explorer, so it
  -- runs first.
  api.nvim_create_autocmd("WinResized", {
    group = group,
    nested = true,
    callback = function()
      if not valid(wins.code) then
        check()
      end
    end,
  })
  api.nvim_create_autocmd("ExitPre", {
    group = group,
    callback = function()
      quitting = true
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == wins.code then
        layout.code_closing(ev.buf)
        refocus_code = api.nvim_get_current_win() == win
      end
      born[win] = nil
      mark()
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      left = api.nvim_get_current_win()
      if left == wins.transcript then
        vim.w[left].anvim_read = nil
      end
    end,
  })
  -- Nested, so that the prompt's own WinEnter handlers run, such as follow
  -- mode's catch-up.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    nested = true,
    callback = function()
      mark()
      local win = api.nvim_get_current_win()
      if in_tab() and win == wins.transcript and not reading(win) then
        leave_transcript()
      elseif in_tab() and win == wins.input then
        enter_input()
      end
      stop_insert()
    end,
  })
  -- Like <Esc>, the end of insert mode moves the cursor one left, after this.
  api.nvim_create_autocmd("InsertLeavePre", {
    group = group,
    callback = function()
      if keep_cursor == api.nvim_get_current_win() then
        kept = api.nvim_win_get_cursor(0)
      end
      keep_cursor = nil
    end,
  })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      if kept then
        pcall(api.nvim_win_set_cursor, 0, kept)
        kept = nil
      end
    end,
  })
  -- :q in the code window, the prompt or the transcript quits anvim. Closing
  -- the other tabs and windows first makes :q close the last one.
  api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local current = api.nvim_get_current_win()
      if not (in_tab() and (current == wins.code or current == wins.input or current == wins.transcript)) then
        return
      end
      quitting = true
      if #api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd.tabonly)
      end
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= current then
          pcall(api.nvim_win_close, win, true)
        end
      end
      -- These closes fire no WinClosed. If the quit fails, SafeState repairs.
      mark()
    end,
  })

  vim.on_key(function(key, typed)
    last_key = key
    -- Only counts while its own command runs. The event loop runs after that.
    vim.schedule(function()
      if last_key == key then
        last_key = nil
      end
    end)
    -- Keys from :normal, such as the steps of a scroll animation, are not typed.
    if typed ~= "" and key ~= left_drag then
      press = nil
    end
  end, ns)
  require("anvim.keys").set("claude", "n", "<leader>cr", M.read)
end

return M
