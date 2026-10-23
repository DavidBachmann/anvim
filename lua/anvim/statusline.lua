-- The global statusline. On the left: Vim's mode, or FOLLOW in follow mode,
-- the git branch, and the file with its diagnostics. On the right: whether
-- Claude works or waits, where Claude is when the footer has no room for it,
-- the git diff counts and the cursor's place. 'statusline' is
-- "%!v:lua.require'anvim.statusline'.render()", so Neovim runs render() each
-- time it draws the statusline.
local M = {}

local api = vim.api
local icons = require("anvim.base").icons

---@type string? The last error of render(), which draws an empty statusline instead.
M.error = nil

-- Vim's mode names, as lualine shows them.
-- stylua: ignore
local names = {
  n = "NORMAL", no = "O-PENDING", nov = "O-PENDING", noV = "O-PENDING", ["no\22"] = "O-PENDING",
  niI = "NORMAL", niR = "NORMAL", niV = "NORMAL", nt = "NORMAL", ntT = "NORMAL",
  v = "VISUAL", vs = "VISUAL", V = "V-LINE", Vs = "V-LINE", ["\22"] = "V-BLOCK", ["\22s"] = "V-BLOCK",
  s = "SELECT", S = "S-LINE", ["\19"] = "S-BLOCK",
  i = "INSERT", ic = "INSERT", ix = "INSERT",
  R = "REPLACE", Rc = "REPLACE", Rx = "REPLACE", Rv = "V-REPLACE", Rvc = "V-REPLACE", Rvx = "V-REPLACE",
  c = "COMMAND", cv = "EX", ce = "EX", r = "REPLACE", rm = "MORE", ["r?"] = "CONFIRM", ["!"] = "SHELL",
  t = "TERMINAL",
}

-- The color set of each mode name. Other names take Normal's.
-- stylua: ignore
local kinds = {
  VISUAL = "Visual", ["V-LINE"] = "Visual", ["V-BLOCK"] = "Visual",
  SELECT = "Visual", ["S-LINE"] = "Visual", ["S-BLOCK"] = "Visual",
  REPLACE = "Replace", ["V-REPLACE"] = "Replace", INSERT = "Insert",
  COMMAND = "Command", EX = "Command", MORE = "Command", CONFIRM = "Command", TERMINAL = "Terminal",
}
local themes = {
  Normal = "normal",
  Insert = "insert",
  Visual = "visual",
  Replace = "replace",
  Command = "command",
  Terminal = "terminal",
}

-- Windows without a file of their own show no path and no cursor place.
local no_file = { anvim_input = true, anvim_transcript = true, anvim_keys = true }

-- Powerline glyphs as UTF-8 bytes: the separators, the branch and the default file icon.
local sep = { left = "\238\130\176", right = "\238\130\178" }
local thin = { left = "\238\130\177", right = "\238\130\179" }

local diff_groups = {
  added = { "GitSignsAdd", "DiffAdded", "DiffAdd" },
  modified = { "GitSignsChange", "DiffChanged", "DiffChange" },
  removed = { "GitSignsDelete", "DiffRemoved", "DiffDelete" },
}

local function esc(text)
  return (text:gsub("%%", "%%%%"))
end

-- A space on each side. As in lualine, the first space takes the first color.
local function pad(text)
  return (text:gsub("^(%%#[^#]*#)", "%1 ", 1)) .. " "
end

---@type integer? The middle section's background.
local c_bg
---@type table<string, string> The groups that render() made since the last colorscheme, by source group.
local cache = {}
---@type table<string, string> The diff counts' source groups, by key.
local picked = {}

-- A group's foreground on the middle section's background, as
-- `AnvimStatusC<group>`. render() makes it on first use, because gitsigns and
-- mini.icons set their groups again after anvim's ColorScheme handler.
-- nocombine keeps the colorscheme's StatusLine style, such as reverse, out.
local function on_c(group)
  local name = cache[group]
  if not name then
    name = "AnvimStatusC" .. group
    local hl = api.nvim_get_hl(0, { name = group, link = false })
    api.nvim_set_hl(0, name, { fg = hl.fg or hl.sp, bg = c_bg, nocombine = true })
    cache[group] = name
  end
  return "%#" .. name .. "#"
end

