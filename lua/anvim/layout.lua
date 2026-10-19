-- The three columns: tree | code | claude (transcript above input).
local config = require('anvim.config')
local input = require('anvim.input')
local transcript = require('anvim.transcript')

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
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.statuscolumn = ''
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.breakindentopt = 'list:-1'
  wo.cursorline = false
  wo.winfixwidth = true
  wo.winfixbuf = true
  wo.statusline = "%!v:lua.require'anvim.input'.activity()"
end

local function is_special(win)
  return win == M.wins.transcript or win == M.wins.input or vim.bo[api.nvim_win_get_buf(win)].buftype ~= ''
end

-- The window that follow mode drives. Recreated if the user closed it.
function M.code_win()
  if valid(M.wins.code) then
    return M.wins.code
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == '' and not is_special(win) then
      M.wins.code = win
      return win
    end
  end
  local anchor = valid(M.wins.transcript) and M.wins.transcript or 0
  M.wins.code = api.nvim_open_win(api.nvim_create_buf(true, false), false, { split = 'left', win = anchor })
  return M.wins.code
end

local function open_tree()
  local ok, snacks = pcall(require, 'snacks')
  if not ok then
    return
  end
  snacks.explorer({
    focus = false,
    layout = {
      preset = 'sidebar',
      preview = false,
      layout = {
        backdrop = false,
        width = config.options.layout.tree_width,
        min_width = config.options.layout.tree_width,
        position = 'left',
        border = 'none',
        box = 'vertical',
        { win = 'list', border = 'none' },
      },
    },
  })
end

function M.focus_input()
  if valid(M.wins.input) then
    api.nvim_set_current_win(M.wins.input)
    vim.cmd.startinsert({ bang = true })
  end
end

function M.open()
  local opts = config.options.layout
  M.wins.code = M.code_win()
  if not valid(M.wins.transcript) then
    local width = opts.claude_width < 1 and math.floor(vim.o.columns * opts.claude_width) or opts.claude_width
    M.wins.transcript = api.nvim_open_win(transcript.buf(), false, { split = 'right', win = -1, width = width })
    setup_transcript_win(M.wins.transcript)
  end
  if not valid(M.wins.input) then
    M.wins.input = api.nvim_open_win(input.buf(), false, {
      split = 'below',
      win = M.wins.transcript,
      height = opts.input_height,
    })
    input.setup_win(M.wins.input)
  end
  api.nvim_set_current_win(M.wins.code)
  open_tree()
  vim.schedule(M.focus_input)
end

-- :q in the last code window quits anvim instead of leaving the side panels.
function M.setup_quit()
  api.nvim_create_autocmd('QuitPre', {
    group = api.nvim_create_augroup('anvim.layout', {}),
    callback = function()
      local current = api.nvim_get_current_win()
      if is_special(current) then
        return
      end
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= current and api.nvim_win_get_config(win).relative == '' and not is_special(win) then
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
