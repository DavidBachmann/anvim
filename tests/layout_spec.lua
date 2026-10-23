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

  it("grows the prompt with its lines, and keeps the footer under the last one", function()
    helpers.start()
    local buf, win = input.buf(), layout.wins.input
    local function footer_row()
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        if mark[4].virt_lines then
          return mark[2]
        end
      end
    end
    assert.are.same(3, vim.api.nvim_win_get_height(win), "one line, the footer and the winbar")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
    input.render()
    assert.are.same(5, vim.api.nvim_win_get_height(win))
    assert.are.same(2, footer_row())
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(("x\n"):rep(30), "\n"))
    input.render()
    assert.are.same(13, vim.api.nvim_win_get_height(win), "at most 12 rows and the winbar")
    vim.api.nvim_win_set_cursor(win, { 31, 0 })
    input.show_footer()
    local showmode = vim.o.showmode
    vim.o.showmode = false
    vim.cmd.redraw()
    vim.o.showmode = showmode
    local shown = vim.api.nvim_win_text_height(win, { start_row = vim.fn.line("w0", win) - 1 }).all
    assert(shown <= 12, ("the footer is out of view: %d rows from the top line"):format(shown))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    input.render()
    assert.are.same(3, vim.api.nvim_win_get_height(win))
    assert.are.same(0, footer_row())
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

  it("wraps code by default, keeps the indent, and marks each wrapped row", function()
    helpers.start()
    local code = layout.wins.code
    local before = api.nvim_win_get_buf(code)
    local buf = show("wrap_default.lua")
    assert.is_true(layout.wraps())
    assert.are.same({ wrap = true, breakindent = true, showbreak = "↪ " }, options(code))
    close(before, { buf })
  end)

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

  -- The rows of the code column: the code window, the row under it and the pane.
  local function column()
    return api.nvim_win_get_height(layout.wins.code) + 1 + api.nvim_win_get_height(layout.wins.pane)
  end

  local function wait_valid(role)
    assert(
      vim.wait(1000, function()
        local win = layout.wins[role]
        return win ~= nil and api.nvim_win_is_valid(win)
      end, 10),
      "no " .. role .. " window"
    )
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
    assert.is_true(transcript.tools_apart, "the tool calls go to the main log")
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
    assert.are.same({ false, "", 0, false, true, true }, got)
    local bar = api.nvim_eval_statusline(wo.winbar, { winid = pane, use_winbar = true })
    assert.are.same(" Tool calls", bar.str)

    layout.set_pane(false)
    assert.is_nil(layout.wins.pane)
    assert.is_false(api.nvim_win_is_valid(pane))
    assert.is_false(saved())
    assert.is_false(transcript.tools_apart, "the tool calls stay in the chat")
    assert.are.same(code, box(layout.wins.code), "the code window takes the column again")
  end)

  it("shows at a first start, with no choice in prefs.json, and takes the tool calls", function()
    helpers.start()
    local path, explorer = prefs.path, Snacks.explorer
    prefs.path = vim.fn.tempname() .. "/prefs.json"
    -- Reads the new file, which has no choice.
    prefs.set("tool_pane", nil)
    -- The specs do not use the tree.
    Snacks.explorer = function() end
    local ok, err = pcall(function()
      layout.setup()
      layout.open()
    end)
    Snacks.explorer = explorer
    prefs.path = path
    assert(ok, err)
    assert.is_true(layout.pane_shown())
    assert.is_true(transcript.tools_apart)
    wait_valid("pane")
    layout.focus_input({ insert = false })
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
    assert.is_true(transcript.tools_apart)
  end)

  it("takes a quarter of the column, after a resize, a cmdheight change and a repair too", function()
    helpers.start()
    layout.set_pane(true)
    local pane = layout.wins.pane
    local rows = column()
    assert.are.same(math.floor(rows * 0.25), api.nvim_win_get_height(pane))

    local cmdheight = vim.o.cmdheight
    vim.o.cmdheight = cmdheight + 2
    assert.are.same(math.floor(rows * 0.25), api.nvim_win_get_height(pane), "the code window gives the rows")
    vim.o.cmdheight = cmdheight

    api.nvim_buf_set_lines(input.buf(), 0, -1, false, vim.split(("x\n"):rep(10), "\n"))
    input.render()
    assert.are.same(math.floor(rows * 0.25), api.nvim_win_get_height(pane), "the prompt grew")
    assert.are.same(rows, column())
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    input.render()

    api.nvim_win_set_height(pane, 3)
    api.nvim_exec_autocmds("VimResized", {})
    assert.are.same(math.floor(rows * 0.25), api.nvim_win_get_height(pane), "VimResized")

    -- From the prompt, and with :close in the code window, which puts the
    -- cursor in the pane while the code window closes.
    for _, from in ipairs({ "input", "code" }) do
      local code = layout.wins.code
      api.nvim_set_current_win(layout.wins[from])
      vim.cmd.stopinsert()
      if from == "code" then
        vim.cmd.close()
      else
        api.nvim_win_close(code, true)
      end
      assert(
        vim.wait(1000, function()
          return api.nvim_win_is_valid(layout.wins.code) and layout.wins.code ~= code
        end, 10),
        "the code window did not come back"
      )
      assert.are.same(layout.wins[from], api.nvim_get_current_win(), "the cursor after a close from the " .. from)
      assert.are.same(pane, layout.wins.pane)
      assert.are.same(math.floor(rows * 0.25), api.nvim_win_get_height(pane), "after the code window's repair")
      assert.are.same(rows, column())
      local top, bottom = box(layout.wins.code), box(pane)
      assert.are.same({ top.col, top.width, top.row + top.height + 1 }, { bottom.col, bottom.width, bottom.row })
    end
    layout.focus_input({ insert = false })
  end)

  it("comes back when it closes, and a closed pane stays closed while the choice is off", function()
    helpers.start()
    layout.set_pane(true)
    local pane = layout.wins.pane
    api.nvim_win_close(pane, true)
    assert(
      vim.wait(1000, function()
        return layout.wins.pane ~= pane and layout.wins.pane ~= nil and api.nvim_win_is_valid(layout.wins.pane)
      end, 10),
      "the pane did not come back"
    )
    wait_valid("code")
    assert.are.same(transcript.log_buf(), api.nvim_win_get_buf(layout.wins.pane))

    api.nvim_set_current_win(layout.wins.code)
    vim.cmd.only()
    for _, role in ipairs({ "transcript", "input", "pane" }) do
      wait_valid(role)
    end
    local top, bottom = box(layout.wins.code), box(layout.wins.pane)
    assert.are.same({ top.col, top.width, top.row + top.height + 1 }, { bottom.col, bottom.width, bottom.row }, ":only")
    assert.are.same(math.floor(column() * 0.25), bottom.height, ":only")
    layout.focus_input({ insert = false })

    layout.set_pane(false)
    layout.repair()
    assert.is_nil(layout.wins.pane)
  end)
end)
