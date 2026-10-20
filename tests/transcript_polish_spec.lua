---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sessions = require("anvim.sessions")
local state = require("anvim.state")
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

  it("nests a subagent's last three tool calls and a count, then its result", function()
    transcript.user("List the lua files")
    local agent = id()
    transcript.tool_start(agent, "Agent")
    transcript.tool_use({
      id = agent,
      name = "Agent",
      input = { description = "List files", subagent_type = "Explore", prompt = "..." },
      parent_id = nil,
    })
    local cwd = state.cwd
    for i, cmd in ipairs({ "ls", "pwd", "find " .. cwd .. " -name '*.lua'", "wc -l a.lua", "cat " .. cwd .. "/a.lua" }) do
      transcript.tool_use({ id = "child" .. i, name = "Bash", input = { command = cmd }, parent_id = agent })
    end
    assert.are.same({
      "⏺ Explore(List files)",
      "  ⎿  Bash(find . -name '*.lua')",
      "     Bash(wc -l a.lua)",
      "     Bash(cat a.lua)",
      "     +2 more tool uses",
    }, lines_from("⏺ Explore(List files)"))
    assert.are.same({ "AnvimResult" }, groups_at(row_of("     +2 more tool uses")))
    transcript.tool_result({
      id = agent,
      is_error = false,
      text = "[Subagent hand-back] The text below is the final report",
      result = { totalToolUseCount = 5, totalTokens = 24056, totalDurationMs = 2825 },
    })
    assert.are.same(
      { "⏺ Explore(List files)", "  ⎿  Done (5 tool uses · 24.1k tokens · 2.8s)" },
      lines_from("⏺ Explore(List files)")
    )
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

  it("shows a permission request after a long pinned list, where 1 answers it in a short window", function()
    local layout = require("anvim.layout")
    local permission = require("anvim.permission")
    local sidecar = require("anvim.sidecar")
    local guard = permission.guard_ms
    permission.guard_ms = 0
    transcript.user("Do eight things")
    local list = {}
    for i = 1, 8 do
      list[i] = item("Do thing " .. i, i == 1 and "in_progress" or "pending")
    end
    todos(list)
    local win = layout.wins.transcript
    local height = api.nvim_win_get_height(win)
    api.nvim_win_set_height(win, 8)
    local tid = id()
    transcript.tool_start(tid, "Bash")
    transcript.tool_use({ id = tid, name = "Bash", input = { command = "rm -rf build" } })
    helpers.capture_sends(function(sent)
      sidecar.dispatch({
        type = "permission_request",
        req = 7801,
        tool_use_id = tid,
        tool = "Bash",
        input = { command = "rm -rf build" },
      })
      local all = buf_lines(transcript.buf())
      local list_end = vim.fn.index(all, "     ☐ Do thing 8")
      local ask = vim.fn.index(all, "  Do you want to proceed?")
      assert(list_end >= 0 and ask > list_end, table.concat(all, "\n"))
      api.nvim_set_current_win(layout.wins.input)
      vim.cmd.stopinsert()
      api.nvim_feedkeys("1", "mx", false)
      assert.are.same({ { type = "permission_response", req = 7801, behavior = "allow" } }, sent)
    end)
    -- Answered, the request goes, and the list is last again.
    local all = buf_lines(transcript.buf())
    assert.are.same("     ☐ Do thing 8", all[#all])
    api.nvim_win_set_height(win, height)
    permission.guard_ms = guard
  end)

  it("moves the pinned list under a block that stays, such as an approved plan", function()
    transcript.user("Plan it")
    todos({ item("Write the plan", "in_progress"), item("Build it", "pending") })
    local block = transcript.block({ "  Claude's plan:", "  1. Build it" }, {})
    transcript.keep_block(block)
    transcript.text_delta("Building now.")
    local all = buf_lines(transcript.buf())
    assert.are.same({
      "❯ Plan it",
      "",
      "  Claude's plan:",
      "  1. Build it",
      "",
      "⏺ Building now.",
      "",
      "⏺ Todos · 0 of 2 done",
      "  ⎿  ☐ Write the plan",
      "     ☐ Build it",
    }, lines_from("❯ Plan it"))
    assert.are.same("     ☐ Build it", all[#all])
  end)

  it("builds the list from TaskCreate and TaskUpdate, also from a saved session's result text", function()
    transcript.user("Plan it")
    local function call(name, input_, text, result)
      local tid = id()
      transcript.tool_start(tid, name)
      transcript.tool_use({ id = tid, name = name, input = input_ })
      transcript.tool_result({ id = tid, is_error = false, text = text, result = result })
    end
    call(
      "TaskCreate",
      { subject = "Read the file", activeForm = "Reading the file" },
      "Task #1 created successfully: Read the file",
      {
        task = { id = "1", subject = "Read the file" },
      }
    )
    -- As a saved session gives it: no tool_use_result.
    call(
      "TaskCreate",
      { subject = "Fix the bug", activeForm = "Fixing the bug" },
      "Task #2 created successfully: Fix the bug"
    )
    call("TaskCreate", { subject = "Drop me" }, "Task #3 created successfully: Drop me")
    call("TaskUpdate", { taskId = "1", status = "in_progress" }, "Updated task #1 status")
    call("TaskUpdate", { taskId = "3", status = "deleted" }, "Updated task #3 deleted")
    call("TaskList", {}, "#1 [in_progress] Read the file")
    assert.are.same({
      "❯ Plan it",
      "",
      "⏺ Todos · 0 of 2 done",
      "  ⎿  ☐ Read the file",
      "     ☐ Fix the bug",
    }, lines_from("❯ Plan it"))
    assert.are.same("Reading the file", transcript.todo_active())
    call("TaskUpdate", { taskId = "1", status = "completed" }, "Updated task #1 status")
    call("TaskUpdate", { taskId = "2", status = "completed" }, "Updated task #2 status")
    assert.are.same("⏺ Todos · 2 of 2 done", lines_from("❯ Plan it")[3])
    -- Done, the next task starts a new list.
    call("TaskCreate", { subject = "Next" }, "Task #4 created successfully: Next")
    local all = buf_lines(transcript.buf())
    assert.are.same({ "⏺ Todos · 0 of 1 done", "  ⎿  ☐ Next" }, vim.list_slice(all, #all - 1))
  end)

  it("writes paths under the cwd short, in labels and results", function()
    local cwd = state.cwd
    assert.are.same("a.lua", transcript.short(cwd .. "/a.lua"))
    assert.are.same("ls . -la", transcript.short("ls " .. cwd .. " -la"))
    assert.are.same("cd .", transcript.short("cd " .. cwd))
    assert.are.same(cwd .. "3/a.lua", transcript.short(cwd .. "3/a.lua"), "another dir that starts the same")
    assert.are.same("/x" .. cwd .. "/a", transcript.short("/x" .. cwd .. "/a"), "a path that holds the cwd")
    assert.are.same("--file=b/c.txt", transcript.short("--file=" .. cwd .. "/b/c.txt"))
    local tid = id()
    transcript.tool_start(tid, "Bash")
    transcript.tool_use({ id = tid, name = "Bash", input = { command = "find " .. cwd .. " -type f" }, parent_id = nil })
    transcript.tool_result({
      id = tid,
      is_error = false,
      text = "",
      result = { stdout = cwd .. "/a.lua\n" .. cwd .. "/b.lua" },
    })
    assert.are.same({ "⏺ Bash(find . -type f)", "  ⎿  a.lua ... +1 lines" }, lines_from("⏺ Bash(find . -type f)"))
  end)

  it("shows a slash command's output under it, and a compaction as a notice", function()
    transcript.user("/cost")
    transcript.output("Total cost: $0.01\nTotal duration: 3s")
    transcript.compact({ trigger = "manual", pre_tokens = 45065, post_tokens = 16912 })
    assert.are.same({
      "❯ /cost",
      "  ⎿  Total cost: $0.01",
      "     Total duration: 3s",
      "",
      "✻ Conversation compacted · 45.1k → 16.9k tokens",
    }, lines_from("❯ /cost"))
  end)

  it("counts an Edit's lines from its input when the result has no patch", function()
    local tid = id()
    transcript.tool_start(tid, "Edit")
    transcript.tool_use({
      id = tid,
      name = "Edit",
      input = {
        file_path = state.cwd .. "/a.lua",
        old_string = "local M = {}",
        new_string = "-- List helpers.\nlocal M = {}",
      },
      parent_id = nil,
    })
    transcript.tool_result({ id = tid, is_error = false, text = "The file has been updated." })
    assert.are.same({ "⏺ Edit(a.lua)", "  ⎿  Added 1 line, removed 0 lines" }, lines_from("⏺ Edit(a.lua)"))
  end)

  it("yanks Claude's last reply, the text after its last tool call", function()
    transcript.user("Explain")
    transcript.text_delta("Let me look.")
    transcript.text_stop()
    local tid = id()
    transcript.tool_start(tid, "Read")
    transcript.tool_result({ id = tid, is_error = false, text = "x" })
    transcript.text_delta("It adds ")
    transcript.text_delta("two numbers.\n\n```lua\nreturn a + b\n```")
    transcript.text_stop()
    local notify, said = vim.notify, nil
    vim.notify = function(msg)
      said = msg
    end
    sessions.yank("a")
    vim.notify = notify
    assert(said and said:find("copied Claude's last reply", 1, true), said)
    assert.are.same("It adds two numbers.\n\n```lua\nreturn a + b\n```", vim.fn.getreg("a"))
  end)
end)
