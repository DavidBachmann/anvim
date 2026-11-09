---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sessions = require("anvim.sessions")
local sidecar = require("anvim.sidecar")
local tasks = require("anvim.tasks")
local transcript = require("anvim.transcript")

local api = vim.api

-- The footer's text, as drawn under the prompt.
local function footer()
  local ns = api.nvim_get_namespaces()["anvim.input"]
  local mark = api.nvim_buf_get_extmarks(input.buf(), ns, 0, -1, { details = true })[1]
  local text = {}
  for _, chunk in ipairs(mark[4].virt_lines[#mark[4].virt_lines]) do
    text[#text + 1] = chunk[1]
  end
  return table.concat(text)
end

describe("tasks", function()
  after_each(function()
    tasks.close()
    sidecar.dispatch({ type = "tasks", tasks = {} })
    sidecar.dispatch({ type = "crons", crons = {} })
  end)

  it("counts the tasks in the footer, lists them in /tasks, and a restart ends them", function()
    helpers.fresh()
    sidecar.dispatch({ type = "tasks", tasks = { { id = "b1", kind = "shell", description = "Sleep two minutes" } } })
    assert.are.same("  1 task", footer())
    local at = os.time() + 3600
    sidecar.dispatch({
      type = "crons",
      crons = { { id = "c1", schedule = os.date("%M %H %d %m *", at), recurring = false, prompt = "Check the deploy" } },
    })
    -- /clear keeps them, as Claude Code does.
    sidecar.dispatch({ type = "reset" })
    assert.are.same("  2 tasks", footer())

    sessions.command("/tasks")
    local buf = api.nvim_get_current_buf()
    assert.are.same("anvim_tasks", vim.bo[buf].filetype)
    local lines = helpers.buf_lines(buf)
    helpers.contains(lines, "^shell   Sleep two minutes%s+since %d%d:%d%d$")
    local fires = os.date(os.date("%d", at) == os.date("%d") and "%H:%M" or "%d %b %H:%M", at)
    helpers.contains(lines, "^prompt  Check the deploy%s+at " .. fires .. "$")
    api.nvim_feedkeys("q", "mxt", false)
    assert.is_nil(tasks.get())

    sidecar.dispatch({ type = "exit", code = 0, restart = true })
    assert.are.same("  ", footer())
    local ended = "The restart ended 1 background task and 1 scheduled prompt%.$"
    helpers.contains(helpers.buf_lines(transcript.buf()), ended)
    -- A resume's history draws the transcript again, with the line.
    sidecar.dispatch({ type = "history", session_id = "tasks-resumed", events = {} })
    helpers.contains(helpers.buf_lines(transcript.buf()), ended)
  end)
end)
