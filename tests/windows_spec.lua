---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
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

local function showing(buf)
  return #vim.tbl_filter(function(win)
    return api.nvim_win_get_buf(win) == buf
  end, api.nvim_tabpage_list_wins(0))
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
  it("moves the cursor from the transcript on to the prompt", function()
    in_code()
    local code, tr, prompt = layout.wins.code, layout.wins.transcript, layout.wins.input
    assert.is_false(api.nvim_win_get_config(tr).focusable)
    vim.cmd("normal! H")
    vim.cmd.wincmd("l")
    assert.are.same(prompt, current(), "<C-w>l from the top row")
    vim.cmd.wincmd("p")
    assert.are.same(code, current(), "<C-w>p goes back to the code window")
    vim.cmd.wincmd("p")
    vim.cmd.wincmd("k")
    assert.are.same(prompt, current(), "<C-w>k from the prompt stays there")
    vim.cmd.wincmd("p")
    assert.are.same(code, current(), "and keeps the previous window")
    vim.cmd("normal! L")
    vim.cmd.wincmd("l")
    assert.are.same(prompt, current(), "<C-w>l from the bottom row")
    vim.cmd.wincmd("h")
    assert.are.same(code, current())
    vim.cmd.wincmd("w")
    assert.are.same(prompt, current(), "<C-w>w skips the transcript")
    vim.cmd.stopinsert()
    keys("<C-w>W")
    assert.are.same(code, current(), "<C-w>W from the prompt skips the transcript")
    vim.cmd.wincmd("l")
    api.nvim_set_current_win(tr)
    assert.are.same(prompt, current(), "the API cannot enter it either")
    vim.cmd.wincmd("h")
    windows.read()
    keys("q")
    assert.are.same(prompt, current())
    vim.cmd.wincmd("p")
    assert.are.same(code, current(), "<C-w>p after read mode goes to the window before the prompt")
  end)

  it("lets the cursor into the transcript in read mode, until it leaves", function()
    helpers.start()
    layout.focus_input()
    local tr, prompt = layout.wins.transcript, layout.wins.input
    transcript.notice("warn", "something to yank")
    for _, key in ipairs({ "q", "<Esc>", unpack(layout.insert_keys) }) do
      -- Without a main loop, the prompt's :startinsert stays pending and eats the keys.
      vim.cmd.stopinsert()
      keys("<leader>cr")
      assert.are.same(tr, current(), "<leader>cr")
      assert(vim.w[tr].anvim_read, "read mode is on")
      keys(key)
      assert.are.same(prompt, current(), key .. " goes back to the prompt")
      assert.is_nil(vim.w[tr].anvim_read, "read mode is off")
    end
    vim.cmd.AnvimTranscript()
    assert.are.same(tr, current(), ":AnvimTranscript")
    keys("Gyy")
    assert.are.same("⚠ something to yank\n", vim.fn.getreg('"'))
    vim.cmd.wincmd("h")
    assert.is_nil(vim.w[tr].anvim_read, "leaving the window ends read mode")
    vim.cmd.wincmd("l")
    assert.are.same(prompt, current(), "so the next move skips the transcript")
  end)

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

  it("keeps help, quickfix and terminal windows, and closes copies of its own", function()
    in_code()
    vim.cmd("help help")
    local help = current()
    settle()
    assert(api.nvim_win_is_valid(help), "the help window closed")
    vim.cmd.close()
    vim.cmd.copen()
    local qf = current()
    settle()
    assert(api.nvim_win_is_valid(qf), "the quickfix window closed")
    vim.cmd.cclose()
    -- A terminal buffer without a process, as Claude's sandbox opens no pty.
    vim.cmd.split()
    local term = current()
    local tbuf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(term, tbuf)
    api.nvim_open_term(tbuf, {})
    settle()
    assert(api.nvim_win_is_valid(term), "the terminal window closed")
    vim.cmd("bdelete!")

    layout.focus_input()
    vim.cmd.split()
    settle()
    assert.are.same(1, showing(input.buf()), "a copy of the prompt stays open")
    assert.are.same(layout.wins.input, current())
    windows.read()
    vim.cmd.vsplit()
    settle()
    assert.are.same(1, showing(transcript.buf()), "a copy of the transcript stays open")
    assert.are.same(layout.wins.input, current())
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
      assert.are.same(3, api.nvim_win_get_height(layout.wins.input), what .. ": the prompt fits its text")
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

  it("follows new output only while the end of the transcript is in view", function()
    helpers.start()
    layout.focus_input()
    local tr = layout.wins.transcript
    local function at_end()
      return vim.fn.line("w$", tr) == api.nvim_buf_line_count(transcript.buf())
    end
    for i = 1, 60 do
      transcript.notice("warn", "line " .. i)
    end
    assert(at_end(), "the view follows new output")
    windows.scroll("<C-u>")
    local top = vim.fn.line("w0", tr)
    assert(not at_end(), "<C-u> scrolls up")
    transcript.notice("warn", "more")
    assert.are.same(top, vim.fn.line("w0", tr), "new output leaves a scrolled view alone")
    for _ = 1, 20 do
      windows.scroll("<C-d>")
    end
    assert(at_end(), "<C-d> scrolls to the end")
    transcript.notice("warn", "more")
    assert(at_end(), "following resumes at the end")
    windows.scroll("<C-b>")
    assert(not at_end(), "<C-b> scrolls up")
    transcript.user("a new prompt")
    assert(at_end(), "a new prompt brings the view back to the end")
  end)

  it("scrolls the transcript from the prompt", function()
    helpers.start()
    layout.focus_input()
    vim.cmd.stopinsert()
    local keymaps =
      { n = { "<C-u>", "<C-d>", "<C-b>", "<C-f>", "<PageUp>", "<PageDown>" }, i = { "<PageUp>", "<PageDown>" } }
    for mode, list in pairs(keymaps) do
      for _, key in ipairs(list) do
        local map = vim.fn.maparg(key, mode, false, true)
        local want = { desc = "Scroll the transcript", buffer = 1 }
        assert.are.same(want, { desc = map.desc, buffer = map.buffer }, mode .. " " .. key)
      end
    end
    local tr = layout.wins.transcript
    local top = vim.fn.line("w0", tr)
    keys("<C-u>")
    local up = vim.fn.line("w0", tr)
    assert(up < top, "<C-u> from the prompt scrolls the transcript")
    assert.are.same(layout.wins.input, current(), "and the cursor stays in the prompt")
    keys("<PageDown>")
    assert(vim.fn.line("w0", tr) > up, "<PageDown> from the prompt scrolls the transcript down")
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

  it("repairs the layout after a :q that fails", function()
    helpers.start()
    layout.focus_input()
    -- :q runs QuitPre, which closes the other windows. A scheduled check runs
    -- while the quit is still under way, and a quit that fails reaches SafeState.
    api.nvim_exec_autocmds("QuitPre", {})
    assert(not api.nvim_win_is_valid(layout.wins.transcript), "QuitPre left the transcript open")
    vim.wait(50)
    api.nvim_exec_autocmds("SafeState", {})
    assert(
      vim.wait(500, function()
        return api.nvim_win_is_valid(layout.wins.code) and api.nvim_win_is_valid(layout.wins.transcript)
      end, 10),
      "the layout stayed broken"
    )
    layout.focus_input()
  end)

  it("rebuilds the prompt and the transcript after :bwipeout and :bdelete", function()
    local function has_map(buf, mode, lhs)
      for _, map in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
        if map.lhs == lhs then
          return true
        end
      end
      return false
    end
    for _, cmd in ipairs({ "bwipeout!", "bdelete!" }) do
      for _, case in ipairs({
        {
          enter = layout.focus_input,
          buf = input.buf,
          role = "input",
          ft = "anvim_input",
          maps = { i = "<CR>", n = "<LeftDrag>" },
        },
        {
          enter = windows.read,
          buf = transcript.buf,
          role = "transcript",
          ft = "anvim_transcript",
          maps = { n = "q" },
        },
      }) do
        helpers.start()
        vim.cmd.stopinsert()
        case.enter()
        local old = case.buf()
        vim.cmd(cmd)
        local what = cmd .. " in the " .. case.role
        assert(
          vim.wait(500, function()
            local win = layout.wins[case.role]
            return api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == case.buf() and case.buf() ~= old
          end, 10),
          what .. " left no new buffer in its window"
        )
        local buf = case.buf()
        assert.are.same({ case.ft, "nofile" }, { vim.bo[buf].filetype, vim.bo[buf].buftype }, what)
        for mode, lhs in pairs(case.maps) do
          assert(has_map(buf, mode, lhs), ("%s lost the %s map %s"):format(what, mode, lhs))
        end
      end
    end
    layout.focus_input()
  end)
end)
