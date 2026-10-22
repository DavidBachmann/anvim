-- The three columns: tree | code | claude (transcript above input), or
-- mirrored, with Claude on the left.
local config = require("anvim.config")
local input = require("anvim.input")
local prefs = require("anvim.prefs")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api

---@type { code: integer?, transcript: integer?, input: integer? }
M.wins = {}
---@type integer? The tab page that holds the layout.
M.tab = nil
---@type integer? The buffer that the code window showed when it closed.
M.last_code_buf = nil
---@type integer? The tree's width when the code window closed.
local tree_width

local function valid(win)
  return win and api.nvim_win_is_valid(win)
end

-- A global statusline puts a separator row under the transcript. Blank it,
-- so the prompt's activity line is the only rule. Both windows of the Claude
-- column draw the corner where that row meets the vertical separator, and
-- with Claude on the left they also draw the vertical separator.
local function column_separator(win)
  local wo = vim.wo[win]
  local vert = vim.opt.fillchars:get().vert or "│"
  local fill = ("horiz: ,vertright:%s,vertleft:%s"):format(vert, vert)
  wo.fillchars = (vim.go.fillchars ~= "" and vim.go.fillchars .. "," or "") .. fill
  wo.winhighlight = wo.winhighlight .. ",WinSeparator:AnvimSeparator"
end

