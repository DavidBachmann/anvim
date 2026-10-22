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
