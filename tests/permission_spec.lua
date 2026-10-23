---@module "luassert"

local config = require("anvim.config")
local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local permission = require("anvim.permission")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local api = vim.api
local buf_lines, field = helpers.buf_lines, helpers.field

-- The specs press keys right after a request opens, and <Esc> twice at once.
permission.guard_ms = 0
input.esc_pause_ms = 0

-- Typed keys. A call that ends in insert mode leaves it, as if <Esc> was typed,
-- so a typed answer goes in one call with the key that starts it.
local function keys(str)
  api.nvim_feedkeys(api.nvim_replace_termcodes(str, true, false, true), "mx", false)
end

-- The prompt in normal mode, where the choice keys work.
local function focus()
  api.nvim_set_current_win(layout.wins.input)
  vim.cmd.stopinsert()
end

-- The last lines of the transcript, where an open request shows.
local function tail(n)
  local lines = buf_lines(transcript.buf())
  return vim.list_slice(lines, #lines - n + 1)
end

local next_req = 500

-- A tool line in the transcript.
local function tool(name, input_)
  next_req = next_req + 1
  local id = "perm" .. next_req
  sidecar.dispatch({ type = "tool_start", id = id, name = name })
  sidecar.dispatch({ type = "tool_use", id = id, name = name, input = input_ })
  return id
end

-- Asks for permission to run a tool, the way the sidecar does.
local function ask(id, name, input_, extra)
  next_req = next_req + 1
  local event = { type = "permission_request", req = next_req, tool_use_id = id, tool = name, input = input_ }
  sidecar.dispatch(vim.tbl_extend("force", event, extra or {}))
  return next_req
end

local function request(name, input_, extra)
  local id = tool(name, input_)
  return ask(id, name, input_, extra), id
end

local function result(id, is_error, text)
  sidecar.dispatch({ type = "tool_result", id = id, is_error = is_error, text = text or "ok" })
end

local mkdir = { command = "mkdir -p out", description = "Make the output dir" }
local remember = "Yes, and don't ask again for Bash(mkdir -p out) in this project"

describe("permission", function()
  -- A failed case must not leave a request open for the next one.
  after_each(permission.cancel_all)

  it("shows a Bash request as a block and allows once with 1", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      local req, id = request("Bash", mkdir, { remember = remember, description = mkdir.description })
      assert.are.same({
        "  Bash command",
        "    mkdir -p out",
        "    Make the output dir",
        "  Do you want to proceed?",
        "  ❯ 1. Yes",
        "    2. " .. remember,
        "    3. No, and tell Claude what to do differently (esc twice)",
      }, tail(7))
      assert.are.same("", tail(8)[1], "a blank line separates the block from the tool line")
      assert(permission.waiting())
      assert(input.activity():find("To answer: 1-3, or j/k and enter", 1, true), input.activity())
      assert.are.same("n", api.nvim_get_mode().mode)

      keys("1")
      assert.are.same({ { type = "permission_response", req = req, behavior = "allow" } }, sent)
      assert(not permission.waiting())
      assert.is_nil(state.waiting)
      assert.are.same("⏺ Bash(mkdir -p out)", tail(1)[1], "the block is gone")
      assert.are.same("", vim.fn.maparg("1", "n", false, false), "choice keys are unmapped")
      result(id, false, "(Bash completed with no output)")
      assert.are.same("  ⎿  (Bash completed with no output)", tail(1)[1])
    end)
  end)

  it("denies with esc, and shows the rejection as the tool's result", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      local req, id = request("Bash", { command = "make" })
      assert.are.same("    2. No, and tell Claude what to do differently (esc twice)", tail(1)[1])
      keys("<Esc><Esc>")
      assert.are.same({ { type = "permission_response", req = req, behavior = "deny" } }, sent)
      result(id, true, "The user doesn't want to proceed with this tool use.")
      assert.are.same("  ⎿  Rejected", tail(1)[1])
    end)
  end)

  it("sends what the user types after 3 as the deny message, then restores the draft", function()
    helpers.start()
    focus()
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "my draft" })
    helpers.capture_sends(function(sent)
      local req, id = request("Bash", mkdir, { remember = remember })
      keys("3Name it build<CR>")
      assert.are.same(
        { { type = "permission_response", req = req, behavior = "deny", message = "Name it build" } },
        sent
      )
      assert.are.same({ "my draft" }, buf_lines(input.buf()))
      assert(not permission.waiting())
      result(id, true, "rejected")
      assert.are.same("  ⎿  Rejected: Name it build", tail(1)[1])
    end)
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("drops the request when the sidecar cancels it", function()
    helpers.start()
    focus()
    local before = #buf_lines(transcript.buf())
    helpers.capture_sends(function(sent)
      local req, id = request("Bash", mkdir)
      sidecar.dispatch({ type = "permission_cancel", req = req })
      assert.are.same({}, sent)
      assert(not permission.waiting())
      assert.are.same(before + 2, #buf_lines(transcript.buf()), "only the tool line and its blank line stay")
      assert.are.same("", vim.fn.maparg("1", "n", false, false))
      keys("1")
      assert.are.same({}, sent, "1 no longer chooses")
      result(id, true, "Interrupted")
    end)
  end)

  it("shows one request at a time, in order", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      -- A message streams all its tool calls before Claude Code asks about them.
      local id1, id2 = tool("Bash", { command = "make one" }), tool("Bash", { command = "make two" })
      local first = ask(id1, "Bash", { command = "make one" })
      local second = ask(id2, "Bash", { command = "make two" })
      assert.are.same("    make one", tail(5)[2])
      keys("1")
      assert.are.same("    make two", tail(5)[2])
      keys("<Esc><Esc>")
      assert.are.same({
        { type = "permission_response", req = first, behavior = "allow" },
        { type = "permission_response", req = second, behavior = "deny" },
      }, sent)
      result(id1, false)
      result(id2, true)
    end)
  end)

  it("ignores choices right after a request opens", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      permission.guard_ms = 60000
      local ok, err = pcall(function()
        local req, id = request("Bash", { command = "make" })
        keys("1<CR>")
        assert.are.same({}, sent)
        keys("j")
        assert.are.same(
          "  ❯ 2. No, and tell Claude what to do differently (esc twice)",
          tail(1)[1],
          "moving still works"
        )
        permission.guard_ms = 0
        keys("1")
        assert.are.same({ { type = "permission_response", req = req, behavior = "allow" } }, sent)
        result(id, false)
      end)
      permission.guard_ms = 0
      assert(ok, err)
    end)
  end)

  it("never answers from insert mode: enter there keeps the prompt", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      local req, id = request("Bash", { command = "rm -rf build" })
      keys("Arun the build in step 2<CR><CR>")
      assert.are.same({}, sent, "enter neither answered nor sent the prompt")
      assert(permission.waiting())
      assert.are.same({ "run the build in step 2" }, buf_lines(input.buf()))
      keys("1")
      assert.are.same({ { type = "permission_response", req = req, behavior = "allow" } }, sent)
      assert.are.same({ "run the build in step 2" }, buf_lines(input.buf()), "the draft stays")
      result(id, false)
    end)
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("leaves the prompt in normal mode after a send and after an answer, also when the user was typing", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      local req
      api.nvim_create_user_command("AnvimSpecAsk", function()
        req = request("Bash", { command = "make" })
      end, {})
      -- Each call ends insert mode, so the mode counts as the call reads it.
      local mode = "<Cmd>let g:anvim_spec_mode = mode()<CR>"
      keys("Ahello<CR>" .. mode)
      assert.are.same("n", vim.g.anvim_spec_mode, "the send left insert mode")
      assert.are.same("hello", sent[#sent].text)
      keys("Adraft<Cmd>AnvimSpecAsk<CR><Esc>1" .. mode)
      assert.are.same({ type = "permission_response", req = req, behavior = "allow" }, sent[#sent])
      assert.are.same("n", vim.g.anvim_spec_mode, "the answer started insert mode")
      assert.are.same({ "draft" }, buf_lines(input.buf()))
    end)
    api.nvim_del_user_command("AnvimSpecAsk")
    vim.g.anvim_spec_mode = nil
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
  end)

  it("answers only a request in view, and brings it back when read mode ends", function()
    helpers.start()
    focus()
    local tr = layout.wins.transcript
    local function at_end()
      return vim.fn.line("w$", tr) == api.nvim_buf_line_count(transcript.buf())
    end
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(helpers.capture_sends, function(sent)
      for i = 1, 60 do
        transcript.notice("warn", "line " .. i)
      end
      local id1, id2 = tool("Bash", { command = "make one" }), tool("Bash", { command = "make two" })
      local first = ask(id1, "Bash", { command = "make one" })
      local second = ask(id2, "Bash", { command = "make two" })
      require("anvim.windows").read()
      keys("gg")
      sidecar.dispatch({ type = "permission_cancel", req = first })
      assert(not at_end(), "read mode keeps the view where the user reads")
      keys("q")
      assert.are.same(layout.wins.input, api.nvim_get_current_win())
      assert(at_end(), "leaving read mode brings the request into view")
      keys("<C-u><C-u>")
      assert(not at_end(), "<C-u> did not scroll the request out of view")
      keys("1")
      assert.are.same({}, sent, "a request out of view takes no answer")
      assert(at_end(), "the key brought the request back into view")
      keys("1")
      assert.are.same({ { type = "permission_response", req = second, behavior = "allow" } }, sent)
      result(id1, true)
      result(id2, false)
    end)
    vim.notify = notify
    assert(ok, err)
  end)

  it("counts the guard from the last character typed in the prompt", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      permission.guard_ms = 300
      local ok, err = pcall(function()
        local req, id = request("Bash", { command = "make" })
        vim.wait(350)
        keys("Ax<Esc>1")
        keys("<Esc>")
        assert.are.same({}, sent, "a choice right after typing does nothing")
        vim.wait(350)
        keys("1")
        assert.are.same({ { type = "permission_response", req = req, behavior = "allow" } }, sent)
        result(id, false)
      end)
      permission.guard_ms = 0
      assert(ok, err)
    end)
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("warns about a path outside the working directory", function()
    helpers.start()
    focus()
    helpers.capture_sends(function()
      local _, outside = request("Bash", { command = "cat /etc/hosts" }, { blocked_path = "/etc/hosts" })
      assert.are.same("    outside the working directory: /etc/hosts", tail(6)[3])
      keys("<Esc><Esc>")
      result(outside, true)
      local _, inside = request("Bash", { command = "mkdir build" }, { blocked_path = helpers.tmp .. "/build" })
      assert.are.same(
        { "    mkdir build", "  Do you want to proceed?" },
        vim.list_slice(tail(4), 1, 2),
        "a path inside it gets no line"
      )
      keys("<Esc><Esc>")
      result(inside, true)
    end)
  end)

  it("asks for a sandboxed command's network access, and remembers the host in this project", function()
    helpers.start()
    api.nvim_set_current_win(layout.code_win())
    local before = buf_lines(transcript.buf())
    local notes, notify = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local ok, err = pcall(helpers.capture_sends, function(sent)
      -- As the sidecar sends it: no tool line has its tool_use_id, and no agent.
      local req = ask("77718261-f1b0-40e7-bf1e-07736e97f24c", "SandboxNetworkAccess", { host = "example.com" }, {
        remember = "Yes, and don't ask again for WebFetch(domain:example.com) in this project",
        description = "Allow network connection to example.com?",
      })
      assert.are.same({ "Claude is waiting for your answer to a network request, in the prompt" }, notes)
      -- A background agent may have sent it, so it outlives the main turn.
      sidecar.dispatch({
        type = "turn_end",
        subtype = "success",
        is_error = false,
        duration_ms = 1,
        cost_usd = 0,
        num_turns = 1,
      })
      assert(permission.waiting(), "the request stays at the turn's end")
      assert.are.same({}, sent)
      focus()
      assert.are.same({
        "  Network access",
        "    example.com",
        "  Do you want to allow this connection?",
        "  ❯ 1. Yes",
        "    2. Yes, and don't ask again for WebFetch(domain:example.com) in this project",
        "    3. No, and tell Claude what to do differently (esc twice)",
      }, tail(6))
      keys("2")
      assert.are.same({ { type = "permission_response", req = req, behavior = "allow", remember = true } }, sent)
      assert.are.same(before, buf_lines(transcript.buf()), "the block goes, and nothing else changed")
    end)
    vim.notify = notify
    assert(ok, err)
  end)

  it("titles a Bash command that asks to run outside the sandbox", function()
    helpers.start()
    focus()
    helpers.capture_sends(function()
      local _, id = request("Bash", { command = "rm -rf ~/.cache/x", dangerouslyDisableSandbox = true })
      assert.are.same({ "  Bash command (unsandboxed)", "    rm -rf ~/.cache/x" }, vim.list_slice(tail(5), 1, 2))
      keys("<Esc><Esc>")
      result(id, true)
    end)
  end)

  it("draws why anvim's own guard asks, in WarningMsg, without a remember choice", function()
    helpers.start()
    focus()
    local ns = api.nvim_get_namespaces()["anvim.transcript"]
    -- The highlight groups of the transcript's last line that reads text.
    local function groups(text)
      local buf = transcript.buf()
      local lines = buf_lines(buf)
      for row = #lines, 1, -1 do
        if lines[row] == text then
          local found = {}
          for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
            found[#found + 1] = mark[4].hl_group
          end
          return found
        end
      end
      error(("no line %q"):format(text))
    end
    local cases = {
      { "Bash", { command = "rm ~/x", dangerouslyDisableSandbox = true }, "runs outside the sandbox" },
      { "Bash", { command = "touch ~/x" }, "runs outside the sandbox (excluded command)" },
      { "Write", { file_path = "/etc/hosts", content = "x" }, "outside the trusted dirs: /etc/hosts" },
      { "Edit", { file_path = helpers.tmp .. "/.claude/settings.json" }, "changes the sandbox's settings" },
      { "Write", { file_path = helpers.tmp .. "/.mcp.json" }, "changes a config that runs outside the sandbox" },
    }
    helpers.capture_sends(function()
      for _, case in ipairs(cases) do
        local _, id = request(case[1], case[2], { reason = case[3], blocked_path = "/etc/hosts" })
        assert.are.same({ "WarningMsg" }, groups("    " .. case[3]), case[3])
        assert.are.same({
          "  ❯ 1. Yes",
          "    2. No, and tell Claude what to do differently (esc twice)",
        }, tail(2))
        -- The reason takes the place of the blocked path's line.
        assert(not vim.tbl_contains(tail(8), "    outside the working directory: /etc/hosts"), case[3])
        keys("<Esc><Esc>")
        result(id, true)
      end
    end)
  end)

  it("replays a recorded sandbox session: a denial, an escape, a network request and an edit outside", function()
    helpers.start()
    focus()
    local fixture = helpers.root .. "/tests/fixtures/sandbox-session.jsonl"
    -- The recording's paths outside the project are in its home dir.
    local home = vim.env.HOME
    local home_repl = (home .. "/"):gsub("%%", "%%%%")
    local blocks = {}
    helpers.capture_sends(function(sent)
      for _, frame in ipairs(vim.fn.readfile(fixture)) do
        frame = frame:gsub("/ANVIM_FIXTURE", helpers.tmp):gsub("/Users/user/", home_repl)
        local ev = vim.json.decode(frame:match("^%d+ (.*)$"), { luanil = { object = true, array = true } })
        if ev.type:match("^tool_") or ev.type:match("^text_") or ev.type:match("^permission_") then
          sidecar.dispatch(ev)
        elseif ev.type == "await_preview" then
          sidecar.dispatch(ev)
          assert(
            vim.wait(3000, function()
              return vim.tbl_contains(sent, function(msg)
                return msg.type == "preview_done" and msg.req == ev.req
              end, { predicate = true })
            end),
            "preview did not catch up"
          )
        end
        if ev.type == "permission_request" then
          blocks[#blocks + 1] = tail(8)
          -- The recording denied the escape and the Write, and allowed the rest.
          keys((ev.reason and "<Esc><Esc>" or "1"))
        end
      end
      local answers = vim.tbl_map(
        function(msg)
          return msg.behavior
        end,
        vim.tbl_filter(function(msg)
          return msg.type == "permission_response"
        end, sent)
      )
      assert.are.same({ "allow", "deny", "allow", "allow", "deny" }, answers)
    end)
    assert.are.same(5, #blocks)
    -- The first touch asks as any Bash command does, and the sandbox denies it.
    helpers.contains(blocks[1], "^    outside the working directory: ~/anvim%-sandbox%-probe/target%.txt$")
    -- Claude retries outside the sandbox. anvim's guard asks, with no "don't ask again".
    assert.are.same({
      "  Bash command (unsandboxed)",
      "    touch " .. home .. "/anvim-sandbox-probe/target.txt",
      "    Create or update target.txt via touch",
      "    runs outside the sandbox",
      "  Do you want to proceed?",
      "  ❯ 1. Yes",
      "    2. No, and tell Claude what to do differently (esc twice)",
    }, vim.list_slice(blocks[2], 2))
    assert.are.same({
      "  Network access",
      "    example.com",
      "  Do you want to allow this connection?",
      "  ❯ 1. Yes",
      "    2. Yes, and don't ask again for WebFetch(domain:example.com) in this project",
      "    3. No, and tell Claude what to do differently (esc twice)",
    }, vim.list_slice(blocks[4], 3))
    assert.are.same({
      "  Write file",
      "    ~/anvim-sandbox-probe/notes.txt",
      "    outside the trusted dirs: ~/anvim-sandbox-probe/notes.txt",
      "  Do you want to create notes.txt?",
      "  ❯ 1. Yes",
      "    2. No, and tell Claude what to do differently (esc twice)",
    }, vim.list_slice(blocks[5], 3), "Claude Code's description, the ~ path, shows no second time")
    assert(not permission.waiting())
    local lines = buf_lines(transcript.buf())
    helpers.contains(lines, "Operation not permitted")
    helpers.contains(lines, "^  ⎿  Rejected$")
    helpers.contains(lines, "HTTP/1%.1 200 Connection Established")
  end)

  it("opens on No and takes no single-key yes when Claude Code asks for care", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      local req, id = request("Bash", { command = "rm -rf out" }, { default_to_no = true })
      assert.are.same("  ❯ 2. No, and tell Claude what to do differently (esc twice)", tail(1)[1])
      assert(not state.waiting:find("1%-2"), state.waiting)
      keys("1")
      assert.are.same({}, sent)
      keys("k<CR>")
      assert.are.same({ { type = "permission_response", req = req, behavior = "allow" } }, sent)
      result(id, false)
    end)
  end)

  it("restores the file when the user denies a streamed Edit", function()
    helpers.start()
    local file = helpers.tmp .. "/deny.lua"
    vim.fn.writefile({ "local a = 1", "return a" }, file)
    focus()
    helpers.capture_sends(function(sent)
      sidecar.dispatch({ type = "tool_start", id = "pe1", name = "Edit" })
      field("pe1", "Edit", "file_path", "end", file)
      field("pe1", "Edit", "old_string", "end", "local a = 1")
      field("pe1", "Edit", "new_string", "delta", "local a = 2")
      field("pe1", "Edit", "new_string", "end", "local a = 2")
      local edit = { file_path = file, old_string = "local a = 1", new_string = "local a = 2" }
      sidecar.dispatch({ type = "tool_use", id = "pe1", name = "Edit", input = edit })
      sidecar.dispatch({ type = "await_preview", req = 61, tool_use_id = "pe1" })
      local buf = vim.fn.bufnr(file)
      assert(
        vim.wait(2000, function()
          return #sent > 0
        end),
        "preview did not catch up"
      )
      assert.are.same({ "local a = 1", "local a = 2", "return a" }, buf_lines(buf), "the edit shows before the prompt")
      sidecar.dispatch({
        type = "permission_request",
        req = 62,
        tool_use_id = "pe1",
        tool = "Edit",
        input = edit,
        remember = "Yes, allow all edits during this session",
        description = "deny.lua",
      })
      assert.are.same({
        "  Edit file",
        "    deny.lua",
        "  Do you want to make this edit to deny.lua?",
        "  ❯ 1. Yes",
        "    2. Yes, allow all edits during this session",
        "    3. No, and tell Claude what to do differently (esc twice)",
      }, tail(6))
      keys("<Esc><Esc>")
      assert.are.same({ type = "permission_response", req = 62, behavior = "deny" }, sent[2])
      -- Claude Code answers a deny with an error result, which ends the preview.
      result("pe1", true, "The user doesn't want to proceed with this tool use.")
      assert.are.same({ "local a = 1", "return a" }, buf_lines(buf))
      assert.are.same({}, helpers.hl_groups(buf, "anvim.stream"), "preview marks are gone")
      assert(not vim.bo[buf].modified)
    end)
  end)

  it("asks single and multi-select questions, with typed answers", function()
    helpers.start()
    focus()
    local form = {
      questions = {
        {
          question = "Which greeting?",
          header = "Greeting",
          multiSelect = false,
          options = { { label = "Hello", description = "Formal" }, { label = "Hi", description = "Casual" } },
        },
        {
          question = "Which languages?",
          header = "Languages",
          multiSelect = true,
          options = {
            { label = "English", description = "" },
            { label = "French", description = "" },
            { label = "German", description = "" },
          },
        },
      },
    }
    helpers.capture_sends(function(sent)
      local req, id = request("AskUserQuestion", form)
      assert.are.same({
        "  ☐ Greeting (1 of 2)",
        "  Which greeting?",
        "  ❯ 1. Hello",
        "       Formal",
        "    2. Hi",
        "       Casual",
        "    3. Other (type an answer)",
      }, tail(7))
      keys("2")
      assert.are.same({
        "  ✔ Greeting: Hi",
        "  ☐ Languages (2 of 2)",
        "  Which languages?",
        "  ❯ 1. [ ] English",
        "    2. [ ] French",
        "    3. [ ] German",
        "    4. Other (type an answer)",
        "    5. Submit",
      }, tail(8))
      keys("1")
      keys("3")
      keys("3")
      assert.are.same(
        { "  ❯ 1. [x] English", "    2. [ ] French", "    3. [ ] German" },
        vim.list_slice(tail(5), 1, 3)
      )
      keys("4Spanish, but formal<CR>")
      assert.are.same("    4. Other: Spanish, but formal", tail(2)[1])
      assert.are.same({}, sent)
      keys("5")
      assert.are.same({
        {
          type = "permission_response",
          req = req,
          behavior = "allow",
          answers = { ["Which greeting?"] = { "Hi" }, ["Which languages?"] = { "English", "Spanish, but formal" } },
        },
      }, sent)
      result(id, false, "Your questions have been answered.")
      assert.are.same("  ⎿  Greeting → Hi · Languages → English, Spanish, but formal", tail(1)[1])
    end)
  end)

  it("shows the plan, approves with auto-accept edits, and keeps the plan", function()
    helpers.start()
    focus()
    local plan = "# Plan\n\n1. Write greet.lua\n2. Test it"
    -- Without bypass mode at the start, Claude Code offers accept edits first.
    config.options.permission_mode = "default"
    helpers.capture_sends(function(sent)
      -- Claude Code adds the plan file's path to the input it asks about.
      local id = tool("ExitPlanMode", { plan = plan })
      local req = ask(id, "ExitPlanMode", { plan = plan, planFilePath = "/tmp/plan.md" })
      assert.are.same({
        "  Ready to code?",
        "  Here is Claude's plan:",
        "  # Plan",
        "",
        "  1. Write greet.lua",
        "  2. Test it",
        "  Would you like to proceed?",
        "  ❯ 1. Yes, auto-accept edits",
        "    2. Yes, manually approve edits",
        "    3. No, keep planning",
      }, tail(10))
      keys("1")
      assert.are.same({ { type = "permission_response", req = req, behavior = "allow", mode = "acceptEdits" } }, sent)
      assert.are.same(
        { "  Claude's plan:", "  # Plan", "", "  1. Write greet.lua", "  2. Test it" },
        tail(5),
        "the plan stays"
      )
      result(id, false, "User has approved your plan.")
      local lines = buf_lines(transcript.buf())
      local at = #lines - 6
      assert.are.same(
        { "⏺ ExitPlanMode(# Plan...)", "  ⎿  Approved, auto-accept edits", "" },
        vim.list_slice(lines, at - 1, at + 1)
      )
    end)
    config.options.permission_mode = "bypassPermissions"
  end)

  it("offers bypass for the plan when anvim started in bypass mode", function()
    helpers.start()
    focus()
    helpers.capture_sends(function(sent)
      local req, id = request("ExitPlanMode", { plan = "# Plan" })
      assert.are.same({
        "  ❯ 1. Yes, and switch to BYPASS PERMISSIONS for this session",
        "    2. Yes, manually approve edits",
        "    3. No, keep planning",
      }, tail(3))
      keys("1")
      assert.are.same(
        { { type = "permission_response", req = req, behavior = "allow", mode = "bypassPermissions" } },
        sent
      )
      result(id, false, "User has approved your plan.")
      helpers.contains(buf_lines(transcript.buf()), "^  ⎿  Approved, bypass permissions$")
    end)
  end)

  it("answers a recorded default-mode Edit after its preview", function()
    helpers.start()
    focus()
    local file = helpers.tmp .. "/matchparen.lua"
    local fixture = helpers.root .. "/tests/fixtures/permission-session.jsonl"
    local asked = {}
    helpers.capture_sends(function(sent)
      for _, frame in ipairs(vim.fn.readfile(fixture)) do
        frame = frame:gsub("/ANVIM_FIXTURE", helpers.tmp)
        local ev = vim.json.decode(frame:match("^%d+ (.*)$"), { luanil = { object = true, array = true } })
        if ev.type:match("^tool_") or ev.type:match("^text_") or ev.type:match("^permission_") then
          sidecar.dispatch(ev)
        elseif ev.type == "await_preview" then
          -- The sidecar asks for permission only after the preview caught up.
          sidecar.dispatch(ev)
          assert(
            vim.wait(3000, function()
              return vim.tbl_contains(sent, function(msg)
                return msg.type == "preview_done" and msg.req == ev.req
              end, { predicate = true })
            end),
            "preview did not catch up"
          )
        end
        if ev.type == "permission_request" then
          asked[#asked + 1] = ev.tool
          local lines = buf_lines(vim.fn.bufnr(file))
          assert.are.same("local api = vim.api", lines[1], "the old text is still there, struck through")
          helpers.contains(lines, "^%-%- Highlights the bracket")
          assert.are.same("  Do you want to make this edit to matchparen.lua?", tail(4)[1])
          assert.are.same("    2. Yes, allow all edits during this session", tail(2)[1])
          keys("1")
        end
      end
      local answers = vim.tbl_filter(function(msg)
        return msg.type == "permission_response"
      end, sent)
      assert.are.same({ { type = "permission_response", req = 1, behavior = "allow" } }, answers)
    end)
    assert.are.same({ "Edit" }, asked)
    assert(not permission.waiting())
    local lines = buf_lines(transcript.buf())
    helpers.contains(lines, "^⏺ Edit%(matchparen%.lua%)$")
    helpers.contains(lines, "^  ⎿  Added 1 line, removed 0 lines$")
    assert.are.same("local api = vim.api", buf_lines(vim.fn.bufnr(file))[1], "the buffer shows the file on disk")
  end)
end)
