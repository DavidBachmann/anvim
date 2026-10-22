---@module "luassert"

local agentlog = require("anvim.agentlog")
local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

-- What Claude reads after a send-back in bypass mode: the guard's deny.
local HOOK_ERROR = "PreToolUse:Bash hook error: anvim held this command back and has not asked the user yet."

local function fresh()
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  transcript.clear()
end

-- The line after the last tool line that reads `label`, and the groups of both.
local function result_of(buf, ns_name, label)
  local lines = helpers.buf_lines(buf)
  local ns = api.nvim_get_namespaces()[ns_name]
  for row = #lines, 1, -1 do
    if lines[row] == "⏺ " .. label then
      local function groups(r)
        local found = {}
        for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { r, 0 }, { r, -1 }, { details = true })) do
          found[#found + 1] = mark[4].hl_group
        end
        return found
      end
      return lines[row + 1], groups(row - 1), groups(row)
    end
  end
  error(("no line %q in:\n%s"):format(label, table.concat(lines, "\n")))
end

local function bash(id, command, extra)
  local ev = { type = "tool_use", id = id, name = "Bash", input = { command = command } }
  sidecar.dispatch(vim.tbl_extend("force", ev, extra or {}))
end

local function failed(id, text, extra)
  local ev = { type = "tool_result", id = id, is_error = true, text = text }
  sidecar.dispatch(vim.tbl_extend("force", ev, extra or {}))
end

describe("a send-back", function()
  it("reads as such in the transcript, and a call without one keeps its error", function()
    fresh()
    sidecar.dispatch({ type = "tool_start", id = "sb1", name = "Bash" })
    bash("sb1", "npm i -g x")
    sidecar.dispatch({ type = "send_back", tool_use_id = "sb1", reason = "runs outside the sandbox" })
    failed("sb1", HOOK_ERROR)
    local line, bullet, result = result_of(transcript.buf(), "anvim.transcript", "Bash(npm i -g x)")
    assert.are.same("  ⎿  Sent back to Claude: runs outside the sandbox", line)
    assert.are.same("AnvimToolError", bullet[1])
    assert.are.same({ "AnvimResult" }, result)

    bash("sb2", "npm i -g x")
    failed("sb2", "Exit code 1\nnpm error")
    assert.are.same(
      "  ⎿  Exit code 1 ... +1 lines",
      (result_of(transcript.buf(), "anvim.transcript", "Bash(npm i -g x)"))
    )
    -- The first call's line stays.
    helpers.contains(helpers.buf_lines(transcript.buf()), "^  ⎿  Sent back to Claude: runs outside the sandbox$")
  end)

  it("keeps an event that comes before the main agent's call", function()
    fresh()
    sidecar.dispatch({ type = "send_back", tool_use_id = "sb3", reason = "changes the sandbox's settings" })
    sidecar.dispatch({ type = "tool_start", id = "sb3", name = "Edit" })
    sidecar.dispatch({ type = "tool_use", id = "sb3", name = "Edit", input = { file_path = "settings.json" } })
    failed("sb3", "anvim held this edit back and has not asked the user yet.")
    assert.are.same(
      "  ⎿  Sent back to Claude: changes the sandbox's settings",
      (result_of(transcript.buf(), "anvim.transcript", "Edit(settings.json)"))
    )
  end)

  it("reads a saved hint, which has no event, as a send-back without its reason", function()
    fresh()
    bash("sb4", "touch ~/x")
    failed("sb4", HOOK_ERROR .. " It would run outside the sandbox.")
    assert.are.same("  ⎿  Sent back to Claude", (result_of(transcript.buf(), "anvim.transcript", "Bash(touch ~/x)")))
    -- In default mode the hint is the whole text.
    bash("sb5", "touch ~/y")
    failed("sb5", "anvim held this command back and has not asked the user yet.\nIt would run outside the sandbox.")
    assert.are.same("  ⎿  Sent back to Claude", (result_of(transcript.buf(), "anvim.transcript", "Bash(touch ~/y)")))
    -- Another hook's error keeps its text.
    bash("sb6", "touch ~/z")
    failed("sb6", "PreToolUse:Bash hook error: my hook says no")
    assert.are.same(
      "  ⎿  PreToolUse:Bash hook error: my hook says no",
      (result_of(transcript.buf(), "anvim.transcript", "Bash(touch ~/z)"))
    )
  end)

  it("names the agent in its log, also when the event comes before the call", function()
    fresh()
    local agent = "a5e0b1c2d3"
    sidecar.dispatch({
      type = "tool_use",
      id = "tu_" .. agent,
      name = "Agent",
      input = { description = "Write notes", subagent_type = "general-purpose", prompt = "Write the notes" },
    })
    sidecar.dispatch({
      type = "agent_start",
      agent_id = agent,
      tool_use_id = "tu_" .. agent,
      description = "Write notes",
      subagent_type = "general-purpose",
      depth = 1,
      background = false,
    })
    local sub = { parent_id = "tu_" .. agent, agent_id = agent }
    local reason = "outside the trusted dirs: ~/notes.txt"
    sidecar.dispatch({ type = "send_back", tool_use_id = "w1", agent_id = agent, reason = reason })
    sidecar.dispatch(vim.tbl_extend("force", {
      type = "tool_use",
      id = "w1",
      name = "Write",
      input = { file_path = vim.env.HOME .. "/notes.txt", content = "x" },
    }, sub))
    failed("w1", "PreToolUse:Write hook error: anvim held this edit back", sub)
    -- The same call again asks the user, who says no.
    sidecar.dispatch(vim.tbl_extend("force", {
      type = "tool_use",
      id = "w2",
      name = "Write",
      input = { file_path = vim.env.HOME .. "/notes.txt", content = "x" },
    }, sub))
    failed("w2", "The user doesn't want to proceed with this tool use.", sub)
    -- A hint without its event, as a replay without the event has it.
    bash("w3", "touch ~/x", sub)
    failed("w3", HOOK_ERROR, sub)
    local lines = helpers.buf_lines(agentlog.buf(agent))
    helpers.contains(lines, "^  ⎿  Sent back to Agent 1$")
    helpers.contains(lines, "^  ⎿  Sent back to Agent 1: outside the trusted dirs: ~/notes%.txt$")
    helpers.contains(lines, "^  ⎿  The user doesn't want to proceed with this tool use%.$")
    -- The transcript has no line of the agent's calls.
    assert(not vim.tbl_contains(helpers.buf_lines(transcript.buf()), function(l)
      return l:find("Sent back", 1, true) ~= nil
    end, { predicate = true }))
  end)

  it("forgets a send-back whose call never came when the conversation resets", function()
    fresh()
    local agent = "a7f1e2d3c4"
    sidecar.dispatch({
      type = "agent_start",
      agent_id = agent,
      tool_use_id = "tu_" .. agent,
      description = "Look",
      subagent_type = "Explore",
      depth = 1,
      background = false,
    })
    sidecar.dispatch({ type = "send_back", tool_use_id = "b9", agent_id = agent, reason = "runs outside the sandbox" })
    sidecar.dispatch({ type = "reset" })
    sidecar.dispatch({
      type = "agent_start",
      agent_id = agent,
      tool_use_id = "tu_" .. agent,
      description = "Look",
      subagent_type = "Explore",
      depth = 1,
      background = false,
    })
    local sub = { parent_id = "tu_" .. agent, agent_id = agent }
    bash("b9", "ls ~", sub)
    failed("b9", "Exit code 2\nno such dir", sub)
    helpers.contains(helpers.buf_lines(agentlog.buf(agent)), "^  ⎿  Exit code 2 ")
  end)
end)
