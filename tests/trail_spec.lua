---@module "luassert"

local helpers = require("helpers")
local layout = require("anvim.layout")
local trail = require("anvim.trail")

local api = vim.api

-- Feeds the tool events of a recording to the trail, as the sidecar would.
local function replay(path)
  for _, frame in ipairs(vim.fn.readfile(path)) do
    local ev =
      vim.json.decode(frame:match("^%d+ (.*)$"):gsub("/ANVIM_FIXTURE", helpers.tmp), { luanil = { object = true } })
    if ev.type == "tool_use" then
      trail.tool_use(ev)
    elseif ev.type == "tool_result" then
      trail.tool_result(ev)
    end
  end
end

local function find(items, what, where)
  for i, item in ipairs(items) do
    if item.what == what and item.where == where then
      return i, item
    end
  end
  error(("no %s %s in:\n%s"):format(
    what,
    where,
    vim.inspect(vim.tbl_map(function(it)
      return it.text
    end, items))
  ))
end

describe("trail", function()
  it("lists what Claude read, edited and showed, and the user's references, newest first", function()
    helpers.start()
    local stream = helpers.tmp .. "/lua/anvim/stream.lua"
    vim.fn.mkdir(vim.fs.dirname(stream), "p")
    local lines = {}
    for i = 1, 220 do
      lines[i] = ("-- line %d"):format(i)
    end
    vim.fn.writefile(lines, stream)

    replay(helpers.recording)
    replay(helpers.root .. "/tests/fixtures/editor-tools.jsonl")
    trail.prompt(
      "see @matchparen.lua#L3-5, @nope.lua and @lua/anvim/stream.lua",
      helpers.tmp .. "/matchparen.lua",
      { start_line = 10, end_line = 12 }
    )

    local items = trail.items()
    local you_file = find(items, "You", "lua/anvim/stream.lua")
    local you_ref = find(items, "You", "matchparen.lua#L3-5")
    local you_sel = find(items, "You", "matchparen.lua#L10-12")
    local show, shown = find(items, "Show", "lua/anvim/stream.lua#L189-205")
    local edit, edited = find(items, "Edit", "matchparen.lua#L9")
    local read = find(items, "Read", "matchparen.lua")
    assert(you_file < you_ref and you_ref < you_sel and you_sel < show and show < edit and edit < read, "newest first")
    assert(shown.note:find("^The only real use of take"), shown.note)
    assert.are.same({ { 9, 0 }, { 9, #vim.fn.readfile(helpers.tmp .. "/matchparen.lua")[9] } }, {
      edited.pos,
      edited.end_pos,
    })
    for _, item in ipairs(items) do
      assert(not item.file:find("nope", 1, true), "a reference to a missing file")
    end

    -- Each place once, at its newest.
    trail.tool_use({ id = "r2", name = "Read", input = { file_path = helpers.tmp .. "/matchparen.lua" } })
    items = trail.items()
    assert.are.same(1, find(items, "Read", "matchparen.lua"))
    local reads = vim.tbl_filter(function(it)
      return it.text == "Read matchparen.lua"
    end, items)
    assert.are.same(1, #reads)
  end)

  it("opens a place in the code window", function()
    helpers.start()
    vim.cmd.stopinsert()
    local file = helpers.tmp .. "/matchparen.lua"
    -- The flash of another spec's read of the file can still show.
    local ns = api.nvim_create_namespace("anvim.follow")
    local buf = vim.fn.bufnr(file)
    if buf > 0 then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    trail.open({ file = file, pos = { 12, 0 }, end_pos = { 14, 3 } })
    local win = layout.wins.code
    assert.are.same(win, api.nvim_get_current_win())
    assert.are.same(file, api.nvim_buf_get_name(api.nvim_win_get_buf(win)))
    assert.are.same(12, api.nvim_win_get_cursor(win)[1])
    local flashed = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(api.nvim_win_get_buf(win), ns, 0, -1, { details = true })) do
      if mark[4].line_hl_group == "AnvimRead" then
        flashed[#flashed + 1] = mark[2] + 1
      end
    end
    assert.are.same({ 12, 13, 14 }, flashed)
    layout.focus_input()
    vim.cmd.stopinsert()
  end)
end)
