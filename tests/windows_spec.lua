---@module "luassert"

local helpers = require("helpers")
local layout = require("anvim.layout")
local transcript = require("anvim.transcript")
local windows = require("anvim.windows")

local api = vim.api

-- Runs keys as if typed. Without a UI there is no SafeState, so the window
-- rules run from the event loop, which vim.wait drives.
local function keys(k)
  api.nvim_feedkeys(vim.keycode(k), "xt", false)
  vim.wait(20)
end

local function settle()
  vim.wait(20)
end

local function current()
  return api.nvim_get_current_win()
end

-- Non-floating windows that show a file buffer.
local function code_wins()
  local wins = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == "" and layout.is_code(api.nvim_win_get_buf(win)) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

local file = helpers.tmp .. "/matchparen.lua"

-- The code window shows the fixture with the cursor on line 20, and has focus.
local function in_code()
  helpers.start()
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.code_win())
  vim.cmd.edit(file)
  api.nvim_win_set_cursor(0, { 20, 0 })
  settle()
end

describe("windows", function()
  it("folds a split back into the code window, at the same place", function()
    local other = helpers.tmp .. "/other.lua"
    vim.fn.writefile({ "return 1", "return 2", "return 3" }, other)
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local cases = {
      { cmd = "split", buf = file, line = 20 },
      { cmd = "vsplit", buf = file, line = 20 },
      { cmd = "new", buf = "", line = 1 },
      { cmd = "split " .. other, buf = other, line = 1 },
      { cmd = "diffsplit " .. other, buf = other },
      { keys = "<C-w>v", buf = file, line = 20 },
      { keys = "<C-w>s", buf = file, line = 20 },
    }
    for _, case in ipairs(cases) do
      in_code()
      local what = case.cmd or case.keys
      if case.cmd then
        vim.cmd(case.cmd)
      else
        keys(case.keys)
      end
      assert(
        vim.wait(500, function()
          return #code_wins() == 1
        end, 10),
        what .. " left two code windows"
      )
      local code = layout.wins.code
      assert.are.same({ code }, code_wins(), what)
      assert.are.same(code, current(), what .. " focuses the code window")
      assert.are.same(case.buf, api.nvim_buf_get_name(api.nvim_win_get_buf(code)), what)
      if case.line then
        assert.are.same(case.line, api.nvim_win_get_cursor(code)[1], what)
      end
      assert.is_false(vim.wo[code].diff, what .. " leaves diff mode on")
    end
    vim.notify = notify
    assert(#notes <= 1, "the notice shows once: " .. vim.inspect(notes))
    layout.focus_input()
  end)

  it("makes the code window snacks' main window, also when it shows no file and after it comes back", function()
    local main = require("snacks.picker.core.main")
    in_code()
    vim.cmd.split()
    assert.is_nil(vim.w[current()].snacks_main, "a split of the code window carries the mark")
    settle()
    local old = layout.wins.code
    vim.cmd.close()
    assert(
      vim.wait(500, function()
        return api.nvim_win_is_valid(layout.wins.code) and layout.wins.code ~= old
      end, 10),
      "the code window did not come back"
    )
    local preview = api.nvim_create_buf(false, true)
    vim.b[preview].anvim_preview = helpers.tmp .. "/new_file.lua"
    api.nvim_win_set_buf(layout.wins.code, preview)
    layout.focus_input()
    assert.are.same(layout.wins.code, main.new():find(), "a picker from the prompt jumps elsewhere")
    api.nvim_set_current_win(layout.wins.code)
    vim.cmd.edit(file)
    api.nvim_buf_delete(preview, { force = true })
    layout.focus_input()
  end)

  it("reopens closed windows", function()
    local function assert_layout(what)
      assert(
        vim.wait(500, function()
          return api.nvim_win_is_valid(layout.wins.code)
            and api.nvim_win_is_valid(layout.wins.transcript)
            and api.nvim_win_is_valid(layout.wins.input)
        end, 10),
        what .. " left the layout broken"
      )
      local code = vim.fn.win_screenpos(layout.wins.code)
      local tr = vim.fn.win_screenpos(layout.wins.transcript)
      local prompt = vim.fn.win_screenpos(layout.wins.input)
      assert(code[2] < tr[2], what .. ": the code window is left of the transcript")
      assert.are.same(tr[2], prompt[2], what .. ": the prompt is under the transcript")
      assert(tr[1] < prompt[1], what .. ": the prompt is under the transcript")
      assert.are.same(1, code[1], what .. ": the code window has the full height")
      assert.are.same(4, api.nvim_win_get_height(layout.wins.input), what .. ": the prompt fits its text")
      assert.are.same(file, api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)), what)
    end
    in_code()
    vim.cmd.only()
    assert_layout(":only in the code window")
    assert.are.same(layout.wins.code, current(), "the cursor stays in the code window")
    vim.cmd.close()
    assert_layout(":close in the code window")
    layout.focus_input()
    vim.cmd.close()
    assert_layout(":close in the prompt")
    assert.are.same(layout.wins.input, current())
    windows.read()
    vim.cmd.close()
    assert_layout(":close in the transcript")
    assert.are.same(layout.wins.input, current())
    vim.cmd.only()
    assert_layout(":only in the prompt")
    layout.focus_input()
  end)

  it("starts insert mode in the prompt only for insert commands, and not while a request waits", function()
    in_code()
    local state = require("anvim.state")
    -- Without a main loop, a pending insert does not show in the mode, so count the calls.
    local calls, startinsert = 0, vim.cmd.startinsert
    vim.cmd.startinsert = function()
      calls = calls + 1
    end
    local function enter(how)
      calls = 0
      api.nvim_set_current_win(layout.wins.code)
      vim.cmd("normal! H")
      if how == "<C-w>l" then
        vim.cmd.wincmd("l")
      else
        layout.focus_input()
      end
      assert.are.same(layout.wins.input, current(), how)
      return calls
    end
    local ok, err = pcall(function()
      assert.are.same(0, enter("<C-w>l"), "<C-w>l leaves the prompt in normal mode")
      assert(enter("focus_input") > 0, "focus_input, as i and a in a file buffer, starts insert mode")
      state.waiting = "To answer: esc, then 1-3"
      assert.are.same(0, enter("<C-w>l"), "<C-w>l while a request waits")
      assert.are.same(0, enter("focus_input"), "focus_input while a request waits")
    end)
    state.waiting = nil
    vim.cmd.startinsert = startinsert
    assert(ok, err)
  end)
