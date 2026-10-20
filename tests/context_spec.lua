---@module "luassert"

local context = require("anvim.context")
local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local refs = require("anvim.refs")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local api = vim.api
local file = helpers.tmp .. "/context.lua"
local other = helpers.tmp .. "/other.lua"

local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "mxt", false)
end

-- The code window shows the file, in normal mode, with nothing pinned.
---@return integer buf
local function in_code()
  helpers.start()
  if not vim.uv.fs_stat(file) then
    local lines = {}
    for i = 1, 40 do
      lines[i] = ("local v%d = %d"):format(i, i)
    end
    lines[5] = "local é = 'aé'"
    vim.fn.writefile(lines, file)
    vim.fn.writefile({ "return 1" }, other)
  end
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.wins.code)
  vim.cmd.edit(file)
  context.clear()
  feed("gg")
  return api.nvim_get_current_buf()
end

local function marks(buf)
  local ns = api.nvim_get_namespaces()["anvim.context"]
  return vim.tbl_map(function(m)
    return { m[2], m[3], m[4].end_row, m[4].end_col, m[4].hl_group }
  end, api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

local function footer(width)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, input.footer(width or 72)))
end

local function prompt(lines)
  if lines then
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, lines)
  end
  return api.nvim_buf_get_lines(input.buf(), 0, -1, false)
end

-- Moves the cursor in the code window and fires CursorMoved, which a spec
-- run gets only from a main loop.
local function moved(keys)
  feed(keys)
  api.nvim_exec_autocmds("CursorMoved", {})
end

