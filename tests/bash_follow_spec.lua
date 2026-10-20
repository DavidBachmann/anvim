---@module "luassert"

local agents = require("anvim.agents")
local bashread = require("anvim.bashread")
local context = require("anvim.context")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local trail = require("anvim.trail")

local api = vim.api

local function file(name, n)
  local lines = {}
  for i = 1, n or 12 do
    lines[i] = ("local x%d = %d"):format(i, i)
  end
  local path = helpers.tmp .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local tool_ids = 0

-- A Bash call of agent `id`, or of the main agent for nil. Returns its id.
local function bash(command, id, input, tool_id)
  tool_ids = tool_ids + 1
  tool_id = tool_id or "bash_tool" .. tool_ids
  sidecar.dispatch({
    type = "tool_use",
    id = tool_id,
    name = "Bash",
    input = vim.tbl_extend("force", { command = command, description = "Read" }, input or {}),
    parent_id = id and "tu_" .. id or nil,
    agent_id = id,
  })
  return tool_id
end

local function result(tool_id, stdout, id)
  sidecar.dispatch({
    type = "tool_result",
    id = tool_id,
    is_error = false,
    text = stdout,
    -- A subagent's result has no tool_use_result.
    result = not id and { stdout = stdout, stderr = "", interrupted = false } or nil,
    parent_id = id and "tu_" .. id or nil,
    agent_id = id,
  })
end

local function start_agent(id, background)
  sidecar.dispatch({
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "Explore",
    depth = 1,
    background = background or false,
  })
end

local function code_file()
  return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code))
end

local function code_line()
  return api.nvim_win_get_cursor(layout.wins.code)[1]
end

-- The 1-based lines of a buffer that flash as read.
local function flashed(path)
  local ns = api.nvim_get_namespaces()["anvim.follow"]
  local lines = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(vim.fn.bufnr(path), ns, 0, -1, { details = true })) do
    if mark[4].line_hl_group == "AnvimRead" then
      lines[#lines + 1] = mark[2] + 1
    end
  end
  table.sort(lines)
  return lines
end

-- The prompt in normal mode, where follow mode follows.
local function prompt()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

local function elsewhere()
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.wins.code)
end

local function fresh()
  helpers.start()
  context.clear()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  bashread.forget()
end

local function turn_end()
  sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
end