-- The first group of the list that has a foreground.
local function first(list)
  for _, group in ipairs(list) do
    if api.nvim_get_hl(0, { name = group, link = false }).fg then
      return group
    end
  end
  return list[#list]
end

-- apple/orange/kiwi.lua -> a/o/kiwi.lua, until it fits, as lualine shortens.
local function shorten(path, max)
  local len = #path
  if len <= max then
    return path
  end
  local parts = vim.split(path, "/")
  for i = 1, #parts - 1 do
    if len <= max then
      break
    end
    local short = parts[i]:sub(1, vim.startswith(parts[i], ".") and 2 or 1)
    len = len - (#parts[i] - #short)
    parts[i] = short
  end
  return table.concat(parts, "/")
end

local function file_icon(buf, name)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  local icon, group
  if ok then
    icon, group = devicons.get_icon(vim.fs.basename(name))
    if not icon then
      icon, group = devicons.get_icon_by_filetype(vim.bo[buf].filetype)
    end
  end
  return icon or "\238\152\146", group
end

local function file(buf)
  local name = api.nvim_buf_get_name(buf)
  local preview = vim.b[buf].anvim_preview
  local context = package.loaded["anvim.context"]
  local path = preview and context and context.relpath(preview) or vim.fn.fnamemodify(name, ":~:.")
  if path == "" then
    path = "[No Name]"
  end
  local text = " " .. esc(shorten(path, vim.o.columns - 40)) .. (vim.bo[buf].modified and " [+] " or " ")
  if vim.bo[buf].filetype == "" then
    return text
  end
  local icon, group = file_icon(buf, preview or name)
  return (group and on_c(group) or "") .. " " .. icon .. " %#AnvimStatusC#" .. text
end

local function diagnostics(buf)
  local count = vim.diagnostic.count(buf)
  local parts = {}
  for severity, name in ipairs({ "Error", "Warn", "Info", "Hint" }) do
    local n = count[severity]
    if n and n > 0 then
      parts[#parts + 1] = on_c("Diagnostic" .. name) .. icons.diagnostics[name] .. n
    end
  end
  return #parts > 0 and pad(table.concat(parts, " ")) or nil
end

local function diff(buf)
  local status = vim.b[buf].gitsigns_status_dict
  if type(status) ~= "table" then
    return nil
  end
  local parts = {}
  for _, key in ipairs({ "added", "modified", "removed" }) do
    local n = status[key == "modified" and "changed" or key]
    if type(n) == "number" and n > 0 then
      picked[key] = picked[key] or first(diff_groups[key])
      parts[#parts + 1] = on_c(picked[key]) .. icons.git[key] .. n
    end
  end
  return #parts > 0 and pad(table.concat(parts, " ")) or nil
end

-- Where Claude needs the user, from any window. The activity line above the
-- prompt shows what Claude does, and it is always on screen.
local function claude(win)
  local input, permission = package.loaded["anvim.input"], package.loaded["anvim.permission"]
  local follow, layout = package.loaded["anvim.follow"], package.loaded["anvim.layout"]
  local parts = {}
  if permission and permission.waiting() and not (layout and win == layout.wins.input) then
    parts[#parts + 1] = on_c("AnvimClaude") .. " ⏺ Claude is waiting "
  end
  if follow and input and not input.follows() and follow.status() ~= "" then
    parts[#parts + 1] = on_c(follow.group()) .. " " .. esc(follow.status(true)) .. " "
  end
  return parts
end

-- With no row for the command line, the macro recording shows here.
local function recording()
  local reg = vim.fn.reg_recording()
  return reg ~= "" and on_c("Constant") .. " recording @" .. esc(reg) .. " " or nil
end

local function place(win)
  local line, last = api.nvim_win_get_cursor(win)[1], api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  local progress = line == 1 and "Top" or line == last and "Bot" or ("%2d%%%%"):format(math.floor(line / last * 100))
  return (" %s %3d:%-2d "):format(progress, line, vim.fn.charcol(".", win))
end

local function render()
  local win = vim.g.statusline_winid or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  local mode = api.nvim_get_mode().mode
  local name = names[mode] or mode
  local kind = kinds[name] or "Normal"
  local follow = package.loaded["anvim.follow"]
  local block, group = name, "AnvimStatus" .. kind
  if follow and follow.mode() == "follow" then
    block, group = "FOLLOW", "AnvimStatusFollow"
  end
  local branch, left, right
  if ft == "lazy" then
    local stats = require("lazy").stats()
    block, branch = "lazy 💤", ("loaded: %d/%d"):format(stats.loaded, stats.count)
    left, right = {}, {}
  else
    branch = vim.b[buf].gitsigns_head
    if type(branch) ~= "string" or branch == "" then
      local state = package.loaded["anvim.state"]
      branch = state and state.branch ~= "" and state.branch or nil
    end
    branch = branch and "\238\130\160 " .. esc(branch)
    left = {}
    if not no_file[ft] then
      left[1] = diagnostics(buf)
      left[#left + 1] = file(buf)
      if vim.b[buf].anvim_preview then
        left[#left + 1] = on_c("Comment") .. " (writing) "
      end
    end
    right = { recording() }
    vim.list_extend(right, claude(win))
    right[#right + 1] = diff(buf)
  end

  local follows = group == "AnvimStatusFollow"
  local out = { "%#", group, "# ", esc(block), " " }
  if branch then
    out[#out + 1] = ("%%#%s#%s%%#AnvimStatus%sB# %s %%#AnvimStatus%sBC#%s"):format(
      follows and "AnvimStatusFollow" .. kind .. "B" or group .. "AB",
      sep.left,
      kind,
      branch,
      kind,
      sep.left
    )
  else
    out[#out + 1] = "%#" .. (follows and "AnvimStatusFollowC" or group .. "AC") .. "#" .. sep.left
  end
  out[#out + 1] = "%#AnvimStatusC#"
  out[#out + 1] = table.concat(left, "%#AnvimStatusC#" .. thin.left)
  out[#out + 1] = "%#AnvimStatusC#%="
  out[#out + 1] = table.concat(right, "%#AnvimStatusC#" .. thin.right)
  if not no_file[ft] and ft ~= "lazy" then
    out[#out + 1] = ("%%#AnvimStatus%sBC#%s%%#AnvimStatus%sB#%s"):format(kind, sep.right, kind, place(win))
  end
  return table.concat(out)
end

function M.render()
  local ok, text = pcall(render)
  if ok then
    return text
  end
  if not M.error then
    vim.schedule(function()
      vim.notify("anvim's statusline failed: " .. text, vim.log.levels.ERROR)
    end)
  end
  M.error = text
  return ""
end

-- Marks the statusline for the next redraw, without drawing now. Setting the
-- option marks it, while :redrawstatus and nvim__redraw() draw at once, which
-- window events must not do.
function M.refresh()
  vim.go.statusline = vim.go.statusline
end

-- A window's 'winhighlight' remaps the groups that nvim_get_hl() reads while
-- that window is current. The prompt maps Normal, so read from a window
-- without remaps.
local function get_hl(name)
  local function get()
    local hl = api.nvim_get_hl(0, { name = name, link = false })
    if hl.reverse then
      hl.fg, hl.bg = hl.bg, hl.fg
    end
    return hl
  end
  if vim.wo.winhighlight == "" then
    return get()
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].winhighlight == "" then
      return api.nvim_win_call(win, get)
    end
  end
  return get()
end

local function color(names_, attr, fallback)
  for _, name in ipairs(names_) do
    local hl = get_hl(name)
    if hl[attr] then
      return hl[attr]
    end
  end
  return fallback
end

-- The brightness of a color, from 0 to 1, as lualine weighs it.
local function brightness(color_)
  local n = type(color_) == "string" and tonumber(color_:sub(2), 16) or color_
  if type(n) ~= "number" then
    return 0
  end
  return (bit.rshift(n, 16) * 2 + bit.band(bit.rshift(n, 8), 255) * 3 + bit.band(n, 255)) / 6 / 255
end

-- Of the candidates, the first that stands out from the background, else the
-- one that stands out most.
local function readable(bg, candidates)
  local best, most = nil, -1
  for i = 1, table.maxn(candidates) do
    local fg = candidates[i]
    local delta = fg and math.abs(brightness(fg) - brightness(bg)) or -1
    if delta >= 0.3 then
      return fg
    elseif delta > most then
      best, most = fg, delta
    end
  end
  return best
end

-- The theme that the colorscheme ships for lualine, such as tokyonight's.
-- Else one from its groups, with lualine's choice of groups: each mode's color
-- behind the mode, the editor's background behind the branch, and the
-- colorscheme's own StatusLine in the middle.
local function theme()
  local colors = vim.g.colors_name
  local path = colors and api.nvim_get_runtime_file(("lua/lualine/themes/%s.lua"):format(colors), false)[1]
  local ok, shipped = pcall(function()
    return path and dofile(path)
  end)
  if ok and type(shipped) == "table" and type(shipped.normal) == "table" then
    return shipped
  end
  local normal, status = get_hl("Normal"), get_hl("StatusLine")
  local back, fore = normal.bg or 0, normal.fg or 0xffffff
  -- A shade lighter on a dark background, darker on a light one.
  local k = brightness(back) > 0.5 and 0.9 or 1.1
  local function shade(n)
    local r, g, b = bit.rshift(n, 16), bit.band(bit.rshift(n, 8), 255), bit.band(n, 255)
    return math.min(255, math.floor(r * k)) * 65536
      + math.min(255, math.floor(g * k)) * 256
      + math.min(255, math.floor(b * k))
  end
  local made = {}
  for mode, list in pairs({
    normal = { { "PmenuSel", "PmenuThumb", "TabLineSel" }, "bg" },
    insert = { { "String", "MoreMsg" }, "fg" },
    replace = { { "Number", "Type" }, "fg" },
    visual = { { "Special", "Boolean", "Constant" }, "fg" },
    command = { { "Identifier" }, "fg" },
  }) do
    local c = color(list[1], list[2], fore)
    made[mode] = {
      a = { bg = c, fg = readable(c, { back, fore }), gui = "bold" },
      b = { bg = shade(back), fg = readable(shade(back), { c, fore }) },
      c = { bg = status.bg or back, fg = status.fg or fore },
    }
  end
  made.terminal = made.command
  return made
end

---@type table<string, vim.api.keyset.get_highlight> The groups as the statusline set them last.
local derived = {}

-- A group that someone else set stays. tokyonight runs no :hi clear on its
-- first load, so the check compares with what the statusline set before.
-- Neovim combines statusline groups with StatusLine, which can be bold and
-- reverse, as in retrobox. nocombine keeps that out, as lualine does.
local function set(name, spec)
  local now = api.nvim_get_hl(0, { name = name })
  if next(now) == nil or vim.deep_equal(now, derived[name]) then
    spec.nocombine = true
    api.nvim_set_hl(0, name, spec)
    derived[name] = api.nvim_get_hl(0, { name = name })
  end
end

-- Sets the statusline's groups from the colorscheme. anvim calls it after its
-- own groups, such as AnvimClaude, on every ColorScheme.
function M.highlights()
  local t = theme()
  local function part(mode, key)
    local p = (t[mode] or {})[key] or t.normal[key] or {}
    local bold = type(p.gui) == "string" and p.gui:find("bold") ~= nil
    return { fg = p.fg, bg = p.bg, bold = bold }
  end
  local c = part("normal", "c")
  local fallback = get_hl("StatusLine")
  c.fg, c.bg = c.fg or fallback.fg, c.bg or fallback.bg
  set("AnvimStatusC", { fg = c.fg, bg = c.bg })
  c_bg, cache, picked = c.bg, {}, {}
  local orange = get_hl("AnvimClaude").fg
  local normal = get_hl("Normal")
  local follow = readable(orange, { part("normal", "a").fg, normal.bg, normal.fg })
  set("AnvimStatusFollow", { fg = follow, bg = orange, bold = true })
  set("AnvimStatusFollowC", { fg = orange, bg = c.bg })
  for kind, mode in pairs(themes) do
    local a, b = part(mode, "a"), part(mode, "b")
    local name = "AnvimStatus" .. kind
    set(name, a)
    set(name .. "B", { fg = b.fg, bg = b.bg })
    set(name .. "AB", { fg = a.bg, bg = b.bg })
    set(name .. "AC", { fg = a.bg, bg = c.bg })
    set(name .. "BC", { fg = b.bg, bg = c.bg })
    set("AnvimStatusFollow" .. kind .. "B", { fg = orange, bg = b.bg })
  end
end

function M.setup()
  local group = api.nvim_create_augroup("anvim.statusline", { clear = true })
  -- Neovim redraws the statusline on its own after a window change, a cursor
  -- move and most changes of Vim's mode. <C-v> after a pause drew no V-BLOCK
  -- without ModeChanged. The other events change what it shows.
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "AnvimStatus",
      "AnvimMode",
      "AnvimAgents",
      "AnvimFiles",
      "AnvimPreviewStart",
      "AnvimPreviewEnd",
      "GitSignsUpdate",
    },
    callback = M.refresh,
  })
  api.nvim_create_autocmd(
    { "DiagnosticChanged", "BufWinEnter", "ModeChanged", "RecordingEnter", "RecordingLeave" },
    { group = group, callback = M.refresh }
  )
end

return M
