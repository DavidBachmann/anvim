---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local transcript = require("anvim.transcript")

local api = vim.api
local buf_lines = helpers.buf_lines

local function lines_from(text)
  local all = buf_lines(transcript.buf())
  local idx = vim.fn.index(all, text)
  assert(idx >= 0, ("no line %q in:\n%s"):format(text, table.concat(all, "\n")))
  return vim.list_slice(all, idx + 1)
end

-- The highlight groups of the transcript's extmarks on a line.
local function groups_at(row)
  local ns = api.nvim_get_namespaces()["anvim.transcript"]
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(transcript.buf(), ns, { row, 0 }, { row, -1 }, { details = true })) do
    out[#out + 1] = m[4].hl_group
  end
  return out
end

local function row_of(text)
  return vim.fn.index(buf_lines(transcript.buf()), text)
end

local next_id = 0
local function id()
  next_id = next_id + 1
  return "polish" .. next_id
end

local function todos(list)
  local tid = id()
  transcript.tool_start(tid, "TodoWrite")
  transcript.tool_use({ id = tid, name = "TodoWrite", input = { todos = list }, parent_id = nil })
  transcript.tool_result({ id = tid, is_error = false, text = "Todos have been modified successfully." })
end

local function item(content, status)
  return { content = content, status = status, activeForm = content:gsub("^%a+", "%0ing") }
end

describe("transcript polish", function()
  before_each(function()
    helpers.start()
    transcript.clear()
  end)

  after_each(function()
    transcript.turn_end()
    transcript.clear()
  end)

  it("keeps the todo list last while it has open items, and updates it in place", function()
    transcript.user("Do three steps")
    todos({
      item("Count the lines", "in_progress"),
      item("List the files", "pending"),
      item("Add a comment", "pending"),
    })
    local list = {
      "⏺ Todos · 0 of 3 done",
      "  ⎿  ☐ Count the lines",
      "     ☐ List the files",
      "     ☐ Add a comment",
    }
    assert.are.same(vim.list_extend({ "❯ Do three steps", "" }, list), lines_from("❯ Do three steps"))
    assert.are.same("Counting the lines", transcript.todo_active())
    input.set_busy(true)
    assert(input.activity():find("Counting the lines...", 1, true), input.activity())
    input.set_busy(false)

    -- New output goes above the list.
    transcript.text_delta("Counting now.")
    transcript.text_stop()
    local bash = id()
    transcript.tool_start(bash, "Bash")
    transcript.tool_use({ id = bash, name = "Bash", input = { command = "wc -l notes.lua" }, parent_id = nil })
    transcript.tool_result({ id = bash, is_error = false, text = "16 notes.lua" })
    todos({
      item("Count the lines", "completed"),
      item("List the files", "in_progress"),
      item("Add a comment", "pending"),
    })
    local updated = {
      "⏺ Todos · 1 of 3 done",
      "  ⎿  ☒ Count the lines",
      "     ☐ List the files",
      "     ☐ Add a comment",
    }
    assert.are.same(
      vim.list_extend({
        "❯ Do three steps",
        "",
        "⏺ Counting now.",
        "",
        "⏺ Bash(wc -l notes.lua)",
        "  ⎿  16 notes.lua",
        "",
      }, updated),
      lines_from("❯ Do three steps")
    )
    assert(vim.tbl_contains(groups_at(row_of("  ⎿  ☒ Count the lines")), "AnvimTodoDone"))
    assert(vim.tbl_contains(groups_at(row_of("     ☐ List the files")), "AnvimTodoActive"))

    -- The next prompt goes above it too, as the list waits under the spinner.
    transcript.turn_end()
    transcript.user("Go on")
    local all = buf_lines(transcript.buf())
    assert.are.same(updated, vim.list_slice(all, #all - 3))
    assert.are.same("❯ Go on", all[#all - 5])

    -- Once all are done, the list stays where it is, and new output follows it.
    todos({
      item("Count the lines", "completed"),
      item("List the files", "completed"),
      item("Add a comment", "completed"),
    })
    transcript.text_delta("All done.")
    all = buf_lines(transcript.buf())
    assert.are.same(
      { "⏺ Todos · 3 of 3 done", "  ⎿  ☒ Count the lines" },
      vim.list_slice(all, #all - 5, #all - 4)
    )
    assert.are.same("⏺ All done.", all[#all])
    assert.is_nil(transcript.todo_active())
    -- TodoWrite draws no tool line of its own.
    assert.are.same(-1, row_of("⏺ TodoWrite"))
  end)
end)

describe("item times", function()
  local start = os.time({ year = 2026, month = 10, day = 22, hour = 9, min = 5, sec = 7 })
  local now = start

  before_each(function()
    helpers.start()
    transcript.clear()
    now = start
    transcript.clock = function()
      return now
    end
  end)

  after_each(function()
    transcript.clock = os.time
    transcript.turn_end()
    transcript.clear()
  end)

  -- Each time in the transcript as { row, text }.
  local function times()
    local buf, out = transcript.buf(), {}
    for row = 0, api.nvim_buf_line_count(buf) - 1 do
      local time = transcript.time_of(buf, row)
      if time then
        out[#out + 1] = { row, time }
      end
    end
    return out
  end

  it("gives a prompt, a text block, a notice and an agent's end the time they came, as virtual text only", function()
    transcript.user("Fix the bug")
    now = start + 1
    transcript.text_delta("I will look.")
    -- Text that streams into the first line later keeps the block's time.
    now = start + 5
    transcript.text_delta(" Then fix it.\nDone.")
    transcript.text_stop()
    now = start + 62
    transcript.notice("info", "Conversation compacted")
    now = start + 3600
    transcript.agent_end({ status = "completed", description = "Find x", summary = "Found it." })
    assert.are.same({
      "❯ Fix the bug",
      "",
      "⏺ I will look. Then fix it.",
      "  Done.",
      "",
      "✻ Conversation compacted",
      "",
      '⏺ Agent "Find x" finished',
      "  ⎿  Found it.",
    }, buf_lines(transcript.buf()))
    assert.are.same({ { 0, "09:05:07" }, { 2, "09:05:08" }, { 5, "09:06:09" }, { 7, "10:05:07" } }, times())
    assert.are.same("I will look. Then fix it.\nDone.", transcript.last_reply())
  end)

  -- The todo list can be the first item, as when Claude writes it before
  -- anything else. The next item then goes in on the list's first row.
  local firsts = {
    {
      "text block",
      function()
        transcript.text_delta("I will look.")
        transcript.text_delta("\nDone.")
        transcript.text_stop()
      end,
      { "⏺ I will look.", "  Done." },
    },
    {
      "tool call",
      function()
        local tid = id()
        transcript.tool_start(tid, "Bash")
        transcript.tool_use({ id = tid, name = "Bash", input = { command = "ls" } })
        transcript.tool_result({ id = tid, is_error = false, text = "a.lua" })
      end,
      { "⏺ Bash(ls)", "  ⎿  a.lua" },
    },
    {
      "prompt",
      function()
        transcript.user("Go on")
      end,
      { "❯ Go on" },
    },
    {
      "notice",
      function()
        transcript.notice("info", "Conversation compacted")
      end,
      { "✻ Conversation compacted" },
    },
  }
  for _, first in ipairs(firsts) do
    for _, ask in ipairs({ false, true }) do
      local name = ("keeps a todo list that came first at the end, after a %s%s"):format(
        first[1],
        ask and " and before a request" or ""
      )
      it(name, function()
        todos({ item("Read the file", "in_progress"), item("Fix the bug", "pending") })
        local block = ask and transcript.block({ "  Do you want to proceed?", "  ❯ 1. Yes" }, {})
        first[2]()
        todos({ item("Read the file", "completed"), item("Fix the bug", "in_progress") })
        local want = vim.list_extend(vim.list_slice(first[3]), {
          "",
          "⏺ Todos · 1 of 2 done",
          "  ⎿  ☒ Read the file",
          "     ☐ Fix the bug",
        })
        if block then
          local all = buf_lines(transcript.buf())
          assert.are.same({ "", "  Do you want to proceed?", "  ❯ 1. Yes" }, vim.list_slice(all, #all - 2))
          transcript.remove_block(block)
        end
        assert.are.same(want, buf_lines(transcript.buf()))
        assert(vim.tbl_contains(groups_at(row_of("  ⎿  ☒ Read the file")), "AnvimTodoDone"))
        assert.are.same({ { 0, "09:05:07" } }, times())
        local ns_text = api.nvim_get_namespaces()["anvim.transcript.text"]
        local text_marks = vim.tbl_map(function(m)
          return { m[2], m[3] }
        end, api.nvim_buf_get_extmarks(transcript.buf(), ns_text, 0, -1, {}))
        assert.are.same(first[1] == "text block" and { { 0, #"⏺ " }, { 1, #"  Done." } } or {}, text_marks)
      end)
    end
  end
end)

describe("durations", function()
  it("write seconds under a minute, then minutes and seconds, then hours, as Claude Code does", function()
    local cases = {
      { 12345, "12.3s", "12s" },
      { 59900, "59.9s", "59s" },
      -- Tenths that round to a minute.
      { 59960, "1m 0s", "59s" },
      { 60000, "1m 0s", "1m 0s" },
      { 2400000, "40m 0s", "40m 0s" },
      { 3599000, "59m 59s", "59m 59s" },
      { 3600000, "1h 0m 0s", "1h 0m 0s" },
      { 3723400, "1h 2m 3s", "1h 2m 3s" },
      { 7200000, "2h 0m 0s", "2h 0m 0s" },
    }
    for _, c in ipairs(cases) do
      assert.are.same({ c[2], c[3] }, { transcript.duration(c[1]), transcript.duration(c[1], true) }, c[1] .. " ms")
    end
    assert.are.same(
      "Done (3 tool uses · 1.2k tokens · 1h 2m 3s)",
      transcript.agent_done({}, { totalToolUseCount = 3, totalTokens = 1200, totalDurationMs = 3723000 })
    )
  end)
end)
