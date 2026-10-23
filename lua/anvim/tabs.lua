-- The code window's winbar: a tab for each of the last files of the agent
-- that follow mode follows. The file that the code window shows is the
-- current tab. A file that is not in the bar shows at the left, apart from
-- the tabs.
local agents = require("anvim.agents")
local context = require("anvim.context")
local files = require("anvim.files")

local M = {}

local api = vim.api

-- The default icon, as the statusline's.
local DEFAULT_ICON = "\238\152\146"
-- The edit mark, as in the explorer, and the counts of the tabs that a
-- narrow window drops on each side, as UTF-8 bytes.
local MARK = "\226\128\162"
local BEFORE = "\226\128\185%d"
local AFTER = "%d\226\128\186"

---@type table<string, { icon: string, group: string? }> By file name.
local icons = {}
---@type table<string, string> The groups on the current tab's background, by source group.
local on_current = {}
---@type string[] The paths of the tabs that the bar drew last, by click id.
local targets = {}

local function esc(text)
  return (text:gsub("%%", "%%%%"))
end

local function icon(name)
  local cached = icons[name]
  if not cached then
    local ok, devicons = pcall(require, "nvim-web-devicons")
    local i, group
    if ok then
      i, group = devicons.get_icon(name)
    end
    cached = { icon = i or DEFAULT_ICON, group = group }
    icons[name] = cached
  end
  return cached.icon, cached.group
end

-- A group's foreground on the current tab's background. Groups in a winbar
-- combine with WinBar only, so the tab's background must be in each group.
-- Made on first use, because mini.icons sets its groups again after
-- anvim's ColorScheme handler.
local function current(group)
  if not group then
    return "AnvimTabCurrent"
  end
  local name = on_current[group]
  if not name then
    name = "AnvimTabCurrent" .. group:gsub("[^%w_]", "")
    local hl = api.nvim_get_hl(0, { name = group, link = false })
    local tab = api.nvim_get_hl(0, { name = "AnvimTabCurrent", link = false })
    api.nvim_set_hl(0, name, { fg = hl.fg, bg = tab.bg, bold = tab.bold })
    on_current[group] = name
  end
  return name
end

-- The key of the agent that follow mode follows, and its edit mark's group.
local function agent()
  local focused = require("anvim.follow").focused()
  return focused and focused.id or "", focused and agents.group(focused.slot) or agents.group(0), focused
end

---@class anvim.Tab
---@field path string The real path.
---@field name string
---@field current boolean
---@field edited boolean
---@field writing boolean
---@field click integer? The click id. The file at the left has none.

-- The parent folder tells apart the names that clash, as in bufferline.
---@param tabs anvim.Tab[]
local function names(tabs)
  local count = {}
  for _, tab in ipairs(tabs) do
    count[tab.name] = (count[tab.name] or 0) + 1
  end
  for _, tab in ipairs(tabs) do
    if count[tab.name] > 1 then
      tab.name = vim.fs.basename(vim.fs.dirname(tab.path)) .. "/" .. tab.name
    end
  end
end

