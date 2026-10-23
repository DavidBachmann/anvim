---@module "luassert"

local completion = require("anvim.completion")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")

-- The start column and the items for a line before the cursor. The file list
-- comes from a process, so file items can come later.
---@return integer start, table[] items
local function complete(line, row, manual)
  local start, items
  vim.wait(3000, function()
    start, items = select(2, completion.items((row or 1) - 1, line, manual))
    return #items > 0 or completion.context((row or 1) - 1, line) ~= "file"
  end)
  return start, items
end

local function by_abbr(items)
  local out = {}
  for _, item in ipairs(items) do
    out[item.abbr or item.word] = item
  end
  return out
end

describe("completion", function()
  it("offers files and directories after @, and words after an @ in a mail address", function()
    helpers.start()
    vim.fn.mkdir(helpers.tmp .. "/comp/sub", "p")
    vim.fn.writefile({ "return 1" }, helpers.tmp .. "/comp/a.lua")
    vim.fn.writefile({ "return 2" }, helpers.tmp .. "/comp/sub/b.lua")
    -- As after Claude made the files: the turn ends, and a list that the
    -- prompt made earlier is old enough to be made again.
    local fresh = completion.fresh_ms
    completion.fresh_ms = 0
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })

    local start, list = complete("look at @comp/")
    local items = by_abbr(list)
    assert.are.same(8, start)
    assert.are.same({ "comp/a.lua", "comp/sub/", "comp/sub/b.lua" }, vim.fn.sort(vim.tbl_keys(items)))
    -- Shallow paths first.
    assert.are.same(
      { "comp/a.lua", "comp/sub/", "comp/sub/b.lua" },
      vim.tbl_map(function(item)
        return item.abbr
      end, list)
    )
    assert.are.same("@comp/a.lua ", items["comp/a.lua"].word)
    assert.are.same(1, items["comp/a.lua"].equal)
    -- A directory goes on to its files, so it ends without a space.
    assert.are.same("@comp/sub/", items["comp/sub/"].word)
    assert.are.same("dir", items["comp/sub/"].user_data.anvim)

    -- The query matches fuzzily, in either case.
    assert.are.same(
      { "comp/sub/b.lua" },
      vim.tbl_map(function(item)
        return item.abbr
      end, select(2, complete("@comp/sub/B")))
    )
    assert(by_abbr(select(2, complete("@")))["matchparen.lua"], "the whole project after a lone @")
    assert.is_nil(completion.context(0, "mail me@comp"))
    start, list = complete("mail me@comp")
    assert.are.same(#"mail me@", start)
    for _, item in ipairs(list) do
      assert(not item.word:find("^@"), item.word)
    end
    completion.fresh_ms = fresh
  end)

  it("offers slash commands with their descriptions at the start of the prompt only", function()
    helpers.start()
    sidecar.dispatch({
      type = "commands",
      commands = {
        { name = "review", description = "Review a pull request", argument_hint = "<pr>" },
        { name = "compact", description = "" },
      },
    })
    local start, list = complete("/")
    local items = by_abbr(list)
    -- anvim runs /model, /resume and /effort itself, and adds them.
    assert.are.same(0, start)
    assert.are.same({ "/compact", "/effort", "/model", "/resume", "/review" }, vim.fn.sort(vim.tbl_keys(items)))
    assert.are.same("/review ", items["/review"].word)
    assert.are.same("Review a pull request", items["/review"].menu)
    assert.are.same("Review a pull request\n\n/review <pr>", items["/review"].info)
    assert.are.same({ anvim = "command", send = false }, items["/review"].user_data)
    assert.is_nil(items["/compact"].menu)
    assert.is_true(items["/compact"].user_data.send)
    -- The typed name filters the list.
    assert.are.same({ "/resume", "/review" }, vim.fn.sort(vim.tbl_keys(by_abbr(select(2, complete("/re"))))))
    for _, case in ipairs({ { "say /re" }, { "/re", 2 } }) do
      for _, item in ipairs(select(2, complete(case[1], case[2]))) do
        assert(not item.word:find("^/"), item.word)
      end
    end
  end)
end)
