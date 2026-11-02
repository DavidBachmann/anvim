---@module "luassert"

local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local summary = table.concat({
  "1. Primary Request and Intent:",
  "   Fix the parser.",
  "",
  "2. Key Technical Concepts:",
  "   - Lua patterns",
  "   - Extmarks",
  "",
  "3. Files and Code Sections (in order):",
  "   - parser.lua",
  "",
  "7. Pending Tasks:",
  "   - None.",
  "",
  "8. Current Work:",
  "   The parser test.",
  "",
  "9. OPTIONAL NEXT STEP:",
  "   Run the tests.",
}, "\n")

local function summary_lines()
  local all = helpers.buf_lines(transcript.buf())
  local idx = vim.fn.match(all, "^✻ Conversation compacted")
  assert(idx >= 0, table.concat(all, "\n"))
  return vim.list_slice(all, idx + 2)
end

describe("a compaction summary", function()
  before_each(helpers.fresh)
  after_each(function()
    transcript.set_verbose(false)
  end)

  it("shows the sections about the next steps in full, folds the others, and shows all in verbose mode", function()
    sidecar.dispatch({ type = "compact", trigger = "auto", pre_tokens = 180000, post_tokens = 12000 })
    sidecar.dispatch({ type = "compact_summary", text = summary })
    transcript.notice("info", "After")
    local folded = {
      "  ⎿  1. Primary Request and Intent:",
      "        Fix the parser.",
      "",
      "     2. Key Technical Concepts · 2 lines",
      "     3. Files and Code Sections (in order) · 1 line",
      "",
      "     7. Pending Tasks:",
      "        - None.",
      "",
      "     8. Current Work:",
      "        The parser test.",
      "",
      "     9. OPTIONAL NEXT STEP:",
      "        Run the tests.",
      "",
      "✻ After",
    }
    assert.are.same(folded, summary_lines())
    local groups = helpers.hl_groups(transcript.buf(), "anvim.transcript")
    assert(groups.AnvimSummary, vim.inspect(groups))

    transcript.set_verbose(true)
    local lines = summary_lines()
    assert.are.same("     2. Key Technical Concepts:", lines[4])
    assert.are.same("        - Extmarks", lines[6])
    assert.are.same("✻ After", lines[#lines])

    transcript.set_verbose(false)
    assert.are.same(folded, summary_lines())
  end)

  it("reads bold titles, with or without a colon", function()
    sidecar.dispatch({ type = "compact", trigger = "auto", pre_tokens = 180000, post_tokens = 12000 })
    sidecar.dispatch({
      type = "compact_summary",
      text = "1. **Primary request and intent**\n   Fix it.\n\n2. **Key Technical Concepts:**\n   - Lua\n\n9. **Optional Next Step**:\n   Test it.",
    })
    assert.are.same({
      "  ⎿  1. Primary request and intent:",
      "        Fix it.",
      "",
      "     2. Key Technical Concepts · 1 line",
      "",
      "     9. Optional Next Step:",
      "        Test it.",
    }, summary_lines())
  end)

  it("shows text that does not start with a numbered section title whole", function()
    sidecar.dispatch({ type = "compact", trigger = "auto", pre_tokens = 180000, post_tokens = 12000 })
    sidecar.dispatch({
      type = "compact_summary",
      text = "## Session summary\n1. `parser.lua`:\n- Fixed the parser.\n\nNext: run the tests.",
    })
    assert.are.same({
      "  ⎿  ## Session summary",
      "     1. `parser.lua`:",
      "     - Fixed the parser.",
      "",
      "     Next: run the tests.",
    }, summary_lines())
  end)
end)
