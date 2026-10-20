---@module "luassert"

local agents = require("anvim.agents")
local context = require("anvim.context")
local follow = require("anvim.follow")
local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local permission = require("anvim.permission")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

local function file(name)
  local path = helpers.tmp .. "/" .. name
  vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "local d = 4", "return a" }, path)
  return path
end

local function start(id, extra)
  sidecar.dispatch(vim.tbl_extend("force", {
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "general-purpose",
    depth = 1,
    background = false,
  }, extra or {}))
end

local function finish(id)
  sidecar.dispatch({ type = "agent_end", agent_id = id, status = "completed", summary = "done" })
end

local tool_ids = 0

-- A tool call of agent `id`, or of the main agent for nil.
local function use(id, name, tool_input)
  tool_ids = tool_ids + 1
  local tool_id = "focus_tool" .. tool_ids
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = name,
    input = tool_input,
    parent_id = id and "tu_" .. id or nil,
    agent_id = id,
  })
  return tool_id
end

local function read(id, path, offset)
  use(id, "Read", { file_path = path, offset = offset })
end

local function code_file()
  return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code))
end

local function code_line()
  return api.nvim_win_get_cursor(layout.wins.code)[1]
end

-- The prompt in normal mode, where follow mode follows. Entering it catches
-- up from the event loop.
local function prompt()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

local function fresh()
  helpers.start()
  context.clear()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  transcript.clear()
end

local function turn_end()
  sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
end

