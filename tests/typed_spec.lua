---@module "luassert"

local agents = require("anvim.agents")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local stream = require("anvim.stream")

local api = vim.api
local buf_lines, hl_groups = helpers.buf_lines, helpers.hl_groups

local LINES = { "local a = 1", "local b = 2", "local c = 3", "local d = 4", "return a" }

local function file(name, lines)
  local path = helpers.tmp .. "/" .. name
  vim.fn.writefile(lines or LINES, path)
  return path
end

local function start(id)
  sidecar.dispatch({
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "general-purpose",
    depth = 1,
    background = false,
  })
end

local reqs = 0

-- The PreToolUse hook of a subagent's edit, as the sidecar sends it.
---@return integer req
local function await(id, tool_id, name, input)
  reqs = reqs + 1
  sidecar.dispatch({
    type = "await_preview",
    req = reqs,
    tool_use_id = tool_id,
    agent_id = id,
    name = name,
    input = input,
  })
  return reqs
end

local function use(id, tool_id, name, input)
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = name,
    input = input,
    parent_id = "tu_" .. id,
    agent_id = id,
  })
end

local function result(id, tool_id)
  sidecar.dispatch({
    type = "tool_result",
    id = tool_id,
    is_error = false,
    text = "The file has been updated successfully.",
    parent_id = "tu_" .. id,
    agent_id = id,
  })
end

local function answered(sent, req)
  for _, msg in ipairs(sent) do
    if msg.type == "preview_done" and msg.req == req then
      return true
    end
  end
  return false
end

-- Waits for the answer to req, and returns the ms it took.
local function wait_answer(sent, req, ms)
  local t0 = vim.uv.hrtime()
  assert(
    vim.wait(ms or 3000, function()
      return answered(sent, req)
    end, 5),
    "preview_done was not sent"
  )
  return (vim.uv.hrtime() - t0) / 1e6
end

local function text_of(buf)
  return table.concat(buf_lines(buf), "\n")
end

local function code_buf()
  return api.nvim_win_get_buf(layout.wins.code)
end

local function prompt()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

