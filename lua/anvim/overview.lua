-- The Agent Overview: a snacks picker whose list holds a tab for Claude and
-- one for each agent, in its color. The preview shows the selected agent's
-- conversation as it grows: the transcript for Claude, its log for a
-- subagent. <CR> closes the window and follows the agent.
local agentlog = require("anvim.agentlog")
local agents = require("anvim.agents")
local follow = require("anvim.follow")
local keys = require("anvim.keys")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api

M.source = "anvim_overview"
-- Below this many columns, the tabs go on top of the conversation.
M.wide_columns = 120
-- The tab rows of the narrow layout, at most.
M.narrow_rows = 6
-- The columns of the wide layout's list, at least.
M.list_min = 40

---@class anvim.OverviewItem: snacks.picker.Item
---@field agent_id string? nil for Claude.

-- The window options of the conversation, as the Claude column shows it.
local WO = {
  wrap = true,
  linebreak = true,
  breakindent = true,
  breakindentopt = "list:-1",
  conceallevel = 2,
  concealcursor = "nvc",
  number = false,
  relativenumber = false,
}

local ENDED = { completed = "done", failed = "failed", stopped = "stopped" }

---@type snacks.Picker?
local picker
-- The agents of the tabs, in order, at the last find.
local order
-- The conversation that the preview shows, and its view before a find.
---@type { key: string, buf: integer, view: vim.fn.winsaveview.ret?, at_end: boolean? }?
local shown
local scheduled = false

local function key(lhs, action)
  return { action, mode = "n", desc = keys.desc("overview", "n", lhs) }
end

-- The keys of the tab list, on top of snacks' own.
M.keys = {
  ["<CR>"] = key("<CR>", "confirm"),
  ["<2-LeftMouse>"] = key("<2-LeftMouse>", "confirm"),
  ["<Tab>"] = key("<Tab>", "list_down"),
  ["<S-Tab>"] = key("<S-Tab>", "list_up"),
  -- These focus the input, and the window has none.
  ["/"] = false,
  ["i"] = false,
  -- These pick a window to jump into, or fill the quickfix list with the tabs.
  ["<S-CR>"] = false,
  ["<c-q>"] = false,
  -- These move the picker to a sidebar, which resizes anvim's columns. The
  -- global map keeps the float in its place instead.
  ["<c-w>H"] = false,
  ["<c-w>J"] = false,
  ["<c-w>K"] = false,
  ["<c-w>L"] = false,
}
for slot = 0, agents.slots do
  M.keys[tostring(slot)] = key(tostring(slot), "anvim_slot" .. slot)
end

---@return snacks.Picker?
function M.get()
  local p = picker
  return p and not p.closed and p or nil
end

function M.close()
  local p = M.get()
  if p then
    p:close()
  end
end

-- Whether `win` is one of the Overview's windows.
function M.owns(win)
  local p = M.get()
  if not p then
    return false
  end
  for _, w in pairs(p.layout.wins or {}) do
    if w.win == win then
      return true
    end
  end
  return p.layout.root.win == win
end