---@param tab anvim.Tab
---@param mark string The edit mark's group.
---@return string text, integer width
local function draw(tab, mark)
  local i, group = icon(vim.fs.basename(tab.path))
  local base = tab.current and "%#AnvimTabCurrent#" or "%*"
  local function hl(g)
    return "%#" .. (tab.current and current(g) or g) .. "#"
  end
  local parts = { base, " ", group and hl(group) or "", i, base, " ", esc(tab.name) }
  local plain = " " .. i .. " " .. tab.name
  if tab.edited then
    parts[#parts + 1] = " " .. hl(mark) .. MARK .. base
    plain = plain .. " " .. MARK
  end
  if tab.writing then
    parts[#parts + 1] = hl("AnvimWinBarWriting") .. " (writing)" .. base
    plain = plain .. " (writing)"
  end
  parts[#parts + 1] = " "
  local text = table.concat(parts)
  if tab.click then
    text = ("%%%d@v:lua.require'anvim.tabs'.click@%s%%T"):format(tab.click, text)
  end
  return text, api.nvim_strwidth(plain) + 1
end

-- The file that the code window shows, by its real path.
---@return string?
local function shown(buf)
  local file = context.file(buf)
  return file and files.real(file)
end

---@param win integer The code window.
function M.render(win)
  local buf = api.nvim_win_get_buf(win)
  local now = shown(buf)
  local key, mark, focused = agent()
  local tabs = {} ---@type anvim.Tab[]
  local outside = now ~= nil
  targets = {}
  for _, file in ipairs(files.bar(key, now)) do
    targets[#targets + 1] = file.path
    tabs[#tabs + 1] = {
      path = file.path,
      name = vim.fs.basename(file.path),
      current = file.path == now,
      edited = file.edited,
      writing = file.path == now and vim.b[buf].anvim_preview ~= nil,
      click = #targets,
    }
    outside = outside and file.path ~= now
  end
  local left ---@type anvim.Tab?
  if outside and now then
    local known = files.get(key, now)
    left = {
      path = now,
      name = vim.fs.basename(now),
      current = true,
      edited = known ~= nil and known.edited,
      writing = vim.b[buf].anvim_preview ~= nil,
    }
  end
  names(left and vim.list_extend({ left }, tabs) or tabs)

  local head, used = { "%*" }, 0
  if focused then
    local name = agents.name(focused)
    head[#head + 1] = ("%%#%s# %s %%*"):format(agents.group(focused.slot), esc(name))
    used = used + api.nvim_strwidth(name) + 2
  end
  if left then
    local text, width = draw(left, mark)
    head[#head + 1] = text .. "%* "
    used = used + width + 1
  end
  local drawn = {}
  for i, tab in ipairs(tabs) do
    local text, width = draw(tab, mark)
    drawn[i] = { text = text, width = width, current = tab.current }
    used = used + width
  end
  -- A narrow window drops tabs from the left, and then from the right of
  -- the current one, which never drops.
  local room, cur = api.nvim_win_get_width(win), nil
  for i, d in ipairs(drawn) do
    cur = d.current and i or cur
  end
  local first, last = 1, #drawn
  local function width()
    local before = first > 1 and api.nvim_strwidth(BEFORE:format(first - 1)) or 0
    return used + before + (last < #drawn and api.nvim_strwidth(AFTER:format(#drawn - last)) or 0)
  end
  while width() > room and first <= last and not (first == cur and last == cur) do
    if first ~= cur then
      used = used - drawn[first].width
      first = first + 1
    else
      used = used - drawn[last].width
      last = last - 1
    end
  end
  if first > 1 then
    head[#head + 1] = BEFORE:format(first - 1)
  end
  for i = first, last do
    head[#head + 1] = drawn[i].text
  end
  if last < #drawn then
    head[#head + 1] = AFTER:format(#drawn - last)
  end
  head[#head + 1] = "%*"
  return table.concat(head)
end

-- Opens a tab's file in the code window, where the code window showed it
-- last, and puts the cursor there. A file that it never showed opens at the
-- newest place in it from Claude's trail, else at the top.
---@param path string
function M.open(path)
  local follow = require("anvim.follow")
  local layout = require("anvim.layout")
  local win = layout.code_win()
  -- A Write preview's file does not exist yet.
  if shown(api.nvim_win_get_buf(win)) == path or not vim.uv.fs_stat(path) then
    api.nvim_set_current_win(win)
    return
  end
  local buf = follow.load(path)
  local line
  if vim.fn.getbufinfo(buf)[1].lastused == 0 then
    local place = require("anvim.trail").newest(function(p)
      return files.real(p) == path
    end)
    line = place and place.first or 1
  end
  follow.show(buf, line)
  api.nvim_set_current_win(win)
end

-- A left click on a tab opens its file.
function M.click(id, _, button)
  local path = targets[id]
  if button == "l" and path then
    M.open(path)
  end
end

-- The previous or next tab, around the ends. From the file at the left,
-- the next tab is the first and the previous one the last. Other windows
-- keep :bprevious and :bnext.
---@param delta 1|-1
function M.step(delta)
  local layout = require("anvim.layout")
  local win = api.nvim_get_current_win()
  if win ~= layout.wins.code then
    vim.cmd(delta > 0 and "bnext" or "bprevious")
    return
  end
  local now = shown(api.nvim_win_get_buf(win))
  local bar = files.bar((agent()), now)
  if #bar == 0 then
    return
  end
  local at
  for i, file in ipairs(bar) do
    if file.path == now then
      at = i
    end
  end
  local target = at and bar[(at - 1 + delta) % #bar + 1] or bar[delta > 0 and 1 or #bar]
  M.open(target.path)
end

-- The tabs' keys in a file buffer.
function M.map(buf)
  local keys = require("anvim.keys")
  keys.set("code", "n", "<S-h>", function()
    M.step(-1)
  end, { buffer = buf })
  keys.set("code", "n", "<S-l>", function()
    M.step(1)
  end, { buffer = buf })
end

function M.unmap(buf)
  pcall(vim.keymap.del, "n", "<S-h>", { buffer = buf })
  pcall(vim.keymap.del, "n", "<S-l>", { buffer = buf })
end

function M.setup()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("anvim.tabs", {}),
    callback = function()
      on_current = {}
    end,
  })
end

return M