-- The 0-based rows that flash after a reload.
local function flashed(buf)
  local ns = api.nvim_get_namespaces()["anvim.follow"]
  local rows = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].line_hl_group == "AnvimInsert" then
      rows[#rows + 1] = mark[2]
    end
  end
  return rows
end

local function fresh(...)
  helpers.start()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  for _, id in ipairs({ ... }) do
    start(id)
  end
  prompt()
end

describe("typed previews", function()
  after_each(function()
    stream.cancel_all()
    agents.clear()
    follow.forget()
  end)

  it("types the focused agent's edit at a steady pace, and answers once it has caught up", function()
    fresh("t1")
    follow.set_focus("t1")
    local path = file("typed_edit.lua")
    local new = "local c = 30\n" .. ("-- note\n"):rep(14) .. "local cc = 33"
    helpers.capture_sends(function(sent)
      local t0 = vim.uv.hrtime()
      local req = await("t1", "te1", "Edit", { file_path = path, old_string = "local c = 3", new_string = new })
      local buf = vim.fn.bufnr(path)
      assert.are.same(buf, code_buf(), "the code window shows the edited file")
      assert.is_false(answered(sent, req), "the edit is held")
      assert.are.same(1, hl_groups(buf, "anvim.stream").AnvimDelete, "the old text is struck through")
      assert(not vim.diagnostic.is_enabled({ bufnr = buf }), "diagnostics are off during the preview")
      vim.wait(80)
      local shown = #text_of(buf) - #table.concat(LINES, "\n") - 1
      assert(shown > 0 and shown < #new, ("the preview is paced, but showed %d of %d bytes"):format(shown, #new))
      local cursor = api.nvim_buf_get_extmarks(buf, api.nvim_get_namespaces()["anvim.stream"], 0, -1, {
        details = true,
      })
      local groups = {}
      for _, mark in ipairs(cursor) do
        if mark[4].virt_text then
          groups[#groups + 1] = mark[4].virt_text[1][2]
        end
      end
      assert.are.same({ "AnvimAgent1" }, groups, "the cursor has the agent's color")

      wait_answer(sent, req)
      local ms = (vim.uv.hrtime() - t0) / 1e6
      local want = vim.list_extend({ "local a = 1", "local b = 2", "local c = 3" }, vim.split(new, "\n"))
      vim.list_extend(want, { "local d = 4", "return a" })
      assert.are.same(want, buf_lines(buf), "the whole new text is in before the answer")
      -- 138 bytes at 500 bytes a second.
      assert(ms > 230 and ms < 1000, ("the preview took %d ms"):format(ms))
      assert(not vim.bo[buf].modifiable and not vim.bo[buf].modified, "the buffer stays read-only and unmodified")

      local after = vim.list_extend({ "local a = 1", "local b = 2" }, vim.split(new, "\n"))
      vim.fn.writefile(vim.list_extend(after, { "local d = 4", "return a" }), path)
      result("t1", "te1")
      assert.are.same({}, hl_groups(buf, "anvim.stream"), "preview marks are gone")
      assert(vim.diagnostic.is_enabled({ bufnr = buf }), "diagnostics are back after the reload")
      assert.are.same(vim.fn.range(2, 17), flashed(buf), "the added rows flash, from a diff")
      assert.are.same(3, api.nvim_win_get_cursor(layout.wins.code)[1], "the cursor is on the first added line")
    end)
  end)

  it("answers at once for other agents, and for the focused one while the user reads elsewhere", function()
    fresh("o1", "o2")
    follow.set_focus("o1")
    local path = file("typed_other.lua")
    local edit = { file_path = path, old_string = "local b = 2", new_string = "local b = 20" }
    helpers.capture_sends(function(sent)
      local req = await("o2", "to1", "Edit", edit)
      assert(answered(sent, req), "an agent without focus waits")
      assert.is_false(stream.typed("to1"))
      local buf = vim.fn.bufnr(path)
      assert(buf == -1 or not hl_groups(buf, "anvim.stream").AnvimDelete, "it has no preview")

      vim.cmd.stopinsert()
      api.nvim_set_current_win(layout.wins.code)
      req = await("o1", "to2", "Edit", edit)
      assert(answered(sent, req), "the focused agent waits while the user reads elsewhere")
      req = await("o1", "to3", "NotebookEdit", { notebook_path = path, new_source = "x" })
      assert(answered(sent, req), "a notebook edit waits")
      prompt()
      req = await("o1", "to4", "Edit", { file_path = path, old_string = "no such text", new_string = "x" })
      assert(answered(sent, req), "an edit whose old text is not in the file waits")
      local missing = helpers.tmp .. "/typed_missing.lua"
      req = await("o1", "to5", "Edit", { file_path = missing, old_string = "a", new_string = "b" })
      assert(answered(sent, req), "an edit of a missing file waits")
    end)
  end)

  it("keeps a background agent's preview through the main turn's end, and ends a foreground one's", function()
    fresh("f1")
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "b1",
      tool_use_id = "tu_b1",
      description = "Task b1",
      depth = 1,
      background = true,
    })
    local path = file("typed_background.lua")
    local long = ("-- note\n"):rep(60) .. "local b = 20"
    local turn_end = { type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 }
    helpers.capture_sends(function(sent)
      follow.set_focus("f1")
      local req = await("f1", "tf1", "Edit", { file_path = path, old_string = "local d = 4", new_string = long })
      assert.is_false(answered(sent, req))
      sidecar.dispatch(turn_end)
      assert(answered(sent, req), "a foreground agent's preview ends with the turn")
      assert.is_false(stream.typed("tf1"))

      follow.set_focus("b1")
      req = await("b1", "tb1", "Edit", { file_path = path, old_string = "local b = 2", new_string = long })
      assert.is_false(answered(sent, req))
      sidecar.dispatch(turn_end)
      assert.is_false(answered(sent, req), "the background agent's preview goes on")
      assert(stream.typed("tb1"))
      wait_answer(sent, req)
    end)
  end)

  it("answers at once when a typed preview cannot start", function()
    fresh("w1")
    follow.set_focus("w1")
    local path = helpers.tmp .. "/typed_taken.lua"
    -- The main agent's Write preview of the same file already has the name.
    sidecar.dispatch({ type = "tool_start", id = "mw", name = "Write" })
    helpers.field("mw", "Write", "file_path", "end", path)
    helpers.capture_sends(function(sent)
      local req = await("w1", "tw1", "Write", { file_path = path, content = "x" })
      assert(answered(sent, req), "the agent does not wait for a broken preview")
      assert.is_false(stream.typed("tw1"))
    end)
    sidecar.dispatch({ type = "tool_result", id = "mw", is_error = true, text = "" })
  end)

  it("takes at most about 2 s for a long edit", function()
    fresh("l1")
    follow.set_focus("l1")
    local path = file("typed_long.lua")
    local new = ("local x = 'a long line of text'\n"):rep(600)
    helpers.capture_sends(function(sent)
      local req = await("l1", "tl1", "Edit", { file_path = path, old_string = "local d = 4", new_string = new })
      local ms = wait_answer(sent, req, 4000)
      assert(ms > 1700 and ms < 2600, ("the preview took %d ms"):format(ms))
      assert(text_of(vim.fn.bufnr(path)):find(new, 1, true), "the whole new text is in")
    end)
  end)

  it("finishes at once when the user stops following the agent", function()
    local new = ("local y = 'more text'\n"):rep(60)
    for _, case in ipairs({ "leaves the prompt", "focuses another agent" }) do
      fresh("u1", "u2")
      follow.set_focus("u1")
      local path = file("typed_unfocus.lua")
      helpers.capture_sends(function(sent)
        local req = await("u1", "tu1", "Edit", { file_path = path, old_string = "return a", new_string = new })
        vim.wait(100)
        assert.is_false(answered(sent, req), case)
        if case == "leaves the prompt" then
          api.nvim_set_current_win(layout.wins.code)
        else
          follow.set_focus("u2")
        end
        local ms = wait_answer(sent, req)
        assert(ms < 100, ("%s: the answer took %d ms"):format(case, ms))
        assert(text_of(vim.fn.bufnr(path)):find(new, 1, true), case .. ": the whole new text is in")
      end)
      stream.cancel_all()
    end
  end)

  it("types a Write into a preview buffer, and flashes the rows that changed", function()
    fresh("w1")
    follow.set_focus("w1")
    local path = file("typed_write.lua")
    local content = { "local a = 1", "local b = 22", "local c = 3", "local d = 4", "return a + b" }
    helpers.capture_sends(function(sent)
      local req = await("w1", "tw1", "Write", { file_path = path, content = table.concat(content, "\n") .. "\n" })
      local preview = code_buf()
      assert.are.same(path, vim.b[preview].anvim_preview, "the code window shows the preview")
      wait_answer(sent, req)
      assert.are.same(vim.list_extend(vim.deepcopy(content), { "" }), buf_lines(preview))
      vim.fn.writefile(content, path)
      result("w1", "tw1")
      local buf = code_buf()
      assert.are.same(path, api.nvim_buf_get_name(buf))
      assert(not api.nvim_buf_is_valid(preview), "the preview buffer is gone")
      assert.are.same({ 1, 4 }, flashed(buf), "only the changed rows flash")
    end)

    -- A new file flashes whole.
    local new = helpers.tmp .. "/typed_new.lua"
    os.remove(new)
    helpers.capture_sends(function(sent)
      wait_answer(sent, await("w1", "tw2", "Write", { file_path = new, content = "return 1\nreturn 2\n" }))
      vim.fn.writefile({ "return 1", "return 2" }, new)
      result("w1", "tw2")
      assert.are.same(new, api.nvim_buf_get_name(code_buf()))
      assert.are.same({ 0, 1 }, flashed(code_buf()))
    end)
  end)

  it("does the same whether the hook or the tool_use comes first", function()
    for _, order in ipairs({ "hook first", "tool_use first" }) do
      fresh("r1")
      follow.set_focus("r1")
      local path = file("typed_order.lua")
      local write = { file_path = path, content = "return 'new'\n" }
      helpers.capture_sends(function(sent)
        local tool_id = "tr_" .. order
        if order == "tool_use first" then
          use("r1", tool_id, "Write", write)
        end
        local req = await("r1", tool_id, "Write", write)
        if order == "hook first" then
          use("r1", tool_id, "Write", write)
        end
        assert.are.same(path, vim.b[code_buf()].anvim_preview, order .. ": the code window shows the preview")
        wait_answer(sent, req)
        assert.are.same({ "return 'new'", "" }, buf_lines(code_buf()), order)
        assert.are.same({ path, 1 }, { follow.place().path, follow.place().line }, order)
        vim.fn.writefile({ "return 'new'" }, path)
        result("r1", tool_id)
        assert.are.same(path, api.nvim_buf_get_name(code_buf()), order)
        assert.are.same({ 0 }, flashed(code_buf()), order)
      end)
    end
  end)
end)