end)

describe("the transcript's view", function()
  -- WinScrolled does not fire under nvim -l, so the spec caps the view after
  -- each scroll, as the handler does.
  local function scroll(key)
    windows.scroll(key)
    windows.clamp(layout.wins.transcript)
  end

  local function top()
    return vim.fn.line("w0", layout.wins.transcript)
  end

  -- The top line when the last line is at the bottom row, as Neovim puts it
  -- with zb.
  local function bottom()
    return api.nvim_win_call(layout.wins.transcript, function()
      local view = vim.fn.winsaveview()
      vim.cmd("normal! Gzb")
      local line = vim.fn.line("w0")
      vim.fn.winrestview(view)
      return line
    end)
  end

  -- Lines that wrap to several rows, and short ones between them.
  local function fill(n)
    transcript.clear()
    for i = 1, n do
      transcript.notice("warn", ("word "):rep(i % 3 == 0 and 60 or 1) .. i)
    end
  end

  before_each(function()
    helpers.start()
    layout.focus_input({ insert = false })
  end)

  after_each(function()
    layout.focus_input({ insert = false })
    transcript.clear()
  end)

  it("follows new output at the end, leaves a view that the user scrolled up, and keeps no empty rows", function()
    fill(60)
    transcript.notice("warn", "more")
    assert.are.same(bottom(), top(), "new output follows the end")
    for _ = 1, 3 do
      scroll("<C-u>")
    end
    local up = top()
    assert(up < bottom())
    transcript.notice("warn", "more")
    assert.are.same(up, top(), "new output leaves a view that the user scrolled up")
    for _ = 1, 20 do
      scroll("<C-d>")
    end
    local lines = {}
    for i = 1, 12 do
      lines[i] = "  choice " .. i
    end
    local id = transcript.block(lines)
    assert.are.same(bottom(), top(), "the block shows at the bottom")
    transcript.remove_block(id)
    assert.are.same(bottom(), top(), "no empty rows where the block was")

    -- A view that hides the block's last line does not follow new output, but
    -- the block's lines still go from under it. More one-row lines than the
    -- window has rows end the text, so the view can fill.
    for _ = 1, 20 do
      transcript.notice("warn", "more")
    end
    id = transcript.block(lines)
    api.nvim_win_call(layout.wins.transcript, function()
      vim.cmd.normal({ vim.keycode("<C-y>"), bang = true })
    end)
    local win = layout.wins.transcript
    assert(vim.fn.line("w$", win) < api.nvim_buf_line_count(transcript.buf()), "the view hides the block's end")
    transcript.remove_block(id)
    local rows = api.nvim_win_text_height(win, { start_row = top() - 1 }).all
    assert.are.same(api.nvim_win_get_height(win), rows, "no empty rows after a block went from under the view")
    assert.are.same(bottom(), top())
  end)
end)
