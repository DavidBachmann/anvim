-- The three columns: tree | code | claude (transcript above input).
local config = require("anvim.config")
local input = require("anvim.input")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api

---@type { code: integer?, transcript: integer?, input: integer? }
M.wins = {}

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
  wo.winfixwidth = true
  wo.winfixbuf = true
  -- A global statusline puts a separator row under the transcript. Blank it,
  -- so the prompt's activity line is the only rule.
  local vert = vim.opt.fillchars:get().vert or "│"
  wo.fillchars = (vim.go.fillchars ~= "" and vim.go.fillchars .. "," or "") .. "horiz: ,vertright:" .. vert
  wo.winhighlight = "WinSeparator:AnvimSeparator"
end

local function is_special(win)
  return win == M.wins.transcript or win == M.wins.input or vim.bo[api.nvim_win_get_buf(win)].buftype ~= ""
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
  local anchor = valid(M.wins.transcript) and M.wins.transcript or 0
  M.wins.code = api.nvim_open_win(api.nvim_create_buf(true, false), false, { split = "left", win = anchor })
  return M.wins.code
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
    vim.cmd.startinsert({ bang = true })
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

local function claude_width()
  local width = config.options.layout.claude_width
  return width < 1 and math.floor(vim.o.columns * width) or width
end

function M.open()
  local opts = config.options.layout
  M.wins.code = M.code_win()
  drop_when_hidden(api.nvim_win_get_buf(M.wins.code))
  if not valid(M.wins.transcript) then
    M.wins.transcript =
      api.nvim_open_win(transcript.buf(), false, { split = "right", win = -1, width = claude_width() })
    setup_transcript_win(M.wins.transcript)
  end
  if not valid(M.wins.input) then
    M.wins.input = api.nvim_open_win(input.buf(), false, {
      split = "below",
      win = M.wins.transcript,
      height = opts.input_height.min + 1,
    })
    input.setup_win(M.wins.input)
  end
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
  -- :q in the last code window quits anvim instead of leaving the side panels.
  api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local current = api.nvim_get_current_win()
      if is_special(current) then
        return
      end
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= current and api.nvim_win_get_config(win).relative == "" and not is_special(win) then
          return
        end
      end
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= current then
          pcall(api.nvim_win_close, win, true)
        end
      end
    end,
  })
end

return M