-- Records the files that the code window shows, in order, while fn runs.
local function shown_files(fn)
  local list, show = {}, follow.show
  follow.show = function(buf, ...)
    list[#list + 1] = vim.fs.basename(api.nvim_buf_get_name(buf))
    return show(buf, ...)
  end
  local ok, err = pcall(fn)
  follow.show = show
  if not ok then
    error(err, 0)
  end
  return list
end

describe("bash reads", function()
  after_each(function()
    agents.clear()
    follow.forget()
    context.clear()
    vim.cmd.stopinsert()
  end)

  it("show a file that Claude reads with cat as a Read does, and only point at it elsewhere", function()
    fresh()
    local a, b = file("bash_a.lua"), file("bash_b.lua")
    prompt()
    bash("cat bash_a.lua")
    assert.are.same({ a, 1 }, { code_file(), code_line() })
    assert.are.same({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, flashed(a))

    elsewhere()
    bash("cd " .. helpers.tmp .. " && sed -n 3,4p bash_b.lua 2>/dev/null")
    assert.are.same(a, code_file(), "the user is in control")
    assert.are.same("⏺ Claude at bash_b.lua:3 +1", follow.status())
    prompt()
    assert(
      vim.wait(1000, function()
        return code_file() == b
      end),
      "entering the prompt did not catch up"
    )
    assert.are.same(3, code_line())

    local items = trail.items()
    assert.are.same("Read bash_b.lua#L3-4", items[1].text)
    assert.are.same("Read bash_a.lua", items[2].text)
  end)

  it("follow a subagent's reads only while it has the focus", function()
    fresh()
    local a, b = file("bash_agent_a.lua"), file("bash_agent_b.lua")
    start_agent("s1")
    prompt()
    local before = code_file()
    bash("head -n 5 " .. a, "s1")
    assert.are.same(before, code_file(), "an agent without focus moves nothing")
    assert.are.same({ path = a, line = 1 }, agents.get("s1").place)
    follow.focus_slot(1)
    assert.are.same(a, code_file(), "focus catches up")
    bash("tail -n 4 " .. b, "s1")
    assert.are.same({ b, 9 }, { code_file(), code_line() })
    assert.are.same({ 9, 10, 11, 12 }, flashed(b))
    assert.are.same({ path = b, line = 9 }, agents.get("s1").place)
    bash("cat " .. a)
    assert.are.same(b, code_file(), "the main agent's read leaves a view that follows a subagent alone")
  end)

  it("step through the files of one call while following, and the next tool call ends the steps", function()
    fresh()
    local a, b, c, d = file("bash_s1.lua"), file("bash_s2.lua"), file("bash_s3.lua"), file("bash_s4.lua")
    prompt()
    local list = shown_files(function()
      local id = bash("cat bash_s1.lua; echo ---; cat bash_s2.lua; head -3 bash_s3.lua; cat bash_s4.lua")
      result(id, "local x1 = 1")
      assert.are.same(a, code_file(), "the first file shows at once")
      local t = vim.uv.hrtime()
      assert(
        vim.wait(2000, function()
          return code_file() == b
        end),
        "the second file did not show"
      )
      local ms = (vim.uv.hrtime() - t) / 1e6
      assert(ms > 600 and ms < 1600, ("the second file came after %d ms"):format(ms))
      assert.are.same({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, flashed(b))
      -- Claude's next call: the rest of the reads count at once.
      bash("ls")
      assert(
        vim.wait(500, function()
          return code_file() == d
        end),
        "no catch-up to the last read"
      )
      vim.wait(1000)
    end)
    assert.are.same({ "bash_s1.lua", "bash_s2.lua", "bash_s4.lua" }, list)
    assert.are.same(d, follow.place().path)
    assert.are.same(0, follow.place().behind)
    assert.are.same(c, trail.items()[2].file, "the trail has every read")
  end)

  it("end the steps when the main agent's next call starts to stream", function()
    fresh()
    local a, b, c = file("bash_n1.lua"), file("bash_n2.lua"), file("bash_n3.lua")
    prompt()
    result(bash(("cat %s %s %s"):format(a, b, c)), "local x1 = 1")
    assert.are.same(a, code_file())
    sidecar.dispatch({ type = "tool_start", id = "bash_next_start", name = "Edit" })
    assert(
      vim.wait(500, function()
        return code_file() == c
      end),
      "no catch-up to the last read"
    )
  end)

  it("queue the reads and hits of calls that Claude sends in one batch", function()
    local a, b, g = file("bash_b1.lua"), file("bash_b2.lua"), file("bash_b3.lua", 40)
    -- As haiku sent them: both calls, then both results. And as in the
    -- fixtures: the first result comes while the second call streams.
    for _, early in ipairs({ false, true }) do
      fresh()
      prompt()
      local list = shown_files(function()
        local first = bash("cat bash_b1.lua bash_b2.lua")
        local second = "bash_batch_" .. tostring(early)
        sidecar.dispatch({ type = "tool_start", id = second, name = "Bash" })
        if early then
          result(first, "local x1 = 1")
        end
        bash("grep -n x bash_b3.lua", nil, nil, second)
        result(second, "30:local x30 = 30\n33:local x33 = 33")
        if not early then
          result(first, "local x1 = 1")
        end
        assert.are.same(a, code_file())
        assert(
          vim.wait(1500, function()
            return code_file() == b
          end),
          "the batch's next read did not show"
        )
        assert(
          vim.wait(1500, function()
            return code_file() == g
          end),
          "the hits of the batch's grep did not show"
        )
        assert.are.same(30, code_line())
        assert.are.same({ 30, 33 }, flashed(g))
      end)
      assert.are.same({ "bash_b1.lua", "bash_b2.lua", "bash_b3.lua" }, list)
    end
  end)

  it("show at most four files of one call: the first three and the last", function()
    fresh()
    local names = {}
    for i = 1, 6 do
      file(("bash_m%d.lua"):format(i))
      names[i] = ("bash_m%d.lua"):format(i)
    end
    prompt()
    local list = shown_files(function()
      bash("cat " .. table.concat(names, " "))
      assert(
        vim.wait(4000, function()
          return vim.fs.basename(code_file()) == "bash_m6.lua"
        end),
        "the last file did not show"
      )
    end)
    assert.are.same({ "bash_m1.lua", "bash_m2.lua", "bash_m3.lua", "bash_m6.lua" }, list)
  end)

  it("stop stepping when the user leaves the prompt, and count the rest as Claude's place", function()
    fresh()
    local a, b, c = file("bash_l1.lua"), file("bash_l2.lua"), file("bash_l3.lua", 30)
    prompt()
    bash(("cat %s; cat %s; tail -n 5 %s"):format(a, b, c))
    assert.are.same(a, code_file())
    elsewhere()
    vim.wait(1200)
    assert.are.same(a, code_file(), "the steps stopped")
    assert.are.same("⏺ Claude at bash_l3.lua:26 +1", follow.status())
  end)

  it("end the steps at turn_end and on a newer move, such as show_user", function()
    fresh()
    local a, b, c = file("bash_t1.lua"), file("bash_t2.lua"), file("bash_t3.lua")
    prompt()
    bash(("cat %s %s %s"):format(a, b, c))
    turn_end()
    assert(
      vim.wait(500, function()
        return code_file() == c
      end),
      "turn_end did not show the last read"
    )

    local shown = file("bash_shown.lua")
    bash(("cat %s %s %s"):format(a, b, c))
    assert.are.same(a, code_file())
    follow.track(shown, 2)
    vim.wait(1200)
    assert.are.same({ shown, 2 }, { code_file(), code_line() }, "the steps fought a newer move")
  end)

  it("keep a running background agent's steps over turn_end, and end a foreground agent's", function()
    fresh()
    local b1, b2, b3 = file("bash_bg1.lua"), file("bash_bg2.lua"), file("bash_bg3.lua")
    start_agent("bg", true)
    prompt()
    follow.focus_slot(1)
    local list = shown_files(function()
      result(bash(("cat %s %s %s"):format(b1, b2, b3), "bg"), "local x1 = 1", "bg")
      turn_end()
      assert(
        vim.wait(2500, function()
          return code_file() == b3
        end),
        "the steps did not go on"
      )
    end)
    assert.are.same({ "bash_bg1.lua", "bash_bg2.lua", "bash_bg3.lua" }, list)

    fresh()
    local f1, f2, f3 = file("bash_fg1.lua"), file("bash_fg2.lua"), file("bash_fg3.lua")
    start_agent("fg")
    prompt()
    follow.focus_slot(1)
    list = shown_files(function()
      result(bash(("cat %s %s %s"):format(f1, f2, f3), "fg"), "local x1 = 1", "fg")
      turn_end()
      vim.wait(1200)
    end)
    assert.are.same({ "bash_fg1.lua" }, list, "the steps went on")
  end)

  it("end the steps when show_user or a typed preview moves the view", function()
    fresh()
    local a, b, c = file("bash_u1.lua"), file("bash_u2.lua"), file("bash_u3.lua")
    local shown = file("bash_u_shown.lua")
    prompt()
    bash(("cat %s %s %s"):format(a, b, c))
    assert.are.same(a, code_file())
    assert.is_nil(helpers.ask("show_user", { path = shown, start_line = 2, end_line = 3 }).error)
    vim.wait(1200)
    assert.are.same({ shown, 2 }, { code_file(), code_line() }, "the steps went on over show_user")
    require("anvim.tools").clear()

    local edited = file("bash_u_edited.lua")
    start_agent("ty")
    follow.focus_slot(1)
    bash(("cat %s %s %s"):format(a, b, c), "ty")
    assert.are.same(a, code_file())
    sidecar.dispatch({
      type = "await_preview",
      req = 9100,
      tool_use_id = "bash_typed_edit",
      agent_id = "ty",
      name = "Edit",
      input = { file_path = edited, old_string = "local x2 = 2", new_string = "local x2 = 20" },
    })
    assert.is_true(require("anvim.stream").typed("bash_typed_edit"))
    vim.wait(1200)
    assert.are.same(edited, code_file(), "the steps went on over a typed preview")
    sidecar.dispatch({
      type = "tool_result",
      id = "bash_typed_edit",
      is_error = false,
      text = "The file has been updated successfully.",
      parent_id = "tu_ty",
      agent_id = "ty",
    })
  end)

  it("show a grep's first hit and flash its file's hits, at the tool result", function()
    fresh()
    local g = file("bash_g.lua", 40)
    local other = file("bash_g_other.lua")
    prompt()
    local before = code_file()
    local id = bash("grep -n x bash_g.lua | head -20")
    assert.are.same(before, code_file(), "a grep moves nothing before its result")
    result(id, "3:local x3 = 3\n7:local x7 = 7\n39:local x39 = 39\n")
    assert.are.same({ g, 3 }, { code_file(), code_line() })
    assert.are.same({ 3, 7 }, flashed(g), "the hits in view flash")

    id = bash("grep -rn x . ; echo ---")
    result(id, "bash_g_other.lua:5:local x5 = 5\nbash_g.lua:9:local x9 = 9\n---\n")
    assert.are.same({ other, 5 }, { code_file(), code_line() })
    assert.are.same({ 5 }, flashed(other))

    elsewhere()
    id = bash("grep -n x bash_g.lua")
    result(id, "12:local x12 = 12")
    assert.are.same(other, code_file())
    assert.are.same("⏺ Claude at bash_g.lua:12 +1", follow.status())
  end)

  it("show a subagent's grep hits from its result text", function()
    fresh()
    local g = file("bash_ga.lua")
    start_agent("s2")
    prompt()
    follow.focus_slot(1)
    local id = bash("grep -n x " .. g, "s2")
    result(id, "4:local x4 = 4", "s2")
    assert.are.same({ g, 4 }, { code_file(), code_line() })
  end)

  it("resolve paths where Claude Code's shell is, which stays from call to call", function()
    fresh()
    vim.fn.mkdir(helpers.tmp .. "/shell/sub", "p")
    local notes = helpers.tmp .. "/shell/sub/notes.md"
    vim.fn.writefile({ "# Notes" }, notes)
    local sub = helpers.tmp .. "/shell/sub"
    -- The shapes of these results come from live sessions and from Claude
    -- Code's Bash tool.
    ---@param opts { agent: string?, input: table?, result: any, is_error: boolean?, text: string? }?
    local function call(command, opts)
      opts = opts or {}
      sidecar.dispatch({
        type = "tool_result",
        id = bash(command, opts.agent, opts.input),
        is_error = opts.is_error or false,
        text = opts.text or "(Bash completed with no output)",
        result = opts.result or { stdout = "", stderr = "", interrupted = false },
        parent_id = opts.agent and "tu_" .. opts.agent or nil,
        agent_id = opts.agent,
      })
    end
    local function reads(command)
      return vim.tbl_map(function(read)
        return read.path
      end, bashread.reads({ name = "Bash", input = { command = command } }))
    end

    call("cd shell/sub")
    assert.are.same(sub, bashread.cwd())
    prompt()
    bash("cat notes.md")
    assert.are.same(notes, code_file())

    call("cd .. && cat missing.md", {
      is_error = true,
      text = "Exit code 1\ncat: missing.md: No such file or directory",
      result = "Error: Exit code 1\ncat: missing.md: No such file or directory",
    })
    assert.are.same(sub, bashread.cwd(), "a call that exits 1 leaves the shell where it was")
    call("cd .. && grep -n nothing notes.md", {
      text = "No matches found",
      result = { stdout = "", stderr = "", interrupted = false, returnCodeInterpretation = "No matches found" },
    })
    assert.are.same(sub, bashread.cwd(), "a grep without a match exits 1, but its result is no error")

    local reset = "\nShell cwd was reset to " .. helpers.tmp
    call("cd /tmp && pwd", { text = "/tmp" .. reset, result = { stdout = "/tmp", stderr = reset } })
    assert.are.same(helpers.tmp, bashread.cwd())

    call("cd shell", { agent = "s9" })
    assert.are.same(helpers.tmp, bashread.cwd(), "Claude Code keeps a subagent's shell where it is")
    assert.are.same({ notes }, reads("cat shell/sub/notes.md"))

    call("cd shell", {
      input = { run_in_background = true },
      text = "Command running in background with ID: b1.",
      result = { stdout = "", stderr = "", interrupted = false, backgroundTaskId = "b1" },
    })
    assert.are.same(helpers.tmp, bashread.cwd(), "a call in the background")
    call("cd shell && sleep 600", {
      text = "Command running in background with ID: b2.",
      result = { stdout = "", stderr = "", interrupted = false, backgroundTaskId = "b2" },
    })
    assert.are.same(helpers.tmp, bashread.cwd(), "a call that went to the background later")

    vim.env.CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR = "true"
    call("cd shell")
    vim.env.CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR = nil
    assert.are.same(helpers.tmp, bashread.cwd(), "Claude Code puts the shell back after each call")

    call("cd $SOMEWHERE")
    assert.is_false(bashread.cwd(), "a cd that the parser cannot follow")
    assert.are.same({}, reads("cat shell/sub/notes.md"))
    assert.are.same({ notes }, reads("cat " .. notes))
    call("cd " .. helpers.tmp .. " && ls")
    assert.are.same(helpers.tmp, bashread.cwd(), "an absolute cd finds the way back")
    call("git commit -m \"$(cat <<'EOF'\nfix: source maps, cd and pushd\nEOF\n)\"")
    assert.are.same(helpers.tmp, bashread.cwd(), "a commit message")

    call("cd shell")
    sidecar.dispatch({ type = "reset" })
    assert.is_false(bashread.cwd(), "/clear may keep the shell where it is")
  end)
end)
