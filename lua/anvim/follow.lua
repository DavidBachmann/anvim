-- Follow mode: while the cursor is in the prompt, the code window shows where
-- Claude reads and writes. Elsewhere the user is in control, and the
-- statusline says where Claude is. A pinned selection pauses it, so the code
-- window keeps what the user points at until the next prompt. Follow mode
-- follows one agent: the main agent, or the subagent that the user focused.
local agents = require("anvim.agents")
local input = require("anvim.input")
local layout = require("anvim.layout")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.follow")

---@class anvim.Place
---@field path string
---@field line integer
---@field buf integer? A buffer to show instead of the file, such as a Write preview.
---@field behind integer Moves of its agent that the code window did not show.

-- Each agent's place, by agent_id. The main agent's has the key "".
---@type table<string, anvim.Place>
local places = {}
-- The subagent Writes of files that do not exist yet, by tool id.
---@type table<string, { agent: string, path: string }>
local writes = {}

---@type string? The agent_id of the agent that follow mode follows. nil is the main agent.
M.focus = nil
-- The focused agent's name, for the notice after its slot is gone.
local focus_name

-- The compose window is the prompt too.
function M.enabled()
  local win = api.nvim_get_current_win()
  return layout.wins.input ~= nil and (win == layout.wins.input or win == require("anvim.compose").win())
end

function M.paused()
  return require("anvim.context").selection() ~= nil
end

-- Whether the focused agent's moves move the code window.
function M.following()
  return M.enabled() and not M.paused()
end

-- Whether the moves of agent `id`, or of the main agent for nil, move the code window.
---@param id string?
function M.shows(id)
  return id == M.focus and M.following()
end

-- The focused agent's place.
---@return anvim.Place?
function M.place()
  return places[M.focus or ""]
end

-- The focused subagent, while it runs. nil for the main agent.
---@return anvim.Agent?
function M.focused()
  local agent = M.focus and agents.get(M.focus)
  return agent and agent.status == "running" and agent or nil
end

-- The focused agent's color.
---@return string group
function M.group()
  local agent = M.focused()
  if agent then
    return agents.group(agent.slot)
  end
  return agents.group(0)
end

