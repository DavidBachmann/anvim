---@module "luassert"

local cheatsheet = require("anvim.cheatsheet")
local helpers = require("helpers")
local keys = require("anvim.keys")
local keyview = require("anvim.keyview")
local layout = require("anvim.layout")

local api = vim.api

-- The slash commands of the prompt's completion. The replays have no list of
-- Claude Code's commands, so the spec sends one with the built-in that the
-- sheet names, and anvim adds its own commands to it.
local function slash_commands()
  local completion = require("anvim.completion")
  local before = completion.commands
  require("anvim.sidecar").dispatch({
    type = "commands",
    commands = { { name = "clear", description = "Clear the conversation", builtin = true } },
  })
  local ret = {}
  for _, c in ipairs(completion.commands) do
    ret["/" .. c.name] = true
  end
  completion.commands = before
  return ret
end

describe("cheatsheet", function()
  it("opens with <leader>cc, names only real keys and commands, and q closes it", function()
    helpers.start()
    vim.cmd.stopinsert()
    api.nvim_set_current_win(layout.wins.code)
    local cursor = api.nvim_win_get_cursor(0)
    api.nvim_feedkeys(vim.keycode("<leader>cc"), "mxt", false)
    local win = keyview.win()
    assert.is_not_nil(win)
    assert.are.equal(win, api.nvim_get_current_win())
    assert.is_true(helpers.contains(helpers.buf_lines(api.nvim_win_get_buf(win)), "Talk to Claude"))

    -- Static and default entries count: the sheet names keys, not maps.
    local lhs, labels = {}, {}
    for _, place in ipairs(keys.places) do
      for _, key in ipairs(place.keys) do
        labels[keys.label(key)] = true
        for _, l in ipairs(keys.lhs(key)) do
          lhs[vim.keycode(l)] = true
        end
      end
    end
    local commands = slash_commands()
    local missing = {}
    for _, section in ipairs(cheatsheet.sections) do
      for _, row in ipairs(section[2]) do
        for _, key in ipairs(type(row[1]) == "table" and row[1] or { row[1] }) do
          local found
          if key:match("^/%l") then
            found = commands[key]
          else
            found = lhs[vim.keycode(key)] or labels[key]
          end
          if not found then
            missing[#missing + 1] = key
          end
        end
      end
    end
    assert.are.same({}, missing)

    api.nvim_feedkeys("q", "mxt", false)
    assert.is_nil(keyview.win())
    assert.are.equal(layout.wins.code, api.nvim_get_current_win())
    assert.are.same(cursor, api.nvim_win_get_cursor(0))
  end)
end)
