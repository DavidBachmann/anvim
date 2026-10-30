---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

describe("transcript", function()
  it("wraps the lines of every bullet after the bullet", function()
    for _, bullet in ipairs({ "⏺", "❯", "⎿", "⚠", "✻" }) do
      assert.are.same(#bullet + 1, vim.fn.matchend(bullet .. " text", transcript.list_pat), bullet)
    end
  end)

  it("renders a replayed turn like Claude Code", function()
    helpers.start()
    layout.focus_input()
    input.send("Add a comment")
    assert(state.busy, "busy right after send")
    assert(input.activity():find("Working"), "activity line shows the spinner")
    local status = require("anvim.statusline").render()
    -- The session started in bypass mode, so the statusline shows no mode label.
    assert(not status:find("bypass", 1, true), status)
    assert(status:find("◉ following", 1, true), status)
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

  it("parses markdown in a plan, also once kept, and not in the choices of a question", function()
    helpers.start()
    local buf = transcript.buf()
    -- The first row of each markdown region, once the scheduled update ran.
    local function region_rows()
      vim.wait(50, function()
        return false
      end)
      return vim.tbl_map(function(region)
        return region[1][1]
      end, vim.treesitter.get_parser(buf):included_regions())
    end
    local question = transcript.block({ "  ❯ 1. [x] One", "    2. [ ] Two" }, {})
    local plan = transcript.block({ "  Claude's plan:", "  **Step**" }, {}, { markdown = true })
    local plan_row =
      vim.api.nvim_buf_get_extmark_by_id(buf, vim.api.nvim_create_namespace("anvim.transcript"), plan, {})[1]
    assert(vim.tbl_contains(region_rows(), plan_row), "the plan is not markdown")
    local question_row = plan_row - 3
    assert.are.same("  ❯ 1. [x] One", helpers.buf_lines(buf)[question_row + 1])
    assert(not vim.tbl_contains(region_rows(), question_row), "the question's choices are markdown")
    transcript.keep_block(plan)
    assert(vim.tbl_contains(region_rows(), plan_row), "the kept plan lost its markdown")
    transcript.remove_block(question)
  end)

  it("draws a table in Claude's text as a box that fits the window", function()
    helpers.fresh()
    local width = vim.api.nvim_win_get_width(layout.wins.transcript)
    local long = "de headline north means hardly increases, not unlikely to increase, so the fix keeps the pattern"
    transcript.text_start()
    transcript.text_delta("| Finding | My call |\n|---|---|\n| " .. long .. " | Take")
    local lines = helpers.buf_lines(transcript.buf())
    assert(vim.startswith(lines[1], "⏺ ┌"), "the header does not show as a box while the table streams")
    transcript.text_delta(" it. |\n| `short` | **Your call.** |")
    transcript.text_stop()
    lines = helpers.buf_lines(transcript.buf())
    local first, last
    for i, line in ipairs(lines) do
      assert(vim.api.nvim_strwidth(line) <= width, ("line %d is wider than the window: %s"):format(i, line))
      assert(not line:find("^%s*|"), "a markdown row stays: " .. line)
      first = first or (line:find("│ de headline", 1, true) and i)
      last = line:find("pattern", 1, true) and i or last
    end
    assert(first and last and last > first, "the long cell does not wrap:\n" .. table.concat(lines, "\n"))
    helpers.contains(lines, "^  │ short +│ Your")
    assert(transcript.last_reply():find("|---|", 1, true), "the reply to copy lost its markdown")
  end)

  it("draws a table in its own rows after rows above it grow", function()
    helpers.fresh()
    local buf = transcript.buf()
    transcript.text_start()
    transcript.text_delta("Intro\n| a | b |\n")
    -- A background agent's rows grow above the text while it streams.
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "agent row" })
    vim.bo[buf].modifiable = false
    transcript.text_delta("|---|---|\n| 1 | 2 |\n")
    transcript.text_stop()
    local lines = helpers.buf_lines(buf)
    helpers.contains(lines, "Intro")
    for _, line in ipairs(lines) do
      assert(not line:find("^%s*|"), "a markdown row stays:\n" .. table.concat(lines, "\n"))
    end
  end)

  it("keeps an underscore inside a word as text, also next to a digit", function()
    helpers.start()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Call hw_002 now, then hw_002's log. Then _this_ and **that**." })
    vim.treesitter.start(buf, "markdown")
    vim.treesitter.get_parser(buf):parse(true)
    local function has(col, capture)
      return vim.iter(vim.treesitter.get_captures_at_pos(buf, 0, col)):any(function(c)
        return c.capture == capture
      end)
    end
    assert.is_false(has(12, "markup.italic"), "the text between hw_002 and hw_002 is italic")
    assert.is_true(has(42, "markup.italic"), "_this_ is not italic")
    assert.is_true(has(54, "markup.strong"), "**that** is not bold")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
