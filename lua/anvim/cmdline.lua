-- The : command line in a window over the code, as noice shows it in LazyVim,
-- so that it never looks like the prompt. ui2 draws the command line in a
-- float of its own at the bottom of the screen. While a : command line is
-- open, this moves that float after each of ui2's updates, which come before
-- ui2 flushes the redraw. The cursor and the completion menu go with it.
local M = {}

local api = vim.api

local WIDTH = 60

---@type table<string, any>? The float's options from before it moved.
local saved

local function set(win, name, value)
  api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

-- The upper part of the code window, or of the screen without one.
local function popup(win)
  local columns = vim.o.columns
  local width = math.min(WIDTH, columns - 4)
  local left, span = 0, columns
  local code = require("anvim.layout").wins.code
  if code and api.nvim_win_is_valid(code) then
    left, span = vim.fn.win_screenpos(code)[2] - 1, api.nvim_win_get_width(code)
  end
  local col = left + math.floor((span - width - 2) / 2)
  api.nvim_win_set_config(win, {
    relative = "editor",
    row = math.floor(vim.o.lines / 5),
    col = math.max(0, math.min(col, columns - width - 2)),
    width = width,
    border = "rounded",
    title = " Command line ",
    title_pos = "center",
  })
  if not saved then
    saved = { wrap = vim.wo[win].wrap, winhighlight = vim.wo[win].winhighlight }
    -- ui2 sets 'cmdheight' to the rows of the command line, which would move
    -- the windows. A long command scrolls instead.
    set(win, "wrap", false)
    set(win, "winhighlight", (saved.winhighlight:gsub("Normal:MsgArea", "Normal:NormalFloat")))
  end
end

-- Back to ui2's own place for it.
local function restore(win)
  if saved then
    api.nvim_win_set_config(
      win,
      { relative = "laststatus", row = 1, col = 0, width = 10000, border = "none", title = "" }
    )
    set(win, "wrap", saved.wrap)
    set(win, "winhighlight", saved.winhighlight)
    saved = nil
  end
end

---@param ui2 table The vim._core.ui2 module, enabled.
function M.setup(ui2)
  local cmd = ui2.cmd
  if not cmd then
    return
  end
  local show, hide = cmd.cmdline_show, cmd.cmdline_hide
  -- Whether the outer command line is a : one. A nested one, such as <C-r>=,
  -- stays where the outer one is.
  local colon = false
  cmd.cmdline_show = function(...)
    show(...)
    local firstc, level = select(3, ...), select(6, ...)
    if level == 1 then
      colon = firstc == ":"
    end
    if colon then
      popup(ui2.wins.cmd)
    end
  end
  cmd.cmdline_hide = function(...)
    hide(...)
    if cmd.level == 0 then
      colon = false
      restore(ui2.wins.cmd)
    end
  end
end

return M
