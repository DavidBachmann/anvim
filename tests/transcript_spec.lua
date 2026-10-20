---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

describe("transcript", function()
  it("renders a replayed turn like Claude Code", function()
    helpers.start()
    layout.focus_input()
    input.send("Add a comment")
    assert(state.busy, "busy right after send")
    assert(input.activity():find("Working"), "activity line shows the spinner")
    local footer = vim.tbl_map(function(chunk)
      return chunk[1]
    end, input.footer(80))
    assert(table.concat(footer):find("bypass permissions"), "footer shows the mode")
    assert(
      vim.wait(10000, function()
        return not state.busy
      end),
      "turn did not end"
    )
    -- Other specs can write to the transcript first, so the turn starts at its prompt.
    local all = helpers.buf_lines(transcript.buf())
    local idx = vim.fn.index(all, "❯ Add a comment")
    assert(idx >= 0, "prompt line missing")
    assert(idx == 0 or (all[idx] == "" and all[idx - 1] ~= ""), "one blank line before the prompt, or none at the top")
    local out = vim.list_slice(all, idx + 1)
    helpers.contains(out, "^⏺ Read%(matchparen%.lua%)$")
    helpers.contains(out, "^  ⎿  Read %d+ lines$")
    helpers.contains(out, "^⏺ Edit%(matchparen%.lua%)$")
    helpers.contains(out, "^  ⎿  Added %d+ lines?, removed %d+ lines?$")
    helpers.contains(out, "^⏺ %a")
    assert.are.same("Opus 5.5", input.model_label(state.model))
    assert(not vim.bo[transcript.buf()].modifiable, "transcript is read-only")
    assert.are.same(
      vim.fn.bufnr(helpers.tmp .. "/matchparen.lua"),
      vim.api.nvim_win_get_buf(layout.wins.code),
      "code window followed"
    )
  end)
end)
