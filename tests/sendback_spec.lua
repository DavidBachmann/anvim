---@module "luassert"

local helpers = require("helpers")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

-- What Claude reads after a send-back in bypass mode: the guard's deny.
local HOOK_ERROR = "PreToolUse:Bash hook error: anvim held this command back and has not asked the user yet."

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
    helpers.fresh()
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
    helpers.fresh()
    sidecar.dispatch({ type = "send_back", tool_use_id = "sb3", reason = "changes the sandbox's settings" })
    sidecar.dispatch({ type = "tool_start", id = "sb3", name = "Edit" })
    sidecar.dispatch({ type = "tool_use", id = "sb3", name = "Edit", input = { file_path = "settings.json" } })
    failed("sb3", "anvim held this edit back and has not asked the user yet.")
    assert.are.same(
      "  ⎿  Sent back to Claude: changes the sandbox's settings",
      (result_of(transcript.buf(), "anvim.transcript", "Edit(settings.json)"))
    )
  end)
end)