-- The footer's dots, with their groups.
local function dots()
  local list = {}
  for _, chunk in ipairs(input.footer(120)) do
    if chunk[1] == "⏺" or chunk[1] == "◉" then
      list[#list + 1] = chunk[1] .. " " .. chunk[2]
    end
  end
  return list
end

-- The focus marks in the transcript, as the line they end and their chunks.
local function focus_marks()
  local buf = transcript.buf()
  local ns = api.nvim_get_namespaces()["anvim.transcript.focus"]
  local list = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local line = api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
    list[#list + 1] = { line, mark[4].virt_text }
  end
  return list
end

describe("focus", function()
  local restore ---@type fun()?

  after_each(function()
    permission.cancel_all()
    agents.clear()
    follow.forget()
    context.clear()
    local fn = restore
    restore = nil
    if fn then
      fn()
    end
  end)

  it("follows the focused agent only, and catches up at once on focus", function()
    fresh()
    local a, b, main = file("focus_a.lua"), file("focus_b.lua"), file("focus_main.lua")
    start("f1")
    start("f2")
    prompt()
    local before = code_file()
    read("f1", a, 2)
    assert.are.same(before, code_file(), "an agent without focus moves nothing")
    read(nil, main)
    assert.are.same(main, code_file(), "the main agent has the focus at first")
    follow.focus_slot(1)
    assert.are.same({ a, 2 }, { code_file(), code_line() }, "focus catches up")
    assert.are.same("f1", follow.focus)
    assert.are.same("◉ following Agent 1", follow.status())
    assert.are.same("◉ Agent 1", follow.status(true))
    assert.are.same("AnvimAgent1", follow.group())

    read("f2", b)
    read(nil, b)
    assert.are.same(a, code_file(), "other agents' moves leave the view alone")
    read("f1", b, 4)
    assert.are.same({ b, 4 }, { code_file(), code_line() })
    use("f1", "Edit", { file_path = a, old_string = "local c = 3", new_string = "local c = 30" })
    assert.are.same({ a, 3 }, { code_file(), code_line() }, "an edit shows its line")

    -- A Write of a new file shows once the file exists.
    local new = helpers.tmp .. "/focus_new.lua"
    os.remove(new)
    local id = use("f1", "Write", { file_path = new, content = "return 1" })
    assert.are.same(a, code_file())
    vim.fn.writefile({ "return 1" }, new)
    sidecar.dispatch({
      type = "tool_result",
      id = id,
      is_error = false,
      text = "ok",
      parent_id = "tu_f1",
      agent_id = "f1",
    })
    assert.are.same(new, code_file())

    follow.focus_slot(0)
    assert.is_nil(follow.focus)
    assert.are.same(b, code_file(), "the main agent's last place")
    assert.are.same("◉ following", follow.status())
    assert.are.same("AnvimClaude", follow.group())
    read("f1", a)
    assert.are.same(b, code_file())
  end)

  it("keeps the focused agent's count of moves while the user reads elsewhere", function()
    fresh()
    local a, other = file("focus_g.lua"), file("focus_other.lua")
    start("g1")
    start("g2")
    vim.cmd.stopinsert()
    api.nvim_set_current_win(layout.wins.code)
    vim.cmd.edit(other)
    follow.focus_slot(2)
    assert.are.same("⏺ Agent 2", follow.status(), "no place yet")
    read("g2", a)
    read("g2", a, 3)
    read("g1", other)
    read(nil, other)
    assert.are.same("⏺ Agent 2 at focus_g.lua:3 +2", follow.status())
    assert.are.same(other, code_file(), "the user is in control")
    prompt()
    assert.are.same({ a, 3 }, { code_file(), code_line() }, "entering the prompt catches up")
    assert.are.same(0, follow.place().behind)

    -- A focus from elsewhere points at the agent, and the prompt catches up.
    api.nvim_set_current_win(layout.wins.code)
    follow.focus_slot(1)
    assert.are.same("⏺ Agent 1 at focus_other.lua:1 +1", follow.status())
    follow.focus_slot(2)
    assert.are.same("⏺ Agent 2 at focus_g.lua:3 +1", follow.status(), "focus counts a place the view left")
    follow.jump()
    assert.are.same({ a, 3 }, { code_file(), code_line() }, "<leader>j goes to the focused agent")

    -- A pin pauses follow mode for the focused agent too.
    vim.api.nvim_feedkeys(vim.keycode("2GVj<Esc>"), "mxt", false)
    assert(context.selection(), "no pin")
    prompt()
    read("g2", other, 2)
    assert.are.same(a, code_file())
    assert.are.same("⏸ pinned · Agent 2 at focus_other.lua:2 +1", follow.status())
    context.clear()
    assert(
      vim.wait(1000, function()
        return code_file() == other
      end),
      "no catch-up after the pin"
    )
  end)

  it("goes back to the main agent when the focused agent ends, with a notice", function()
    fresh()
    local a, main = file("focus_h.lua"), file("focus_h_main.lua")
    start("h1")
    start("h2")
    prompt()
    follow.focus_slot(1)
    read("h1", a)
    read(nil, main, 2)
    finish("h2")
    assert.are.same("h1", follow.focus, "another agent's end keeps the focus")
    finish("h1")
    assert.is_nil(follow.focus)
    local lines = helpers.buf_lines(transcript.buf())
    assert.are.same("✻ Agent 1 ended · focus is back on Claude", lines[#lines])
    vim.wait(1000, function()
      return code_file() == main
    end)
    assert.are.same({ main, 2 }, { code_file(), code_line() }, "the main agent moved meanwhile")
    -- The catch-up loaded the file outside the AnvimAgents handler, so it has
    -- its filetype and the read-only lock.
    local buf = vim.fn.bufnr(main)
    assert.are.same({ "lua", false }, { vim.bo[buf].filetype, vim.bo[buf].modifiable })
    assert.are.same("◉ following", follow.status())

    -- A foreground agent ends with its turn.
    start("h3", { subagent_type = "Explore" })
    follow.focus_slot(1)
    turn_end()
    assert.is_nil(follow.focus)
    lines = helpers.buf_lines(transcript.buf())
    assert.are.same("✻ Explore 1 ended · focus is back on Claude", lines[#lines])

    -- A session that forgot its agents says nothing.
    start("h4")
    follow.focus_slot(1)
    local count = #helpers.buf_lines(transcript.buf())
    agents.clear()
    assert.is_nil(follow.focus)
    assert.are.same(count, #helpers.buf_lines(transcript.buf()))
  end)

  it("keeps the main agent's show_user and edit previews off a view that follows a subagent", function()
    fresh()
    local a, b = file("focus_view_a.lua"), file("focus_view_b.lua")
    start("v1")
    prompt()
    follow.focus_slot(1)
    read("v1", a)
    assert.are.same({ a, 1 }, { code_file(), code_line() })
    local reply = helpers.ask("show_user", { path = b, start_line = 3, end_line = 4, note = "here" })
    assert(reply.result:find("^Marked focus_view_b.lua#L3%-4"), reply.result)
    assert.are.same({ a, 1 }, { code_file(), code_line() }, "show_user moved the view")
    -- The main agent edits the file that the code window shows.
    sidecar.dispatch({ type = "tool_start", id = "focus_edit", name = "Edit" })
    helpers.field("focus_edit", "Edit", "file_path", "end", a)
    helpers.field("focus_edit", "Edit", "old_string", "end", "local d = 4")
    helpers.field("focus_edit", "Edit", "new_string", "delta", "local d = 40")
    helpers.field("focus_edit", "Edit", "new_string", "end", "local d = 40")
    local buf = vim.fn.bufnr(a)
    assert(
      vim.wait(1000, function()
        return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("local d = 40", 1, true) ~= nil
      end),
      "no preview"
    )
    assert.are.same({ a, 1 }, { code_file(), code_line() }, "the preview moved the cursor")
    sidecar.dispatch({ type = "tool_result", id = "focus_edit", is_error = true, text = "denied" })
  end)

  it("says so for an empty slot, and ignores an agent that does not run", function()
    fresh()
    local notify = vim.notify
    local said = {}
    restore = function()
      vim.notify = notify
    end
    vim.notify = function(msg, level)
      said[#said + 1] = { msg, level }
    end
    start("e1")
    prompt()
    follow.focus_slot(1)
    follow.focus_slot(3)
    assert.are.same({ { "No agent in slot 3", vim.log.levels.INFO } }, said)
    assert.are.same("e1", follow.focus)
    follow.set_focus("nobody")
    assert.are.same("e1", follow.focus)
    -- A fifth agent at once has no slot and no color.
    for i = 2, 5 do
      start("e" .. i)
    end
    follow.set_focus("e5")
    assert.are.same({ "e5", "Comment", "◉ following Agent" }, { follow.focus, follow.group(), follow.status() })
    for slot, desc in pairs({ [0] = "Focus the main agent", [1] = "Focus agent 1", [4] = "Focus agent 4" }) do
      assert.are.same(desc, vim.fn.maparg("<leader>k" .. slot, "n", false, true).desc)
    end
    assert.are.same("Pick an agent to focus", vim.fn.maparg("<leader>ka", "n", false, true).desc)
  end)

  it("lists the agents in a picker, and its choice takes the focus", function()
    fresh()
    local a = file("focus_p.lua")
    start("p1", { subagent_type = "Explore", description = "Find x" })
    start("p2")
    read("p1", a, 2)
    sidecar.dispatch({ type = "agent_progress", agent_id = "p1", description = "Reading focus_p.lua" })
    local pick = Snacks.picker.pick
    local opts ---@type table
    restore = function()
      Snacks.picker.pick = pick
    end
    Snacks.picker.pick = function(o)
      opts = o
    end
    follow.pick()
    local function texts(item)
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, opts.format(item)))
    end
    local items = opts.items
    assert.are.same({
      "◉ Claude     main agent",
      "⏺ Explore 1  Find x  Reading focus_p.lua · 1 tool use · focus_p.lua:2",
      "⏺ Agent 2    Task p2  0 tool uses",
    }, vim.tbl_map(texts, items))
    assert.are.same({ "AnvimClaude", "AnvimAgent1", "AnvimAgent2" }, {
      opts.format(items[1])[1][2],
      opts.format(items[2])[1][2],
      opts.format(items[3])[1][2],
    })
    assert.are.same({ a, { 2, 0 }, "file" }, { items[2].file, items[2].pos, items[2].preview })
    assert.are.same({ text = "Task p2", loc = false }, items[3].preview)

    prompt()
    local closed = false
    opts.confirm({
      close = function()
        closed = true
      end,
    }, items[2])
    assert(closed)
    assert(
      vim.wait(1000, function()
        return follow.focus == "p1"
      end),
      "the choice took no focus"
    )
    assert.are.same({ a, 2 }, { code_file(), code_line() })
    follow.pick()
    assert.are.same({ "⏺ Claude", "◉ Explore 1" }, {
      texts(opts.items[1]):sub(1, #"⏺ Claude"),
      texts(opts.items[2]):sub(1, #"◉ Explore 1"),
    })
    opts.confirm({ close = function() end }, opts.items[1])
    assert(
      vim.wait(1000, function()
        return follow.focus == nil
      end),
      "the main agent took no focus"
    )
  end)

  it("marks the focused agent with ◉ in the footer and at the end of its Agent line", function()
    fresh()
    sidecar.dispatch({ type = "turn_start" })
    for _, id in ipairs({ "m1", "m2" }) do
      sidecar.dispatch({ type = "tool_start", id = "tu_" .. id, name = "Agent" })
      sidecar.dispatch({
        type = "tool_use",
        id = "tu_" .. id,
        name = "Agent",
        input = { description = "Mark " .. id, subagent_type = "Explore" },
      })
      start(id, { description = "Mark " .. id, subagent_type = "Explore" })
    end
    assert.are.same({ "⏺ AnvimAgent1", "⏺ AnvimAgent2" }, dots())
    assert.are.same({}, focus_marks())
    follow.focus_slot(2)
    assert.are.same({ "⏺ AnvimAgent1", "◉ AnvimAgent2" }, dots())
    local mark = { "⏺ Explore(Mark m2)", { { "◉ focused", "AnvimAgent2" } } }
    assert.are.same({ mark }, focus_marks())
    -- The mark keeps its line when the line or the lines under it change.
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_m2",
      name = "Agent",
      input = { description = "Mark m2", subagent_type = "Explore" },
    })
    use("m2", "Grep", { pattern = "x" })
    use("m1", "Grep", { pattern = "y" })
    assert.are.same({ mark }, focus_marks())
    follow.focus_slot(1)
    assert.are.same({ { "⏺ Explore(Mark m1)", { { "◉ focused", "AnvimAgent1" } } } }, focus_marks())
    follow.focus_slot(0)
    assert.are.same({}, focus_marks())
    assert.are.same({ "⏺ AnvimAgent1", "⏺ AnvimAgent2" }, dots())
    turn_end()
  end)

  it("names a subagent's permission request by its type and slot, in its color", function()
    fresh()
    local path = file("focus_perm.lua")
    start("q0")
    start("q1", { subagent_type = "Explore", description = "Find x" })
    local function header(agent_id, req)
      sidecar.dispatch({
        type = "permission_request",
        req = req,
        tool_use_id = "focus_perm" .. req,
        tool = "Edit",
        input = { file_path = path, old_string = "local a = 1", new_string = "local a = 2" },
        agent_id = agent_id,
      })
      local buf = transcript.buf()
      local ns = api.nvim_get_namespaces()["anvim.transcript"]
      for row, line in ipairs(helpers.buf_lines(buf)) do
        if line:find("^  Edit file") then
          local marks = {}
          for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
            if m[4].hl_group then
              marks[#marks + 1] = { line:sub(m[3] + 1, m[4].end_col), m[4].hl_group }
            end
          end
          permission.cancel_all()
          return line, marks
        end
      end
      error("no request")
    end
    local line, marks = header("q1", 901)
    assert.are.same("  Edit file · Explore 2 (Find x)", line)
    assert.are.same({ { "Edit file", "AnvimAsk" }, { "Explore 2 (Find x)", "AnvimAgent2" } }, marks)
    line, marks = header("unknown", 902)
    assert.are.same("  Edit file (subagent)", line)
    assert.are.same({ { "Edit file (subagent)", "AnvimAsk" } }, marks)
    line = header(nil, 903)
    assert.are.same("  Edit file", line)
  end)
end)