local function setup_transcript_win(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.breakindentopt = "list:-1"
  wo.cursorline = false
  -- Claude's markdown reads as Claude Code shows it: no ** or backticks, and
  -- no fence lines. Blank lines in Claude's text hold two spaces, which
  -- 'list' would mark.
  wo.conceallevel = 2
  wo.concealcursor = "nvc"
  wo.list = false
  wo.spell = false
  -- A drag puts the cursor where the mouse was pressed. With 'scrolloff', the
  -- view would scroll under the mouse there.
  wo.scrolloff = 0
  -- anvim turns on 'smoothscroll', which can leave a wrapped line half
  -- scrolled at the top, marked "<<<".
  wo.smoothscroll = false
  wo.winfixwidth = true
  wo.winfixbuf = true
  wo.winhighlight = "Normal:AnvimNormal,NormalNC:AnvimNormal"
  column_separator(win)
  -- In 0.12 this only drops the window number. Window commands and mouse
  -- clicks still enter it, so a WinEnter guard moves the cursor on.
  api.nvim_win_set_config(win, { focusable = false })
end

-- Files and Write previews. Only the code window shows them.
function M.is_code(buf)
  return vim.bo[buf].buftype == "" or vim.b[buf].anvim_preview ~= nil
end

local function is_special(win)
  return win == M.wins.transcript or win == M.wins.input or vim.bo[api.nvim_win_get_buf(win)].buftype ~= ""
end

local function claude_width()
  local width = config.options.layout.claude_width
  return width < 1 and math.floor(vim.o.columns * width) or width
end

-- The side of the Claude column, as the user last chose it.
---@return 'left'|'right'
function M.claude_side()
  return prefs.get("claude_side") == "left" and "left" or "right"
end

---@return 'left'|'right'
function M.tree_side()
  return M.claude_side() == "left" and "right" or "left"
end

-- The explorer's sidebar split. Its list is a float on top of it.
local function tree_win()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local snacks_win = vim.w[win].snacks_win
    if api.nvim_win_get_config(win).relative == "" and snacks_win and snacks_win.position == M.tree_side() then
      return win
    end
  end
end

-- A full-height window between the tree and the Claude column. Splitting the
-- transcript would only span the transcript's rows.
local function open_code_win(buf)
  local tree, win = tree_win(), nil
  if tree then
    local width = tree_width or api.nvim_win_get_width(tree)
    tree_width = nil
    -- The side of the tree that faces Claude.
    win = api.nvim_open_win(buf, false, { split = M.claude_side(), win = tree })
    api.nvim_win_set_width(tree, width)
  else
    win = api.nvim_open_win(buf, false, { split = M.tree_side(), win = -1 })
  end
  if valid(M.wins.transcript) then
    api.nvim_win_set_width(M.wins.transcript, claude_width())
  end
  return win
end

-- The code window's own options. Its winbar names its file, because the
-- statusline names the prompt's buffer while the cursor is there. Groups in a
-- winbar combine with WinBar, which often has the statusline's background.
-- 'winhighlight' maps no other group, so a code window that split the prompt
-- drops the prompt's background. Wrapped lines keep their indent.
M.code_options = {
  winbar = "%!v:lua.require'anvim.layout'.winbar_text()",
  winhighlight = "WinBar:AnvimWinBar,WinBarNC:AnvimWinBar",
  breakindent = true,
}

-- Text wraps in the code window, also when the user turned wrap off.
M.text_filetypes = { text = true, plaintex = true, typst = true, gitcommit = true, markdown = true }

-- Whether the code window wraps code, as the user last chose it.
function M.wraps()
  return prefs.get("code_wrap") ~= false
end

---@param on boolean
function M.set_wrap(on)
  prefs.set("code_wrap", on)
  require("anvim.follow").apply(M.wins.code)
end

function M.winbar_text()
  local buf = api.nvim_win_get_buf(vim.g.statusline_winid)
  local context = require("anvim.context")
  local file = context.file(buf)
  if not file then
    return ""
  end
  local text = " " .. (context.relpath(file):gsub("%%", "%%%%"))
  return vim.b[buf].anvim_preview and text .. "%#AnvimWinBarWriting# (writing)" or text
end

-- snacks' pickers jump into a window that shows a file, or else into one with
-- this mark. The code window can show a Write preview, which is no file, and
-- without the mark a picker would jump into the Claude column.
local function set_code_win(win)
  vim.w[win].snacks_main = true
  M.wins.code = win
  -- A new window copies the line numbers of the window it opened from.
  require("anvim.follow").apply(win)
  return win
end

-- The window that follow mode drives. Recreated if the user closed it.
function M.code_win()
  if valid(M.wins.code) then
    return M.wins.code
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == "" and not is_special(win) then
      return set_code_win(win)
    end
  end
  local buf = M.last_code_buf
  if not (buf and api.nvim_buf_is_loaded(buf)) then
    buf = api.nvim_create_buf(true, false)
  end
  return set_code_win(open_code_win(buf))
end

-- Runs before the code window closes. Neovim then gives its columns to the
-- tree, because the Claude column has 'winfixwidth'.
function M.code_closing(buf)
  M.last_code_buf = buf
  local tree = tree_win()
  tree_width = tree and api.nvim_win_get_width(tree)
end

-- The explorer, with anvim's layout, but without taking focus.
local function open_tree()
  local ok, snacks = pcall(require, "snacks")
  if ok then
    snacks.explorer({ focus = false })
  end
end

-- Insert commands. Where nothing can change, in a file buffer or in read
-- mode, they go to the prompt and type there.
M.insert_keys = { "i", "a", "I", "A", "o", "O" }

---@param opts? { insert: boolean? } With insert false, the prompt stays in normal mode.
function M.focus_input(opts)
  if valid(M.wins.input) then
    api.nvim_set_current_win(M.wins.input)
    if opts and opts.insert == false then
      -- Entering the prompt asked for insert mode, which starts only after
      -- this callback. Cancel it.
      vim.cmd.stopinsert()
    else
      input.resume()
    end
  end
end

-- The empty buffer that Neovim starts with is not listed, so :bnext and the
-- buffer picker skip it, and it goes away once the code window shows a file.
local function drop_when_hidden(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, 2, false)
  if api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified and #lines == 1 and lines[1] == "" then
    vim.bo[buf].buflisted = false
    vim.bo[buf].bufhidden = "wipe"
  end
end

-- Reopens the windows that the user closed, and keeps the cursor where it is.
-- A prompt or transcript window that lost its buffer, as after :bdelete, opens
-- again with a new one.
function M.repair()
  for role, buf in pairs({ transcript = transcript.buf(), input = input.buf() }) do
    local win = M.wins[role]
    if valid(win) and api.nvim_win_get_buf(win) ~= buf then
      pcall(api.nvim_win_close, win, true)
    end
  end
  if valid(M.wins.code) and valid(M.wins.transcript) and valid(M.wins.input) then
    return
  end
  if not valid(M.wins.transcript) then
    local opts = { split = M.claude_side(), win = -1, width = claude_width() }
    if valid(M.wins.input) then
      opts = { split = "above", win = M.wins.input }
    end
    M.wins.transcript = api.nvim_open_win(transcript.buf(), false, opts)
    setup_transcript_win(M.wins.transcript)
  end
  if not valid(M.wins.input) then
    M.wins.input = api.nvim_open_win(input.buf(), false, {
      split = "below",
      win = M.wins.transcript,
      height = config.options.layout.input_height.min + 1,
    })
    input.setup_win(M.wins.input)
    column_separator(M.wins.input)
  end
  M.code_win()
  api.nvim_win_set_width(M.wins.transcript, claude_width())
  input.render()
end

-- Moves the Claude column to a side, and the tree to the other side. The
-- code window stays between them.
---@param side 'left'|'right'
function M.set_claude_side(side)
  prefs.set("claude_side", side)
  local code, top, bottom = M.wins.code, M.wins.transcript, M.wins.input
  if not (valid(code) and valid(top) and valid(bottom)) then
    return
  end
  -- With win -1, the split goes to the current tab page. Make that the
  -- layout's tab page.
  api.nvim_win_call(code, function()
    api.nvim_win_set_config(top, { split = side, win = -1 })
  end)
  api.nvim_win_set_config(bottom, { split = "below", win = top })
  api.nvim_win_set_width(top, claude_width())
  input.render()
  -- Last, because snacks flushes a redraw when it lays the explorer out. The
  -- layout takes the side from M.tree_side().
  local explorer = require("anvim.tree").explorer()
  if explorer then
    explorer:set_layout()
  end
end

function M.open()
  if valid(M.wins.code) then
    api.nvim_set_current_tabpage(api.nvim_win_get_tabpage(M.wins.code))
  end
  M.tab = api.nvim_get_current_tabpage()
  M.wins.code = M.code_win()
  drop_when_hidden(api.nvim_win_get_buf(M.wins.code))
  M.repair()
  api.nvim_set_current_win(M.wins.code)
  open_tree()
  -- In normal mode, the first keys can be window keys and <leader> maps.
  vim.schedule(function()
    M.focus_input({ insert = false })
  end)
end

function M.setup()
  local group = api.nvim_create_augroup("anvim.layout", {})
  -- The Claude column keeps its share of the screen. 'winfixwidth' alone would
  -- keep it at the narrowest width it was ever squeezed to.
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if valid(M.wins.transcript) then
        api.nvim_win_set_width(M.wins.transcript, claude_width())
      end
    end,
  })
  -- A split of the code window copies its winbar, and so does a window that
  -- shows a buffer which the code window showed last.
  api.nvim_create_autocmd({ "WinNew", "BufWinEnter" }, {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      if win ~= M.wins.code and vim.wo[win].winbar == M.code_options.winbar then
        vim.wo[win].winbar = ""
      end
    end,
  })
end

return M
