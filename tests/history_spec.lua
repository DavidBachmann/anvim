---@module "luassert"

local helpers = require("helpers")
local history = require("anvim.history")
local input = require("anvim.input")
local layout = require("anvim.layout")

local api = vim.api

local function keys(str)
  api.nvim_feedkeys(api.nvim_replace_termcodes(str, true, false, true), "mx", false)
end

local function prompt()
  return table.concat(api.nvim_buf_get_lines(input.buf(), 0, -1, false), "\n")
end

local function focus()
  api.nvim_set_current_win(layout.wins.input)
  vim.cmd.stopinsert()
end

-- Submits prompts the way <CR> does, without waiting for the turns. The
-- replay plays one recorded turn per prompt, so the specs stub the send.
local function submit_all(list)
  helpers.capture_sends(function()
    for _, text in ipairs(list) do
      api.nvim_buf_set_lines(input.buf(), 0, -1, false, vim.split(text, "\n"))
      input.submit()
    end
  end)
  input.set_busy(false)
end

describe("history", function()
  before_each(function()
    helpers.start()
    vim.fn.delete(history.dir, "rf")
    -- A submit forgets where the last spec left off.
    submit_all({ "reset" })
    vim.fn.delete(history.dir, "rf")
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("cycles with <Up> on the first line and <Down> on the last, and keeps the draft", function()
    focus()
    submit_all({ "first prompt", "second\nprompt on two lines", "third" })
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "my draft" })
    keys("A<Up>")
    assert.are.same("third", prompt())
    keys("A<Up>")
    assert.are.same("second\nprompt on two lines", prompt())
    -- The cursor ends on the first line, so the next <Up> goes back again.
    assert.are.same(1, api.nvim_win_get_cursor(0)[1])
    keys("A<Up>")
    assert.are.same("first prompt", prompt())
    keys("A<Up>")
    assert.are.same("first prompt", prompt(), "the oldest prompt stays")
    keys("A<Down>")
    assert.are.same("second\nprompt on two lines", prompt())
    -- <Down> lands on the last line, so the next <Down> comes forward again.
    assert.are.same(2, api.nvim_win_get_cursor(0)[1])
    keys("A<Down><Down>")
    assert.are.same("my draft", prompt(), "past the newest prompt, the draft comes back")
  end)

  it("moves inside a prompt of several lines before it goes back", function()
    focus()
    submit_all({ "older" })
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "line one", "line two" })
    api.nvim_win_set_cursor(0, { 2, 0 })
    keys("i<Up>")
    assert.are.same("line one\nline two", prompt(), "the first <Up> moves to the first line")
    assert.are.same(1, api.nvim_win_get_cursor(0)[1])
    keys("i<Up>")
    assert.are.same("older", prompt())
  end)

  it("<C-p> and <C-n> cycle in normal mode", function()
    focus()
    submit_all({ "one", "two" })
    keys("<C-p>")
    assert.are.same("two", prompt())
    keys("<C-p>")
    assert.are.same("one", prompt())
    keys("<C-n><C-n>")
    assert.are.same("", prompt())
  end)

  it("persists per directory, drops a repeat and keeps the last 200", function()
    submit_all({ "a", "a", "b" })
    local saved = vim.json.decode(table.concat(vim.fn.readfile(history.path()), "\n"))
    assert.are.same({ "a", "b" }, saved)
    local name = vim.fs.basename(history.path())
    assert(name:find("^" .. vim.pesc(vim.fs.basename(helpers.tmp)) .. "%-%x+%.json$"), name)
    local many = {}
    for i = 1, 205 do
      many[i] = "prompt " .. i
    end
    vim.fn.writefile({ vim.json.encode(many) }, history.path())
    submit_all({ "newest" })
    saved = vim.json.decode(table.concat(vim.fn.readfile(history.path()), "\n"))
    assert.are.same(200, #saved)
    assert.are.same("prompt 7", saved[1])
    assert.are.same("newest", saved[200])
  end)

  it("gives each directory its own file, also for paths that differ only in punctuation", function()
    local state = require("anvim.state")
    local cwd = state.cwd
    local names = {}
    for _, dir in ipairs({ "/a/b-c", "/a/b/c", "/a/b.c", "/a/b c", "/a/bä", "/a/bö", "/" .. ("x"):rep(300) }) do
      state.cwd = dir
      names[vim.fs.basename(history.path())] = true
      assert(#vim.fs.basename(history.path()) < 80, history.path())
    end
    state.cwd = cwd
    assert.are.same(7, vim.tbl_count(names))
  end)

  it("keeps a recalled prompt that the user changed as the draft", function()
    focus()
    submit_all({ "older", "newer" })
    keys("A<Up>")
    assert.are.same("newer", prompt())
    -- The user clears the recalled prompt and types their own.
    keys("ccmy own text<Up>")
    assert.are.same("newer", prompt(), "<Up> goes back again from the newest prompt")
    keys("A<Up>")
    assert.are.same("older", prompt())
    keys("A<Down><Down>")
    assert.are.same("my own text", prompt(), "the typed text came back as the draft")
  end)

  it("reads the file again, so two anvims in one directory keep both their prompts", function()
    submit_all({ "from this anvim" })
    local other = vim.json.decode(table.concat(vim.fn.readfile(history.path()), "\n"))
    other[#other + 1] = "from another anvim"
    vim.fn.writefile({ vim.json.encode(other) }, history.path())
    submit_all({ "again from this one" })
    local saved = vim.json.decode(table.concat(vim.fn.readfile(history.path()), "\n"))
    assert.are.same({ "from this anvim", "from another anvim", "again from this one" }, saved)
  end)
end)
