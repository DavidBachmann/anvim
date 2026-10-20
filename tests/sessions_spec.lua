---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sessions = require("anvim.sessions")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local api = vim.api
local buf_lines = helpers.buf_lines

local now = 1792477569004
local list = {
  {
    id = "9b0fe4b4-4c79-44ac-be0c-7ccce0301a50",
    title = "Notes.lua line count and comment",
    modified = now - 5 * 60 * 1000,
    created = now - 2 * 86400 * 1000,
    size = 601959,
    branch = "main",
    first_prompt = "Do these three steps",
  },
  { id = "6d2410d5-bdc2-40a7-a972-2ae28eae2c6e", title = "Say hi", modified = now - 30 * 1000, size = 2048 },
}

-- Replaces fn on a module while fn runs, and records its calls.
local function stub(mod, name, fn)
  local calls, orig = {}, mod[name]
  mod[name] = function(...)
    calls[#calls + 1] = { ... }
    if fn then
      return fn(...)
    end
  end
  return calls, function()
    mod[name] = orig
  end
end

-- The recorded turn's events, as the plugin got them live.
local function recorded()
  local events = {}
  for _, frame in ipairs(vim.fn.readfile(helpers.recording)) do
    events[#events + 1] = vim.json.decode(frame:sub(frame:find(" ") + 1), { luanil = { object = true, array = true } })
  end
  return events
end

local live = {
  text_start = transcript.text_start,
  text_delta = function(ev)
    transcript.text_delta(ev.text)
  end,
  text_stop = transcript.text_stop,
  tool_start = function(ev)
    transcript.tool_start(ev.id, ev.name)
  end,
  tool_field = transcript.tool_field,
  tool_use = transcript.tool_use,
  tool_result = transcript.tool_result,
  turn_end = transcript.turn_end,
}

describe("sessions", function()
  local model
  before_each(function()
    helpers.start()
    model = state.model
  end)

  -- Other specs check the model that the replay's init named.
  after_each(function()
    state.model, sessions.model = model, nil
  end)

  it("lists sessions for the picker: title, time, size and which one is open", function()
    state.session_id = list[2].id
    local items = sessions.items(list, now)
    assert.are.same(
      { "Notes.lua line count and comment", "Say hi" },
      vim.tbl_map(function(i)
        return i.text
      end, items)
    )
    assert.are.same({ "5 min ago", "just now" }, { items[1].ago, items[2].ago })
    assert.are.same({ "588 KB", "2 KB" }, { items[1].size, items[2].size })
    assert.are.same({ false, true }, { items[1].current, items[2].current })
    assert.are.same(list[1].id, items[1].id)
    local preview = items[1].preview.text
    assert(preview:find("Do these three steps", 1, true), preview)
    assert(preview:find("Branch `main`", 1, true), preview)
    assert(preview:find("Created 2 days ago", 1, true), preview)
    assert.are.same("2 h ago", sessions.ago(now - 2 * 3600 * 1000, now))
    assert.are.same("yesterday", sessions.ago(now - 86400 * 1000, now))
    state.session_id = nil
  end)

  it("opens the picker with this directory's sessions, and a choice resumes one", function()
    local shown = {}
    local _, unfetch = stub(sessions, "fetch", function(cb)
      cb(list)
    end)
    local _, unshow = stub(sessions, "show_picker", function(items)
      shown = items
    end)
    local restarts, unrestart = stub(sidecar, "restart")
    sessions.pick()
    unfetch()
    unshow()
    assert.are.same(2, #shown)
    sessions.resume(shown[1].id)
    unrestart()
    assert.are.same(1, #restarts)
    local cmd = restarts[1][1]
    assert.are.same({ "start", list[1].id, true, state.cwd }, { cmd.type, cmd.resume, cmd.history, cmd.cwd })
    assert.are.same({ "✻ Resuming session " .. list[1].id }, buf_lines(transcript.buf()))
  end)

  it("draws a resumed session the way the live turn looked", function()
    local events = recorded()
    -- Live: the recorded turn, field by field and in text chunks.
    transcript.clear()
    transcript.user("Add a comment")
    for _, ev in ipairs(events) do
      if live[ev.type] then
        live[ev.type](ev)
      end
    end
    local want = buf_lines(transcript.buf())
    assert(#want > 4, table.concat(want, "\n"))

    -- Resumed: the events that a saved session gives. One text delta per
    -- block, and no tool results but a Read's line count.
    local past, text = { { type = "user", text = "Add a comment" } }, nil
    for _, ev in ipairs(events) do
      if ev.type == "text_delta" then
        text = (text or "") .. ev.text
      elseif ev.type == "text_stop" then
        vim.list_extend(past, { { type = "text_start" }, { type = "text_delta", text = text }, { type = "text_stop" } })
        text = nil
      elseif ev.type == "tool_use" then
        past[#past + 1] = ev
      elseif ev.type == "tool_result" then
        local r = ev.result
        local lines = type(r) == "table" and r.file and r.file.numLines
        past[#past + 1] = vim.tbl_extend("force", ev, { result = lines and { file = { numLines = lines } } or vim.NIL })
      end
    end
    for _, ev in ipairs(past) do
      if ev.result == vim.NIL then
        ev.result = nil
      end
    end
    sidecar.dispatch({ type = "history", session_id = "s-resumed", events = past })
    assert.are.same(want, buf_lines(transcript.buf()))
    assert.are.same("s-resumed", state.session_id)
    assert(state.turns > 0, "a resumed session can be resumed again")
  end)

  it("draws a long resumed session fast: 300 prompts with 4 tools each", function()
    local cwd = state.cwd
    local events = {}
    for i = 1, 300 do
      events[#events + 1] = { type = "user", text = "prompt " .. i }
      for j = 1, 4 do
        local tid = ("big%d_%d"):format(i, j)
        local read = j % 2 == 0
        events[#events + 1] = {
          type = "tool_use",
          id = tid,
          name = read and "Read" or "Bash",
          input = read and { file_path = cwd .. "/a.lua" } or { command = "ls " .. cwd },
        }
        events[#events + 1] = {
          type = "tool_result",
          id = tid,
          is_error = false,
          text = ("line\n"):rep(50),
          result = read and { file = { numLines = 50 } } or nil,
        }
      end
      vim.list_extend(events, {
        { type = "text_start" },
        { type = "text_delta", text = "Here is **bold** and `code`.\n\n```lua\nlocal x = 1\n```\n" },
        { type = "text_stop" },
      })
    end
    local t0 = vim.uv.hrtime()
    sidecar.dispatch({ type = "history", session_id = "big", events = events })
    vim.cmd.redraw()
    local ms = (vim.uv.hrtime() - t0) / 1e6
    assert(api.nvim_buf_line_count(transcript.buf()) > 6000)
    assert(ms < 1000, ("300 prompts took %d ms"):format(ms))
    -- Conceal is back on for the transcript window.
    assert.are.same(2, vim.wo[require("anvim.layout").wins.transcript].conceallevel)
    transcript.clear()
  end)

  it("/clear empties the transcript, and the next init names the new session", function()
    transcript.user("/clear")
    state.session_id, state.cost_usd, state.turns = "old", 0.5, 3
    state.last_turn = { duration_ms = 1000, cost_usd = 0.5 }
    sidecar.dispatch({ type = "reset" })
    assert.are.same({ "" }, buf_lines(transcript.buf()))
    assert.are.same({ 0, 0 }, { state.cost_usd, state.turns })
    assert.is_nil(state.last_turn)
    sidecar.dispatch({ type = "init", session_id = "new", model = state.model, permission_mode = state.permission_mode })
    assert.are.same("new", state.session_id)
  end)

  it(":AnvimRestart resumes a session that has saved a turn, and starts a new one otherwise", function()
    local restarts, unrestart = stub(sidecar, "restart")
    state.session_id, state.turns = "s1", 2
    vim.cmd.AnvimRestart()
    state.turns = 0
    sessions.restart()
    unrestart()
    assert.are.same({ "s1", nil }, { restarts[1][1].resume, restarts[2][1].resume })
    assert.are.same(state.cwd, restarts[2][1].cwd)
    local all = buf_lines(transcript.buf())
    assert.are.same(
      { "✻ Restarting Claude in this session", "", "✻ Restarting Claude" },
      vim.list_slice(all, #all - 2)
    )
  end)

  it("starts a new session after /clear, and finishes cut tool calls as interrupted", function()
    local restarts, unrestart = stub(sidecar, "restart")
    sidecar.dispatch({ type = "reset" })
    sidecar.dispatch({
      type = "init",
      session_id = "after-clear",
      model = state.model,
      permission_mode = state.permission_mode,
    })
    -- /clear's own turn asked no model and saved nothing to resume.
    sidecar.dispatch({
      type = "turn_end",
      subtype = "success",
      is_error = false,
      duration_ms = 20,
      cost_usd = 0,
      num_turns = 0,
    })
    transcript.user("Run it")
    transcript.tool_start("cut1", "Bash")
    transcript.tool_use({ id = "cut1", name = "Bash", input = { command = "sleep 100" } })
    sessions.restart()
    unrestart()
    assert.is_nil(restarts[1][1].resume)
    local all = buf_lines(transcript.buf())
    assert.are.same({ "⏺ Bash(sleep 100)", "  ⎿  Interrupted" }, vim.list_slice(all, 3, 4))
  end)

  it("restarts the sidecar process, and what was sent meanwhile reaches the new one", function()
    -- The replay sidecar plays its recording from the start again, init first.
    local function restart()
      state.process = "starting"
      sidecar.restart(sessions.start_command())
    end
    restart()
    sidecar.send({ type = "prompt", text = "Add a comment" })
    assert(
      vim.wait(10000, function()
        return state.process == "ready"
      end),
      "the new sidecar sent init"
    )
    local turns = state.turns
    assert(
      vim.wait(10000, function()
        return state.turns > turns and not state.busy
      end),
      "the new sidecar played a turn for the prompt sent during the restart"
    )
    -- The specs after this one get a replay that has not played its turn yet.
    restart()
    assert(vim.wait(10000, function()
      return state.process == "ready"
    end))
  end)

  it("stops a sidecar that hangs, and starts the new one", function()
    local config = require("anvim.config")
    local replay = config.options.sidecar_cmd
    -- Never reads its stdin, so closing it does nothing.
    config.options.sidecar_cmd = { "sleep", "30" }
    state.process = "starting"
    sidecar.restart(sessions.start_command())
    -- The replay exits at once, and sleep starts in its place.
    vim.wait(1000)
    config.options.sidecar_cmd = replay
    assert.are.same("starting", state.process)
    local t0 = vim.uv.hrtime()
    sidecar.restart(sessions.start_command())
    assert(
      vim.wait(8000, function()
        return state.process == "ready"
      end),
      "the replay sidecar did not come back"
    )
    local secs = (vim.uv.hrtime() - t0) / 1e9
    assert(secs >= 1.9, ("the hung sidecar went after %.1f s, before its signal"):format(secs))
  end)

  it("picks a model from Claude Code's list and switches to it", function()
    local running, unrunning = stub(sidecar, "running", function()
      return true
    end)
    local choices
    local _, unselect = stub(vim.ui, "select", function(items, _, on_choice)
      choices = items
      on_choice(items[2])
    end)
    helpers.capture_sends(function(sent)
      sessions.pick_model()
      assert.are.same({ type = "list_models" }, sent[1])
      sidecar.dispatch({
        type = "models",
        models = {
          { value = "default", name = "Default (recommended)", description = "Opus 5.5", resolved = "claude-opus-5-5" },
          { value = "haiku", name = "Haiku 5.5", description = "Fastest", resolved = "claude-haiku-5-5" },
        },
      })
      assert.are.same({ type = "set_model", model = "haiku" }, sent[2])
    end)
    unselect()
    unrunning()
    assert(#running > 0)
    assert.are.same(2, #choices)
    assert.are.same("claude-haiku-5-5", state.model)
    local footer = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, input.footer(80)))
    assert(footer:find("Haiku 5.5", 1, true), footer)
    local all = buf_lines(transcript.buf())
    assert.are.same("✻ Set model to Haiku 5.5", all[#all])
    -- A restart keeps the chosen model.
    assert.are.same("haiku", sessions.start_command().model)
  end)

  it("adds /resume and /model to Claude Code's commands for the completion", function()
    local completion = require("anvim.completion")
    local before = completion.commands
    sidecar.dispatch({ type = "commands", commands = { { name = "compact", description = "Summarize" } } })
    assert.are.same(
      { "compact", "resume", "model" },
      vim.tbl_map(function(c)
        return c.name
      end, completion.commands)
    )
    sidecar.dispatch({ type = "commands", commands = { { name = "model", description = "Claude Code's own" } } })
    assert.are.same(
      { "model", "resume" },
      vim.tbl_map(function(c)
        return c.name
      end, completion.commands)
    )
    completion.commands = before
  end)

  it("runs /resume and /model itself, and sends other slash commands to Claude", function()
    local picks, unpick = stub(sessions, "pick")
    local models, unmodels = stub(sessions, "pick_model")
    helpers.capture_sends(function(sent)
      assert(sessions.command("/resume"))
      assert(sessions.command("/model"))
      assert(sessions.command("/model sonnet"))
      assert.are.same({ type = "set_model", model = "sonnet" }, sent[1])
      assert.is_false(sessions.command("/clear"))
      assert.is_false(sessions.command("/compact keep the notes"))
      assert.is_false(sessions.command("explain /resume"))
    end)
    unpick()
    unmodels()
    assert.are.same({ 1, 1 }, { #picks, #models })
  end)
end)