---@return integer buf
function M.load(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

local function reveal_in_tree(path)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker and snacks.picker.get({ source = "explorer" })[1] then
    pcall(snacks.explorer.reveal, { file = path })
  end
end

-- Shows buf in the code window with the cursor at line (1-based) and col (0-based).
function M.show(buf, line, col)
  local win = layout.code_win()
  if api.nvim_win_get_buf(win) ~= buf then
    vim.bo[buf].buflisted = vim.bo[buf].buftype == ""
    api.nvim_win_set_buf(win, buf)
    local name = vim.b[buf].anvim_preview or api.nvim_buf_get_name(buf)
    if name ~= "" then
      reveal_in_tree(name)
    end
  end
  line = math.max(1, math.min(line, api.nvim_buf_line_count(buf)))
  api.nvim_win_set_cursor(win, { line, col or 0 })
end

-- Records an agent's place, and moves the code window there when following that agent.
---@param buf integer? A buffer to show instead of the file itself, such as a Write preview.
---@param id string? The agent's agent_id. nil is the main agent.
function M.track(path, line, buf, id)
  local old = places[id or ""]
  local place = { path = path, line = line or 1, buf = buf, behind = old and old.behind or 0 }
  places[id or ""] = place
  if M.shows(id) then
    place.behind = 0
    M.show(buf or M.load(path), place.line)
  else
    place.behind = place.behind + 1
    if id == M.focus then
      input.redraw()
    end
  end
end

-- The focused agent's place: the buffer that it writes into while that
-- lives, as a Write preview of a file that may not exist yet, else the file.
-- Without either, the agent stays ahead.
local function catch_up()
  local place = M.place()
  local buf = place and place.buf
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = place and vim.uv.fs_stat(place.path) and M.load(place.path)
  end
  if buf then
    place.behind = 0
    M.show(buf, place.line)
  end
end

-- Moves the code window to the focused agent's latest place. A pin goes
-- first, since it would keep the view where the user pointed.
function M.jump()
  require("anvim.context").clear()
  catch_up()
  input.redraw()
end

-- When following, the code window catches up with the focused agent, as on
-- entering the prompt or after a pin ends.
function M.resume()
  local place = M.place()
  if M.following() and place and place.behind > 0 then
    catch_up()
  end
  input.redraw()
end

-- Follow mode follows agent `id`, or the main agent for nil, and catches up
-- with it at once. Elsewhere the statusline points at its place.
---@param id string?
function M.set_focus(id)
  local agent = id and agents.get(id)
  if id and not (agent and agent.status == "running") then
    return
  end
  M.focus, focus_name = id, agent and agents.name(agent)
  local place = M.place()
  if place and M.following() then
    catch_up()
  elseif place then
    place.behind = math.max(place.behind, 1)
  end
  agents.changed()
end

-- Slot 0 is the main agent.
function M.focus_slot(slot)
  local agent = slot > 0 and agents.in_slot(slot)
  if slot > 0 and not agent then
    vim.notify(("No agent in slot %d"):format(slot), vim.log.levels.INFO, { title = "anvim", timeout = 1500 })
    return
  end
  M.set_focus(agent and agent.id or nil)
end

-- Focus goes back to the main agent when the focused agent ends. A session
-- that forgot its agents says nothing.
local function on_agents()
  for key in pairs(places) do
    if key ~= "" and not agents.get(key) then
      places[key] = nil
    end
  end
  local agent = M.focus and agents.get(M.focus)
  if not M.focus or (agent and agent.status == "running") then
    focus_name = agent and agents.name(agent)
    return
  end
  M.focus = nil
  if agent then
    require("anvim.transcript").notice("info", ("%s ended · focus is back on Claude"):format(focus_name))
  end
  -- From the event loop: a file that this non-nested handler loads would get
  -- no BufReadPost, so no filetype and no read-only lock.
  local place = M.place()
  if place and place.behind > 0 then
    vim.schedule(M.resume)
  end
  agents.changed()
end

-- A new session starts with no places and no focus.
function M.forget()
  places, writes, M.focus, focus_name = {}, {}, nil, nil
end

---@param rows integer[] 0-based rows
function M.flash(buf, rows, group, ms)
  local marks = {}
  for _, row in ipairs(rows) do
    if row < api.nvim_buf_line_count(buf) then
      marks[#marks + 1] = api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = group, priority = 150 })
    end
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      for _, mark in ipairs(marks) do
        api.nvim_buf_del_extmark(buf, ns, mark)
      end
    end
  end, ms or 1200)
end

---@param id string? The agent's agent_id. nil is the main agent.
local function on_read(ev, id)
  local path = ev.input.file_path
  if type(path) ~= "string" or not vim.uv.fs_stat(path) then
    return
  end
  local first = tonumber(ev.input.offset) or 1
  M.track(path, first, nil, id)
  if not M.shows(id) then
    return
  end
  local win = layout.code_win()
  api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  local buf = api.nvim_win_get_buf(win)
  local last = math.min(first + (tonumber(ev.input.limit) or api.nvim_win_get_height(win)) - 1, vim.fn.line("w$", win))
  local rows = {}
  for row = first - 1, last - 1 do
    rows[#rows + 1] = row
  end
  M.flash(buf, rows, "AnvimRead", 400)
end

-- A subagent's edits arrive whole, so its place is the edit's line. A Write of
-- a new file shows once the file exists. A typed preview of the edit keeps
-- the place itself, whichever of the hook and the tool_use comes first.
local function on_agent_edit(agent, ev)
  local path = ev.input.file_path or ev.input.notebook_path
  if type(path) ~= "string" or require("anvim.stream").typed(ev.id) then
    return
  elseif not vim.uv.fs_stat(path) then
    writes[ev.id] = { agent = agent.id, path = path }
    return
  end
  M.track(path, ev.name == "Edit" and agents.edit_line(path, ev.input) or 1, nil, agent.id)
end

local edit_tools = { Edit = true, Write = true, NotebookEdit = true }

-- Where Claude is, as plain text for the statusline. A global statusline
-- shows the current window, so this does not depend on the window. A focused
-- subagent takes Claude's name.
---@param short boolean? Without the words, for a narrow statusline.
function M.status(short)
  local place = M.place()
  local where = place
    and ("%s:%d%s"):format(
      require("anvim.transcript").relpath(place.path),
      place.line,
      place.behind > 0 and (" +%d"):format(place.behind) or ""
    )
  local agent = M.focused()
  local name = agent and agents.name(agent) or "Claude"
  local claude = where and (short and where or name .. " at " .. where) or (agent and name)
  if M.paused() then
    return short and "⏸ " .. (where or "pinned") or "⏸ pinned" .. (claude and " · " .. claude or "")
  elseif M.enabled() then
    return agent and (short and "◉ " or "◉ following ") .. name or "◉ following"
  end
  return claude and "⏺ " .. claude or ""
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- The main agent, then the running agents by slot. Each shows its place in
-- the preview.
local function pick_items()
  local relpath = require("anvim.transcript").relpath
  local list = { { name = "Claude", group = agents.group(0), description = "main agent" } }
  for _, agent in ipairs(agents.running()) do
    list[#list + 1] = {
      agent_id = agent.id,
      name = agents.name(agent),
      group = agents.group(agent.slot),
      description = agent.description,
      activity = agent.activity,
      tools = plural(agent.tools, "tool use"),
    }
  end
  local width = 0
  for _, item in ipairs(list) do
    width = math.max(width, api.nvim_strwidth(item.name))
  end
  for _, item in ipairs(list) do
    local place = places[item.agent_id or ""] or (item.agent_id and agents.get(item.agent_id).place)
    item.name = item.name .. (" "):rep(width - api.nvim_strwidth(item.name))
    item.focused = item.agent_id == M.focus
    item.where = place and ("%s:%d"):format(relpath(place.path), place.line)
    item.text = table.concat({ item.name, item.description, item.activity or "", item.where or "" }, " ")
    if place and vim.uv.fs_stat(place.path) then
      item.file, item.pos, item.preview = place.path, { place.line, 0 }, "file"
    else
      item.preview = { text = item.description ~= "" and item.description or item.name, loc = false }
    end
  end
  return list
end

function M.pick()
  Snacks.picker.pick({
    source = "anvim_agents",
    title = "Agents",
    items = pick_items(),
    format = function(item)
      local ret = {
        { item.focused and "◉ " or "⏺ ", item.group },
        { item.name .. "  ", item.group },
        { item.description },
      }
      local info = {}
      info[#info + 1] = item.activity
      info[#info + 1] = item.tools
      info[#info + 1] = item.where
      if #info > 0 then
        ret[#ret + 1] = { "  " .. table.concat(info, " · "), "Comment" }
      end
      return ret
    end,
    preview = "preview",
    -- Without a query, the main agent stays on top, then the slots in order.
    sort = { fields = { "score:desc", "idx" } },
    -- The cursor goes back where it was, such as the prompt, which is no file.
    main = { current = true },
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          M.set_focus(item.agent_id)
        end)
      end
    end,
  })
end

function M.attach(sidecar)
  sidecar.on("tool_use", function(ev)
    local agent = agents.of(ev)
    if agent and ev.name == "Read" then
      on_read(ev, agent.id)
    elseif agent and edit_tools[ev.name] then
      on_agent_edit(agent, ev)
    elseif ev.name == "Read" and not ev.parent_id then
      on_read(ev)
    end
  end)
  sidecar.on("tool_result", function(ev)
    local write = writes[ev.id]
    writes[ev.id] = nil
    if write and not ev.is_error and vim.uv.fs_stat(write.path) and agents.get(write.agent) then
      M.track(write.path, 1, nil, write.agent)
    end
  end)
  sidecar.on("turn_end", function()
    writes = {}
  end)
  local group = api.nvim_create_augroup("anvim.follow", {})
  -- The catch-up waits for the event loop. A file that it loads inside the
  -- window's autocmds can miss its filetype: a non-nested autocmd blocks
  -- BufReadPost, and in one order of the stack tests did_filetype() was
  -- already 1 for the new buffer, nested or not. And :redrawstatus inside a
  -- window command, such as a split that anvim is about to fold back, would
  -- show a frame too early.
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      vim.schedule(M.resume)
    end,
  })
  api.nvim_create_autocmd("User", { group = group, pattern = "AnvimAgents", callback = on_agents })
  vim.keymap.set("n", "<leader>j", M.jump, { desc = "Jump to where Claude or the focused agent is" })
  vim.keymap.set("n", "<leader>kj", M.jump, { desc = "Jump to where Claude or the focused agent is" })
  vim.keymap.set("n", "<leader>k0", function()
    M.focus_slot(0)
  end, { desc = "Focus the main agent" })
  for slot = 1, agents.slots do
    vim.keymap.set("n", "<leader>k" .. slot, function()
      M.focus_slot(slot)
    end, { desc = ("Focus agent %d"):format(slot) })
  end
  vim.keymap.set("n", "<leader>ka", M.pick, { desc = "Pick an agent to focus" })
end

return M