-- Claude, the running agents by slot, the agents without a slot, then the
-- agents that ended since the last prompt, newest first.
---@return anvim.OverviewItem[]
function M.items()
  local list = { { text = "Claude" } }
  for _, agent in ipairs(vim.list_extend(agents.running(), agents.ended())) do
    list[#list + 1] = { text = agents.name(agent), agent_id = agent.id }
  end
  return list
end

local function claude_status()
  return state.waiting and "waiting for you" or state.busy and "working" or "idle"
end

-- An agent's name, color, bullet color and status.
---@param id string?
---@return string name, string group, string bullet, string status
local function describe(id)
  local agent = id and agents.get(id)
  if not id then
    local group = agents.group(0)
    return "Claude", group, group, claude_status()
  elseif not agent then
    return "Agent", "Comment", "Comment", "gone"
  elseif agent.status == "running" then
    local group = agents.group(agent.slot)
    local parts = {}
    parts[#parts + 1] = not agent.slot and "no slot" or nil
    parts[#parts + 1] = agent.background and "bg" or nil
    parts[#parts + 1] = agents.settings(agent)
    parts[#parts + 1] = agent.description ~= "" and agent.description or nil
    parts[#parts + 1] = agent.activity or "working"
    return agents.name(agent), group, group, table.concat(parts, " · ")
  end
  -- The slot may belong to another agent now, so the name has no number.
  local status = ENDED[agent.status] or agent.status
  local settings = agents.settings(agent)
  if settings then
    status = status .. " · " .. settings
  end
  if agent.description ~= "" then
    status = status .. " · " .. agent.description
  end
  return agents.name(agent), "Comment", agent.status == "completed" and "AnvimToolOk" or "AnvimToolError", status
end

-- How full the context window of agent `id` is, or Claude's for nil.
---@param id string?
---@return integer?
local function percent(id)
  local agent = id and agents.get(id)
  local context = (agent and agent.context) or (not id and state.context) or nil
  return context and tonumber(context.percent)
end

-- The percents line up. Without any, the rows have no column for them.
local function percent_width()
  for _, item in ipairs(M.items()) do
    if percent(item.agent_id) then
      return 6
    end
  end
  return 0
end

-- The names line up, with at least two spaces after the longest.
local function name_width()
  local width = 10
  for _, item in ipairs(M.items()) do
    width = math.max(width, api.nvim_strwidth(item.text))
  end
  return width + 2
end

---@param item anvim.OverviewItem
function M.format(item)
  local name, group, bullet, status = describe(item.agent_id)
  local pad = math.max(2, name_width() - api.nvim_strwidth(name))
  local pct = percent(item.agent_id)
  return {
    { (item.agent_id == follow.focus and "◉" or "⏺") .. " ", bullet },
    { name, group },
    { (" "):rep(pad) },
    { pct and ("%3d%%  "):format(pct) or (" "):rep(percent_width()), "Comment" },
    { status, "Comment" },
  }
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- The preview's title: the agent, its task, its state and its totals.
---@param id string?
function M.title(id)
  local agent = id and agents.get(id)
  if not id then
    return "Claude · " .. claude_status()
  elseif not agent then
    return "Agent"
  end
  local parts = { agents.name(agent) }
  parts[#parts + 1] = agent.description ~= "" and agent.description or nil
  parts[#parts + 1] = agents.settings(agent)
  parts[#parts + 1] = agent.status == "running" and "running" or ENDED[agent.status]
  local usage = agent.status ~= "running" and agent.usage or {}
  parts[#parts + 1] = plural(usage.tool_uses or agent.tools, "tool use")
  local tokens = usage.tokens or agent.tokens
  parts[#parts + 1] = tokens and transcript.tokens(tokens) .. " tokens" or nil
  parts[#parts + 1] = usage.duration_ms and transcript.duration(usage.duration_ms) or nil
  return table.concat(parts, " · ")
end

local function view_key(id)
  return id or ""
end

local function at_end(win, buf)
  return vim.fn.line("w$", win) >= api.nvim_buf_line_count(buf)
end

---@param ctx snacks.picker.preview.ctx
function M.preview(ctx)
  local id = ctx.item.agent_id
  local buf = id and agentlog.buf(id) or not id and transcript.buf()
  ctx.preview:set_title(M.title(id))
  if not buf then
    ctx.preview:reset()
    ctx.preview:set_lines({ "anvim keeps no log of this agent." })
    shown = nil
    return
  end
  -- snacks maps CursorLine to Visual in its preview, and the prompt lines of
  -- a conversation link to CursorLine.
  local winhl = (ctx.preview.winhl or ""):gsub("CursorLine:[^,]*,?", ""):gsub(",$", "")
  ctx.item.wo = vim.tbl_extend("force", WO, { winhighlight = winhl })
  ctx.preview:set_buf(buf)
  -- snacks would reset the options of the next split that shows the buffer,
  -- such as the transcript window that a layout repair makes.
  vim.b[buf].snacks_previewed = nil
  local win, last = ctx.win, api.nvim_buf_line_count(buf)
  local same = shown and shown.key == view_key(id) and shown.buf == buf
  if same and shown.view and not shown.at_end then
    api.nvim_win_call(win, function()
      vim.fn.winrestview(shown.view)
    end)
  elseif not (same and not shown.view) then
    -- A new tab starts at the end, and a view at the end stays there.
    api.nvim_win_set_cursor(win, { last, 0 })
  end
  shown = { key = view_key(id), buf = buf }
end

-- Moves the list's cursor to the tab of agent `id`, or Claude's for nil.
---@param p snacks.Picker
---@param id string?
local function select_tab(p, id)
  for i, item in ipairs(p:items()) do
    if item.agent_id == id then
      p.list:view(i)
      return true
    end
  end
  return false
end

---@param p snacks.Picker
function M.select_slot(p, slot)
  local agent = slot > 0 and agents.in_slot(slot)
  if slot > 0 and not agent then
    follow.empty_slot(slot)
    return
  end
  select_tab(p, agent and agent.id or nil)
end

---@param p snacks.Picker
---@param item anvim.OverviewItem?
function M.confirm(p, item)
  if item then
    follow.follow(item.agent_id)
  else
    p:close()
  end
end

local function hint()
  local chunks = { { " ", "FloatBorder" } }
  for _, part in ipairs({ { "⏎", "follow" }, { "⇥", "next" }, { "0-4", "agent" }, { "q", "close" } }) do
    vim.list_extend(chunks, { { part[1], "SnacksPickerToggle" }, { " " .. part[2] .. "  ", "FloatFooter" } })
  end
  chunks[#chunks][1] = chunks[#chunks][1]:gsub("  $", " ")
  return chunks
end

-- The wide float's width, as a part of the editor's.
local FLOAT_WIDTH = 0.8

-- The wide list fits its longest row, from M.list_min columns up to half the
-- float. A longer row gets cut.
local function list_width()
  local widest = 0
  for _, item in ipairs(M.items()) do
    local width = 0
    for _, chunk in ipairs(M.format(item)) do
      width = width + api.nvim_strwidth(chunk[1])
    end
    widest = math.max(widest, width)
  end
  local half = math.floor(math.floor(vim.o.columns * FLOAT_WIDTH) / 2)
  -- One space on each side of the row.
  return math.max(M.list_min, math.min(widest + 2, half))
end

-- Wide: the tabs left of the conversation. Narrow: the tabs on top, one row
-- each, up to M.narrow_rows. snacks asks again on VimResized.
function M.layout()
  local box = {
    border = "rounded",
    title = "{title}",
    title_pos = "center",
    footer = hint(),
    footer_pos = "center",
    -- As in the prompt editor: a backdrop would blank the explorer's list.
    backdrop = false,
  }
  -- Neovim wants a corner between two edges, so neither window has both a
  -- top and a side border.
  if vim.o.columns >= M.wide_columns then
    box = vim.tbl_extend("force", box, {
      box = "horizontal",
      width = FLOAT_WIDTH,
      height = 0.8,
      { win = "list", width = list_width(), border = "right" },
      { win = "preview", border = "top", title = "{preview}", title_pos = "left" },
    })
  else
    box = vim.tbl_extend("force", box, {
      box = "vertical",
      width = 0.95,
      height = 0.9,
      { win = "list", height = math.min(#M.items(), M.narrow_rows), border = "none" },
      { win = "preview", border = "top", title = "{preview}", title_pos = "left" },
    })
  end
  return { cycle = true, layout = box }
end

local function ids(items)
  return table.concat(
    vim.tbl_map(function(item)
      return item.agent_id or ""
    end, items),
    ","
  )
end

-- The narrow list's rows follow the tab count, and the wide list's width
-- follows its rows. While the window is open, the wide list only grows, so
-- that it keeps still as an agent's activity changes. It resizes in place:
-- set_layout() would close and open the windows, and flush frames with a
-- blank row and title. `grow` limits it to a growth or a shrink.
---@param p snacks.Picker
---@param grow boolean
local function fit(p, grow)
  local box = p.layout.opts and p.layout.opts.layout
  local wide = vim.o.columns >= M.wide_columns
  if box and box.box ~= (wide and "horizontal" or "vertical") then
    return
  end
  local dim = wide and "width" or "height"
  local size = wide and list_width() or math.min(#M.items(), M.narrow_rows)
  local list = box and box[1] and box[1].win == "list" and box[1]
  local now = list and list[dim]
  if now == size or (now and (size > now) ~= grow) or (wide and not (grow and list)) then
    return
  end
  if not (list and p.list.state and p.layout.opts.on_update) then
    -- Parts of snacks that this relies on are gone: flicker, but no error.
    p:set_layout(M.layout())
    p:update_titles()
    return
  end
  list[dim] = size
  -- The list's render flushes a frame, and it cuts each row at the window's
  -- width. So a list that grows rows renders them before the windows move,
  -- and a list that shrinks or widens renders after. Without it, the list
  -- would learn its height only on WinResized. snacks' own on_update would
  -- put a scratch buffer in the preview first.
  local before = grow and not wide
  if not wide then
    p.list.state.height = size
  end
  if before then
    p.list:update({ force = true })
  end
  local on_update = p.layout.opts.on_update
  p.layout.opts.on_update = nil
  p.layout:update()
  p.layout.opts.on_update = on_update
  -- The update gives each window its own options again, which drops the
  -- preview's 'wrap' and highlights from M.preview().
  local item = p:current()
  if item and item.wo and p.preview.win:valid() then
    Snacks.util.wo(p.preview.win.win, item.wo)
  end
  if not before then
    p.list:update({ force = true })
  end
  p:update_titles()
end

-- Tabs that came or went run a find, which would put the cursor on the
-- first row, so the list keeps the selected agent's row as its target.
-- Other changes redraw the rows and the preview's title.
local function refresh()
  scheduled = false
  local p = M.get()
  if not (p and p.list and p.preview) then
    return
  end
  local current = p:current()
  local items = M.items()
  if ids(items) ~= order then
    order = ids(items)
    local win = p.preview.win.win
    if shown and win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == shown.buf then
      shown.view = api.nvim_win_call(win, vim.fn.winsaveview)
      shown.at_end = at_end(win, shown.buf)
    end
    local want = current and current.agent_id
    local target = 1
    for i, item in ipairs(items) do
      target = item.agent_id == want and i or target
    end
    -- A shrink before the find, so no frame shows the old rows' blanks, and
    -- a wider list, so that no frame cuts a new row.
    fit(p, false)
    if vim.o.columns >= M.wide_columns then
      fit(p, true)
    end
    -- After the shrink: a render while no find runs drops the target.
    p.list:set_target(target, nil, { force = true })
    p:find({
      refresh = true,
      on_done = function()
        fit(p, true)
        if not select_tab(p, want) then
          select_tab(p, nil)
        end
      end,
    })
  else
    -- An agent's new activity can make its row longer.
    fit(p, true)
    p.list:update({ force = true })
  end
  if current then
    p.preview:set_title(M.title(current.agent_id))
    p:update_titles()
  end
end

local function schedule()
  if M.get() and not scheduled then
    scheduled = true
    vim.schedule(refresh)
  end
end

-- Opens the Overview, or closes it when it is open.
function M.open()
  if M.get() then
    M.close()
    return
  end
  local actions = {}
  for slot = 0, agents.slots do
    actions["anvim_slot" .. slot] = function(p)
      M.select_slot(p, slot)
    end
  end
  order, shown = ids(M.items()), nil
  picker = Snacks.picker.pick({
    source = M.source,
    title = "Agent Overview",
    finder = M.items,
    format = M.format,
    preview = M.preview,
    confirm = M.confirm,
    actions = actions,
    focus = "list",
    -- The cursor goes back where it was, such as the prompt, which is no file.
    main = { current = true },
    sort = { fields = { "idx" } },
    layout = M.layout,
    -- With the explorer open, a resize enters a split for a moment, and
    -- snacks would close the picker. The WinEnter check below closes it.
    auto_close = false,
    win = {
      list = { keys = M.keys },
      -- A log that no window has shown takes the float's own values, which
      -- it copied from the window it opened from, such as the prompt's
      -- 'statuscolumn'.
      preview = { minimal = true },
    },
    on_close = function(p)
      if picker == p then
        picker, shown = nil, nil
      end
    end,
  })
end

function M.attach(sidecar)
  sidecar.on("agent_progress", schedule)
  sidecar.on("agent_context", schedule)
  -- A late end, after a turn's end stopped the agent, fires no AnvimAgents.
  sidecar.on("agent_end", schedule)
  sidecar.on("tool_use", function(ev)
    if ev.agent_id or ev.parent_id then
      schedule()
    end
  end)
  local group = api.nvim_create_augroup("anvim.overview", {})
  api.nvim_create_autocmd("User", { group = group, pattern = { "AnvimAgents", "AnvimStatus" }, callback = schedule })
  -- A click or a window key elsewhere closes the window. By the time the
  -- check runs, a split that a resize entered inside nvim_win_call() has
  -- given the cursor back. Floats on top, such as the key view, keep it. The
  -- explorer's list is a float on its split. The compose window under the
  -- Overview is a float too, which <C-w>p can enter.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if not M.get() then
        return
      end
      vim.schedule(function()
        local win = api.nvim_get_current_win()
        local elsewhere = not follow.on_top(win) or win == require("anvim.compose").win()
        if M.get() and not M.owns(win) and elsewhere then
          M.close()
        end
      end)
    end,
  })
  keys.set("claude", "n", "<leader>ca", M.open)
end

return M