describe("context", function()
  after_each(function()
    context.clear()
    state.waiting = nil
    state.branch = nil
  end)

  it("pins the selection of each visual mode when visual mode ends", function()
    local buf = in_code()
    feed("2GVjj<Esc>")
    local sel = context.selection()
    assert.are.same(
      { start_line = 2, end_line = 4, mode = "line", text = "local v2 = 2\nlocal v3 = 3\nlocal v4 = 4" },
      { start_line = sel.start_line, end_line = sel.end_line, mode = sel.mode, text = sel.text }
    )
    -- One mark that ends where the next line starts, so that 'hl_eol' covers the last line.
    assert.are.same({ { 1, 0, 4, 0, "AnvimSelection" } }, marks(buf))
    assert(footer():find("⧉ 3 lines selected", 1, true), footer())
    -- In a narrow column, the mode label gets short, so that the chip stays.
    local narrow = footer(55)
    assert(narrow:find("⧉ 3 lines selected", 1, true), narrow)
    assert(narrow:find("⏵⏵ bypass $"), narrow)
    assert.are.same(55, api.nvim_strwidth(narrow), narrow)

    feed("2G0wvjl<Esc>")
    sel = context.selection()
    assert.are.same({ "char", "v2 = 2\nlocal v3" }, { sel.mode, sel.text })
    assert.are.same({ { 1, 6, 2, 8, "AnvimSelection" } }, marks(buf))

    feed("2G0w<C-v>jjl<Esc>")
    sel = context.selection()
    assert.are.same({ "block", "v2\nv3\nv4" }, { sel.mode, sel.text })
    assert.are.same({
      { 1, 6, 1, 8, "AnvimSelection" },
      { 2, 6, 2, 8, "AnvimSelection" },
      { 3, 6, 3, 8, "AnvimSelection" },
    }, marks(buf))

    -- The highlight covers a multibyte character whole.
    feed("5G0wv<Esc>")
    assert.are.same("é", context.selection().text)
    assert.are.same({ { 4, 6, 4, 8, "AnvimSelection" } }, marks(buf))
    assert(footer():find("⧉ 1 line selected", 1, true), footer())
  end)

  it("takes each line of a block to its end after $, and skips lines that end before the block", function()
    in_code()
    local path = helpers.tmp .. "/block.lua"
    vim.fn.writefile({ "abcdefgh", "ab", "abcdefghijkl" }, path)
    vim.cmd.edit(path)
    local buf = api.nvim_get_current_buf()
    feed("1G06l<C-v>jj$<Esc>")
    assert.are.same("gh\n\nghijkl", context.selection().text)
    assert.are.same({ { 0, 6, 0, 8, "AnvimSelection" }, { 2, 6, 2, 12, "AnvimSelection" } }, marks(buf))
    feed("1G06l<C-v>jjl<Esc>")
    assert.are.same("gh\n\ngh", context.selection().text)
    assert.are.same({ { 0, 6, 0, 8, "AnvimSelection" }, { 2, 6, 2, 8, "AnvimSelection" } }, marks(buf))
    vim.cmd.edit(file)
  end)

  it("sends the start of a long selection, with its true lines and one highlight", function()
    in_code()
    local path = helpers.tmp .. "/long.lua"
    local lines = {}
    for i = 1, 5000 do
      lines[i] = ("local value_%05d = %d"):format(i, i)
    end
    vim.fn.writefile(lines, path)
    vim.cmd.edit(path)
    local buf = api.nvim_get_current_buf()
    feed("ggVG<Esc>")
    local sel = context.selection()
    assert.are.same({ 1, 5000 }, { sel.start_line, sel.end_line })
    assert.are.same(2048, vim.fn.strchars(sel.text))
    assert(vim.startswith(sel.text, "local value_00001 = 1\n"), sel.text:sub(1, 40))
    assert.are.same(1, #marks(buf))
    feed("gg<C-v>G$<Esc>")
    assert.are.same(2048, vim.fn.strchars(context.selection().text))
    assert.are.same(500, #marks(buf), "a long block gets a highlight on its first lines only")
    context.clear()
    vim.cmd.edit(file)
    api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps the pin until the cursor moves, and not for scrolling or leaving the window", function()
    local buf = in_code()
    feed("2GVj<Esc>")
    for _, key in ipairs({ "<C-d>", "<C-u>", "<C-f>", "<C-b>", "<C-y>" }) do
      feed(key)
      api.nvim_win_set_cursor(0, { 6, 0 })
      api.nvim_exec_autocmds("CursorMoved", {})
      assert(context.selection(), key .. " dropped the pin")
    end
    -- Follow mode moves the code window while the user is in the prompt.
    api.nvim_set_current_win(layout.wins.input)
    vim.cmd.stopinsert()
    feed("v<Esc>")
    assert.are.same(buf, context.selection().buf, "visual mode in the prompt changed the pin")
    api.nvim_win_set_cursor(layout.wins.code, { 30, 0 })
    api.nvim_set_current_win(layout.wins.code)
    api.nvim_exec_autocmds("CursorMoved", {})
    assert(context.selection(), "coming back dropped the pin")
    moved("k")
    assert.is_nil(context.selection())
    assert.are.same({}, marks(buf))
    assert(footer():find("⧉ In context.lua", 1, true), footer())
  end)

  it("drops the pin for a new selection, another file, a reload, <Esc> and <C-x>", function()
    local buf = in_code()
    feed("2GVj<Esc>10Gv")
    assert.is_nil(context.selection(), "a new selection did not replace the pin")
    assert.are.same({}, marks(buf))
    feed("<Esc>")
    assert.are.same(10, context.selection().start_line)

    vim.cmd.edit(other)
    assert.is_nil(context.selection(), "another file kept the pin")
    vim.cmd.edit(file)

    feed("2GV<Esc>")
    vim.cmd("edit!")
    assert.is_nil(context.selection(), "a reload kept the pin")

    feed("2GV<Esc><Esc>")
    assert(
      vim.wait(500, function()
        return context.selection() == nil
      end),
      "<Esc> kept the pin"
    )

    feed("2GV<Esc>")
    api.nvim_set_current_win(layout.wins.input)
    vim.cmd.stopinsert()
    feed("<C-x>")
    assert.is_nil(context.selection(), "<C-x> kept the pin")
  end)

  it("sends what the code window shows with each prompt, and shows it under the prompt", function()
    in_code()
    feed("7G")
    local win = layout.wins.code
    local visible = { vim.fn.line("w0", win), vim.fn.line("w$", win) }
    helpers.capture_sends(function(sent)
      input.send("What does this file do?")
      feed("2GVjj<Esc>")
      -- Claude Code runs no hook for a slash command, and it keeps the pin.
      input.send("/compact")
      assert.are.same({ type = "prompt", text = "/compact" }, table.remove(sent))
      input.send("And this?")
      assert.is_nil(context.selection(), "the pin outlived its prompt")
      vim.cmd.enew()
      local empty = api.nvim_get_current_buf()
      input.send("No file")
      vim.cmd.edit(file)
      api.nvim_buf_delete(empty, { force = true })
      assert.are.same({
        type = "prompt",
        text = "What does this file do?",
        context = { file = "context.lua", cursor_line = 7, visible = visible },
      }, sent[1])
      assert.are.same({
        start_line = 2,
        end_line = 4,
        mode = "line",
        text = "local v2 = 2\nlocal v3 = 3\nlocal v4 = 4",
      }, sent[2].context.selection)
      assert.are.same({ type = "prompt", text = "No file" }, sent[3])
    end)
    input.set_busy(false)
    local lines = helpers.buf_lines(transcript.buf())
    local at = vim.fn.index(lines, "❯ What does this file do?")
    assert.are.same("  ⎿  ⧉ context.lua", lines[at + 2])
    at = vim.fn.index(lines, "❯ And this?")
    assert.are.same("  ⎿  ⧉ context.lua#L2-4", lines[at + 2])
    for _, prompt_line in ipairs({ "❯ No file", "❯ /compact" }) do
      at = vim.fn.index(lines, prompt_line)
      assert(at >= 0, prompt_line)
      assert.are_not.same("  ⎿", (lines[at + 2] or ""):sub(1, 5), prompt_line)
    end
  end)

  it("fits the chip into the footer: the hint goes first, then the branch, the long mode, then the chip", function()
    in_code()
    state.branch = "main"
    local w = api.nvim_strwidth
    for width, want in pairs({
      [100] = { "git:(main)", "⧉ In context.lua", "(shift+tab to cycle)", "⏵⏵ bypass permissions on" },
      [80] = { "git:(main)", "⧉ In context.lua", "⏵⏵ bypass permissions on" },
      [62] = { "⧉ In context.lua", "⏵⏵ bypass permissions on" },
      [58] = { "⧉ In context.lua" },
      [50] = { "⧉ In context.lua" },
      [43] = { "⧉ In contex..." },
      [30] = {},
    }) do
      local text = footer(width)
      for _, part in ipairs({
        "git:(main)",
        "⧉ In context.lua",
        "⧉ In contex...",
        "(shift+tab to cycle)",
        "⏵⏵ bypass permissions on",
      }) do
        assert.are.same(
          vim.tbl_contains(want, part),
          text:find(part, 1, true) ~= nil,
          ("%q at %d: %s"):format(part, width, text)
        )
      end
      assert(text:find("⏵⏵ bypass", 1, true), text)
      assert.are.same(width, w(text), text)
    end
    -- While Claude waits, the waiting text stays, and the chip goes if both do not fit.
    state.waiting = "Esc to deny"
    assert(footer(72):find("⧉ In context.lua  +⏺ Claude is waiting for you $"), footer(72))
    assert.are.same(" anvim Opus 5.5" .. (" "):rep(11) .. "⏺ Claude is waiting for you ", footer(54))
  end)

  it("inserts references with visual c, c{motion}, cc and a count, where typing stopped", function()
    in_code()
    prompt({ "" })
    feed("2GVjc")
    assert.are.same(layout.wins.input, api.nvim_get_current_win())
    assert.are.same({ "@context.lua#L2-3 " }, prompt())
    assert.is_nil(context.selection(), "the reference left the selection pinned")
    api.nvim_set_current_win(layout.wins.code)
    feed("5G2cc")
    api.nvim_set_current_win(layout.wins.code)
    feed("10Gcj")
    api.nvim_set_current_win(layout.wins.code)
    feed("20Gcc")
    assert.are.same({ "@context.lua#L2-3 @context.lua#L5-6 @context.lua#L10-11 @context.lua#L20 " }, prompt())

    prompt({ "why does fail?" })
    api.nvim_win_set_cursor(layout.wins.input, { 1, 9 })
    feed("i<Esc>")
    api.nvim_set_current_win(layout.wins.code)
    feed("3Gcc")
    assert.are.same({ "why does @context.lua#L3 fail?" }, prompt())
    assert.are.same({ 1, 25 }, api.nvim_buf_get_mark(input.buf(), "^"), "typing goes on after the reference")

    prompt({ "" })
    refs.files({ { path = file }, { path = helpers.tmp .. "/sub", dir = true } })
    vim.cmd.stopinsert()
    assert.are.same({ "@context.lua @sub/ " }, prompt())
    prompt({ "" })
  end)
end)
