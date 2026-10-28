---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local transcript = require("anvim.transcript")

describe("layout", function()
  it("has code, transcript and input windows", function()
    local started = helpers.start()
    for _, role in ipairs({ "code", "transcript", "input" }) do
      assert(vim.api.nvim_win_is_valid(layout.wins[role]), role .. " window missing")
    end
    assert.are.same(transcript.buf(), vim.api.nvim_win_get_buf(layout.wins.transcript))
    assert.are.same(input.buf(), vim.api.nvim_win_get_buf(layout.wins.input))
    assert.are.same("input", started, "start focuses the input")
  end)
end)

describe("wrap in the code window", function()
  local api = vim.api
  local prefs = require("anvim.prefs")

  local function saved()
    local f = assert(io.open(prefs.path))
    local data = vim.json.decode(f:read("*a"))
    f:close()
    return data.code_wrap
  end

  -- A spec that fails with wrap off would leave it off for the next specs.
  after_each(function()
    if not layout.wraps() then
      layout.set_wrap(true)
    end
  end)

  -- Shows a file with a long line in the code window.
  local function show(name)
    local file = helpers.tmp .. "/" .. name
    vim.fn.writefile({ "  " .. ("word "):rep(40) }, file)
    local buf = vim.fn.bufadd(file)
    vim.fn.bufload(buf)
    api.nvim_win_set_buf(layout.wins.code, buf)
    return buf
  end

  local function options(win)
    return { wrap = vim.wo[win].wrap, breakindent = vim.wo[win].breakindent, showbreak = vim.wo[win].showbreak }
  end

  -- The empty buffer that Neovim starts with goes once another buffer shows.
  local function close(before, bufs)
    if api.nvim_buf_is_valid(before) then
      api.nvim_win_set_buf(layout.wins.code, before)
    end
    for _, buf in ipairs(bufs) do
      api.nvim_buf_delete(buf, { force = true })
    end
  end

  it("applies the choice to each buffer that the code window shows, and keeps it in prefs.json", function()
    helpers.start()
    local code = layout.wins.code
    local before = api.nvim_win_get_buf(code)
    local seen = show("wrap_seen.lua")
    local current = show("wrap_current.lua")
    layout.set_wrap(false)
    assert.is_false(saved())
    assert.is_false(vim.wo[code].wrap, "the buffer in the window")
    api.nvim_win_set_buf(code, seen)
    assert.is_false(vim.wo[code].wrap, "a buffer that the window showed with wrap")
    local new = show("wrap_new.lua")
    assert.is_false(vim.wo[code].wrap, "a buffer that no window showed")
    local float = api.nvim_win_call(code, function()
      local opts = { relative = "editor", row = 1, col = 1, width = 20, height = 3 }
      return api.nvim_open_win(api.nvim_create_buf(false, true), false, opts)
    end)
    assert.is_false(vim.wo[float].wrap, "a float from the code window, such as a picker's preview")
    api.nvim_win_close(float, true)

    local notes = show("wrap_notes.md")
    assert.are.same("markdown", vim.bo[notes].filetype)
    assert.are.same(
      { wrap = true, breakindent = true, showbreak = "NONE" },
      options(code),
      "text wraps without the mark"
    )
    api.nvim_win_set_buf(code, new)
    vim.bo[new].filetype = "text"
    assert.is_true(vim.wo[code].wrap, "a buffer that becomes text")
    vim.bo[new].filetype = "lua"
    assert.is_false(vim.wo[code].wrap)

    layout.set_wrap(true)
    assert.is_true(saved())
    assert.is_true(vim.wo[code].wrap)
    api.nvim_win_set_buf(code, seen)
    assert.are.same({ wrap = true, breakindent = true, showbreak = "↪ " }, options(code))
    close(before, { seen, current, new, notes })
  end)
end)

