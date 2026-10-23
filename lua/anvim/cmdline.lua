-- The command line in a window over the code, as noice shows it in LazyVim,
-- so that it never looks like the prompt. ui2 draws the command line in a
-- float of its own at the bottom of the screen. While a command line is
-- open, this moves that float after each of ui2's updates, which come before
-- ui2 flushes the redraw. The cursor and the completion menu go with it.
local M = {}

local api = vim.api

local WIDTH = 60

local titles = { [":"] = " Command line ", ["/"] = " Search ", ["?"] = " Search " }

---@type table<string, any>? The float's options from before it moved.
local saved

local function set(win, name, value)
  api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

-- The upper part of the code window, or of the screen without one.
local function popup(win, firstc)
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
    title = titles[firstc] or " Input ",
    title_pos = "center",
  })
  if not saved then
    saved = { wrap = vim.wo[win].wrap, winhighlight = vim.wo[win].winhighlight }
    -- ui2 sets 'cmdheight' to the rows of the command line. A long command
    -- scrolls instead.
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
  -- The outer command line's first character. A nested one, such as <C-r>=,
  -- stays where the outer one is.
  local firstc
  cmd.cmdline_show = function(...)
    show(...)
    local level = select(6, ...)
    if level == 1 then
      firstc = select(3, ...)
    end
    popup(ui2.wins.cmd, firstc)
    -- ui2 gives the command line a row at the bottom, which would move the
    -- windows. The popup needs none. The rows go back to the bottom windows,
    -- such as the tool pane, and not to the windows that gave them.
    if vim.o.cmdheight ~= ui2.cmdheight then
      vim._with({ noautocmd = true, o = { splitkeep = "screen" } }, function()
        vim.o.cmdheight = ui2.cmdheight
      end)
      require("anvim.layout").refit_pane()
    end
  end
  cmd.cmdline_hide = function(...)
    hide(...)
    if cmd.level == 0 then
      firstc = nil
      restore(ui2.wins.cmd)
    end
  end
end

return M
