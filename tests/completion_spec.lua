---@module "luassert"

local completion = require("anvim.completion")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")

local source = completion.new()

---@return table response
local function complete(line, row)
  local got
  source:get_completions({ line = line, cursor = { row or 1, #line } }, function(response)
    got = response
  end)
  assert(
    vim.wait(3000, function()
      return got ~= nil
    end),
    "no completions for " .. line
  )
  return got
end

local function by_label(items)
  local out = {}
  for _, item in ipairs(items) do
    out[item.label] = item
  end
  return out
end

describe("completion", function()
  it("offers files and directories after @, and nothing for a mail address", function()
    helpers.start()
    vim.fn.mkdir(helpers.tmp .. "/comp/sub", "p")
    vim.fn.writefile({ "return 1" }, helpers.tmp .. "/comp/a.lua")
    vim.fn.writefile({ "return 2" }, helpers.tmp .. "/comp/sub/b.lua")
    assert(source:get_trigger_characters()[1] == "@")

    local items = by_label(complete("look at @comp/").items)
    assert.are.same({ "comp/a.lua", "comp/sub/", "comp/sub/b.lua" }, vim.fn.sort(vim.tbl_keys(items)))
    assert.are.same({
      newText = "@comp/a.lua ",
      range = { start = { line = 0, character = 8 }, ["end"] = { line = 0, character = 14 } },
    }, items["comp/a.lua"].textEdit)
    assert.are.same("a.lua", items["comp/a.lua"].filterText)
    -- A directory goes on to its files, so it ends without a space.
    assert.are.same("@comp/sub/", items["comp/sub/"].textEdit.newText)

    assert(by_label(complete("@").items)["matchparen.lua"], "the whole project after a lone @")
    assert.are.same({}, complete("mail me@comp").items)
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
    local items = by_label(complete("/re").items)
    -- anvim runs /model, /resume and /effort itself, and adds them.
    assert.are.same({ "/compact", "/effort", "/model", "/resume", "/review" }, vim.fn.sort(vim.tbl_keys(items)))
    assert.are.same({
      newText = "/review ",
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
    }, items["/review"].textEdit)
    assert.are.same({ description = "Review a pull request" }, items["/review"].labelDetails)
    assert.are.same("review", items["/review"].filterText)
    assert.is_nil(items["/compact"].labelDetails)
    assert.are.same({}, complete("say /re").items)
    assert.are.same({}, complete("/re", 2).items)
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

    local labels = vim.tbl_map(function(item)
      return item.label
    end, complete("/").items)
    assert.are.same(
      { "/__remote-workflow", "/color", "/doctor", "/ultrareview" },
      vim.tbl_filter(function(label)
        return not vim.tbl_contains(labels, label)
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
    local items = by_label(complete("/").items)
    assert.are.same({ true, true }, { items["/model"].data.send, items["/effort"].data.send })
    assert.are.same("Choose Claude's model", items["/model"].labelDetails.description)

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

  it("leaves out the other providers in a reference or a slash command", function()
    helpers.start()
    local win = require("anvim.layout").wins.input
    local buf = require("anvim.input").buf()
    vim.api.nvim_set_current_win(win)
    vim.cmd.stopinsert()
    for line, want in pairs({
      ["see @lua/an"] = { "anvim" },
      ["/rev"] = { "anvim" },
      ["see lua"] = { "anvim", "path", "buffer" },
      ["me@lua"] = { "anvim", "path", "buffer" },
    }) do
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      vim.api.nvim_win_set_cursor(win, { 1, #line })
      assert.are.same(want, completion.providers(), line)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  end)
end)