describe("the tool pane", function()
  local api = vim.api
  local prefs = require("anvim.prefs")

  local function saved()
    local f = assert(io.open(prefs.path))
    local data = vim.json.decode(f:read("*a"))
    f:close()
    return data.tool_pane
  end

  local function box(win)
    local pos = vim.fn.win_screenpos(win)
    return { row = pos[1], col = pos[2], width = api.nvim_win_get_width(win), height = api.nvim_win_get_height(win) }
  end

  after_each(function()
    layout.set_pane(false)
  end)

  it("opens under the code window, takes no focus, and closes, and prefs.json keeps the choice", function()
    helpers.start()
    layout.focus_input({ insert = false })
    local code = box(layout.wins.code)
    layout.set_pane(true)
    local pane = layout.wins.pane
    assert(pane and api.nvim_win_is_valid(pane), "no pane")
    assert.is_true(saved())
    assert.is_true(transcript.pane_on, "the tool calls go to the main log")
    assert.are.same(transcript.log_buf(), api.nvim_win_get_buf(pane))
    assert.are.same(layout.wins.input, api.nvim_get_current_win(), "the cursor stays in the prompt")
    local top, bottom = box(layout.wins.code), box(pane)
    assert.are.same({ code.row, code.col, code.width }, { top.row, top.col, top.width })
    assert.are.same({ top.row + top.height + 1, code.col, code.width }, { bottom.row, bottom.col, bottom.width })
    assert.are.same(code.height, top.height + 1 + bottom.height, "the two share the column")
    assert.is_false(api.nvim_win_get_config(pane).focusable)
    local wo = vim.wo[pane]
    -- The prompt had the cursor, and a new window copies its options.
    local got = { wo.number, wo.statuscolumn, wo.conceallevel, wo.winfixwidth, wo.winfixheight, wo.winfixbuf }
    assert.are.same({ false, " ", 0, false, true, true }, got)
    local bar = api.nvim_eval_statusline(wo.winbar, { winid = pane, use_winbar = true })
    assert.are.same(" Tool calls ", bar.str)

    layout.set_pane(false)
    assert.is_nil(layout.wins.pane)
    assert.is_false(api.nvim_win_is_valid(pane))
    assert.is_false(saved())
    assert.is_false(transcript.pane_on, "the tool calls stay in the chat")
    assert.are.same(code, box(layout.wins.code), "the code window takes the column again")
  end)

  it("names the followed agent in its tab, with the time that its run has worked", function()
    local agents, follow, sidecar = require("anvim.agents"), require("anvim.follow"), require("anvim.sidecar")
    local now = 5000
    agents.clock = function()
      return now
    end
    helpers.start()
    layout.set_pane(true)
    local pane = layout.wins.pane
    local function tab()
      return api.nvim_eval_statusline(vim.wo[pane].winbar, { winid = pane, use_winbar = true }).str
    end
    sidecar.dispatch({ type = "agent_start", agent_id = "t1", tool_use_id = "tu_t1", description = "Time", depth = 1 })
    sidecar.dispatch({ type = "tool_use", id = "t1a", name = "Bash", input = { command = "ls" }, agent_id = "t1" })
    follow.set_focus("t1")
    now = 5000 + 72400
    assert.are.same(" Tool calls · Agent 1 · 1m 12s ", tab())
    -- SendMessage continues it, and the new run counts from zero.
    sidecar.dispatch({ type = "agent_end", agent_id = "t1", status = "completed" })
    sidecar.dispatch({ type = "agent_start", agent_id = "t1", tool_use_id = "tu_t1b", description = "Time", depth = 1 })
    follow.set_focus("t1")
    now = now + 3200
    assert.are.same(" Tool calls · Agent 1 · 3s ", tab())

    agents.clock = vim.uv.now
    sidecar.dispatch({ type = "reset" })
    follow.forget()
  end)

  it("keeps its own choice when another anvim saves another one", function()
    helpers.start()
    layout.set_pane(true)
    local pane = layout.wins.pane
    -- Another anvim turns its pane off, and this one then saves another choice.
    local f = assert(io.open(prefs.path, "w"))
    f:write(vim.json.encode({ tool_pane = false }))
    f:close()
    prefs.set("code_wrap", true)
    assert.is_false(prefs.get("tool_pane"))
    local code = layout.wins.code
    api.nvim_win_close(code, true)
    assert(
      vim.wait(1000, function()
        return api.nvim_win_is_valid(layout.wins.code) and layout.wins.code ~= code
      end, 10),
      "the code window did not come back"
    )
    assert.are.same(pane, layout.wins.pane)
    assert.is_true(api.nvim_win_is_valid(pane), "the repair closed the pane")
    assert.is_true(layout.pane_shown())
    assert.is_true(transcript.pane_on)
  end)
end)

describe("the todo window", function()
  local api = vim.api
  local config = require("anvim.config")
  local sidecar = require("anvim.sidecar")
  local todos = require("anvim.todos")
  local max

  local function list(items)
    sidecar.dispatch({ type = "todos", items = items })
  end

  local function inline()
    local text = table.concat(api.nvim_buf_get_lines(transcript.buf(), 0, -1, false), "\n")
    return text:find("Todos · ", 1, true) ~= nil
  end

  after_each(function()
    config.options.layout.input_height.max = max
    layout.set_todo_window(false)
    todos.set({})
  end)

  it("shows the list on top of the Claude column, or inline when it is off or has no room", function()
    helpers.start()
    max = config.options.layout.input_height.max
    local items = {
      { id = 1, subject = "Read the file", status = "completed" },
      { id = 2, subject = "Fix the bug", status = "in_progress" },
    }
    layout.set_todo_window(true)
    assert.is_true(require("anvim.prefs").get("todo_window"))
    -- The test screen has 24 rows: too few next to a prompt of up to 12.
    list(items)
    assert.is_nil(layout.wins.todos)
    assert.is_true(inline())

    config.options.layout.input_height.max = 3
    list(items)
    local win = assert(layout.wins.todos, "no todo window")
    assert.are.same({ "  ☒ #1 Read the file", "  ☐ #2 Fix the bug" }, helpers.buf_lines(api.nvim_win_get_buf(win)))
    local bar = api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true })
    assert.are.same("  Todos · 1 of 2 done", bar.str)
    assert.is_false(api.nvim_win_get_config(win).focusable)
    local top, below = vim.fn.win_screenpos(win), vim.fn.win_screenpos(layout.wins.transcript)
    assert.are.same({ top[1] + api.nvim_win_get_height(win) + 1, top[2] }, below)
    assert.is_false(inline(), "the list shows twice")

    layout.set_todo_window(false)
    assert.is_false(api.nvim_win_is_valid(win))
    assert.is_true(inline())
    layout.set_todo_window(true)
    assert.is_true(layout.todos_shown())
    assert.is_false(inline())

    list({})
    assert.is_nil(layout.wins.todos)
    assert.is_false(inline())
  end)
end)
