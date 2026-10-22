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

  it("hides the built-ins that do nothing here, and keeps the rest", function()
    helpers.start()
    local state = require("anvim.state")
    local commands, terminal = completion.commands, completion.terminal
    sidecar.dispatch({
      type = "commands",
      commands = {
        { name = "color", description = "Set the prompt bar color", builtin = true },
        { name = "color", description = "A plugin's color, which Claude Code's own shadows" },
        { name = "doctor", description = "Check the setup", aliases = { "checkup" }, builtin = true },
        { name = "focus", description = "A user's own focus command", argument_hint = "[on|off]" },
        { name = "reload-plugins", description = "Activate pending plugin changes", builtin = true },
        { name = "__remote-workflow", description = "Run the workflow script", builtin = true },
        { name = "ultrareview", description = "Review the branch in the cloud", builtin = true },
        { name = "code-review", description = "Review the diff", argument_hint = "[level]", builtin = true },
        { name = "usage", description = "Show plan usage", aliases = { "cost", "stats" }, builtin = true },
        { name = "model", description = "Set the AI model for Claude Code", argument_hint = "<model>", builtin = true },
      },
    })
    -- Init names the terminal-bound built-ins. Without the list, none is.
    local function init(list)
      sidecar.dispatch({
        type = "init",
        session_id = state.session_id,
        model = state.model,
        permission_mode = state.permission_mode,
        slash_commands = {},
        terminal_slash_commands = list,
      })
    end
    init(nil)
    assert.are.same({}, completion.terminal)
    init({ "color", "doctor", "focus", "reload-plugins" })

    local items = by_abbr(completion.command_items(""))
    assert.are.same(
      { "/__remote-workflow", "/color", "/doctor", "/ultrareview" },
      vim.tbl_filter(function(label)
        return not items[label]
      end, {
        "/__remote-workflow",
        "/color",
        "/doctor",
        "/ultrareview",
        "/code-review",
        "/effort",
        "/focus",
        "/model",
        "/reload-plugins",
        "/usage",
      })
    )
    -- anvim's own /model takes the place of Claude Code's, so Enter sends it
    -- and opens the picker, as /effort does.
    assert.are.same({ true, true }, { items["/model"].user_data.send, items["/effort"].user_data.send })
    assert.are.same("Choose Claude's model", items["/model"].menu)

    assert.are.same("/color works only in Claude Code's terminal. Run `claude` for it.", completion.unusable("color"))
    assert.are.same(
      "/checkup works only in Claude Code's terminal. Run `claude` for it.",
      completion.unusable("checkup")
    )
    assert.are.same(
      "/__remote-workflow works only in sessions that a server launched.",
      completion.unusable("__remote-workflow")
    )
    local paid = "anvim starts no paid cloud review. Run /ultrareview or /code-review ultra in Claude Code."
    assert.are.same(paid, completion.unusable("ultrareview"))
    assert.are.same(paid, completion.unusable("code-review", " Ultra 42"))
    assert.is_nil(completion.unusable("code-review", "high"))
    for _, name in ipairs({ "focus", "reload-plugins", "usage", "cost", "review", "code-review", "nope" }) do
      assert.is_nil(completion.unusable(name), name)
    end
    completion.commands, completion.terminal = commands, terminal
  end)

  it("offers the words that start with the typed part, from the file buffers in the windows", function()
    helpers.start()
    -- The transcript is no file buffer, so its words never show.
    require("anvim.transcript").notice("info", "The zebrine zebroid")
    local path = helpers.tmp .. "/words.txt"
    vim.fn.writefile({ "The zebrafish swims past Zeb, and Davíð waves" }, path)
    local code = require("anvim.layout").code_win()
    local before = vim.api.nvim_win_get_buf(code)
    vim.api.nvim_win_call(code, function()
      vim.cmd.edit(path)
    end)
    local start, list = complete("a zeb")
    assert.are.same(2, start)
    assert.are.same(
      { "zebrafish", "Zeb" },
      vim.tbl_map(function(item)
        return item.word
      end, list)
    )
    assert.is_nil(list[1].menu)
    -- An upper case letter matches only itself.
    assert.are.same(
      { "Zeb" },
      vim.tbl_map(function(item)
        return item.word
      end, select(2, complete("a Ze")))
    )
    -- Words with letters past ASCII stay whole.
    start, list = complete("and dav")
    assert.are.same(#"and ", start)
    assert.are.same("Davíð", list[1].word)
    -- After a space, only <C-Space> asks for words.
    assert.are.same({}, select(2, complete("a ")))
    start, list = complete("a ", 1, true)
    assert.are.same(2, start)
    assert(#list > 0, "no words for <C-Space>")
    vim.api.nvim_win_set_buf(code, before)
  end)
end)
