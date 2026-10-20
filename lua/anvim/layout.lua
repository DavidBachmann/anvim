-- The three columns: tree | code | claude (transcript above input).
local config = require("anvim.config")
local input = require("anvim.input")
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
  -- A drag puts the cursor where the mouse was pressed. With 'scrolloff', the
  -- view would scroll under the mouse there.
  wo.scrolloff = 0
  -- LazyVim turns on 'smoothscroll', which can leave a wrapped line half
  -- scrolled at the top, marked "<<<".
  wo.smoothscroll = false
  wo.winfixwidth = true
  wo.winfixbuf = true
  -- A global statusline puts a separator row under the transcript. Blank it,
  -- so the prompt's activity line is the only rule.
  local vert = vim.opt.fillchars:get().vert or "│"
  wo.fillchars = (vim.go.fillchars ~= "" and vim.go.fillchars .. "," or "") .. "horiz: ,vertright:" .. vert
  wo.winhighlight = "WinSeparator:AnvimSeparator"
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

-- The explorer's sidebar split. Its list is a float on top of it.
local function tree_win()
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local snacks_win = vim.w[win].snacks_win
    if api.nvim_win_get_config(win).relative == "" and snacks_win and snacks_win.position == "left" then
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
    win = api.nvim_open_win(buf, false, { split = "right", win = tree })
    api.nvim_win_set_width(tree, width)
  else
    win = api.nvim_open_win(buf, false, { split = "left", win = -1 })
  end
  if valid(M.wins.transcript) then
    api.nvim_win_set_width(M.wins.transcript, claude_width())
  end
  return win
end

-- The window that follow mode drives. Recreated if the user closed it.
function M.code_win()
  if valid(M.wins.code) then
    return M.wins.code
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == "" and not is_special(win) then
      M.wins.code = win
      return win
    end
  end
  local buf = M.last_code_buf
  if not (buf and api.nvim_buf_is_loaded(buf)) then
    buf = api.nvim_create_buf(true, false)
  end
  M.wins.code = open_code_win(buf)
  return M.wins.code
end

-- Runs before the code window closes. Neovim then gives its columns to the
-- tree, because the Claude column has 'winfixwidth'.
function M.code_closing(buf)
  M.last_code_buf = buf
  local tree = tree_win()
  tree_width = tree and api.nvim_win_get_width(tree)
end

-- The user's own explorer, with their layout, but without taking focus.
local function open_tree()
  local ok, snacks = pcall(require, "snacks")
  if ok then
    snacks.explorer({ focus = false })
  end
end

function M.focus_input()
  if valid(M.wins.input) then
    api.nvim_set_current_win(M.wins.input)
    input.resume()
  end
end

-- The empty buffer that Neovim starts with gets no bufferline tab, and goes
-- away once the code window shows a file.
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
    local opts = { split = "right", win = -1, width = claude_width() }
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
  end
  M.code_win()
  api.nvim_win_set_width(M.wins.transcript, claude_width())
  input.render()
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
  vim.schedule(M.focus_input)
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
end

return M
