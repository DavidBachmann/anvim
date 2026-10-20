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
    state.model, sessions.model, state.effort = model, nil, nil
    sessions.effort_choice, sessions.models, require("anvim.config").options.effort = nil, nil, nil
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

  it("adds /resume, /model and /effort to Claude Code's commands, in place of Claude Code's own", function()
    local completion = require("anvim.completion")
    local before = completion.commands
    local function names()
      return vim.tbl_map(function(c)
        return c.name
      end, completion.commands)
    end
    sidecar.dispatch({ type = "commands", commands = { { name = "compact", description = "Summarize" } } })
    assert.are.same({ "compact", "resume", "model", "effort" }, names())
    sidecar.dispatch({
      type = "commands",
      commands = {
        { name = "model", description = "Claude Code's own", argument_hint = "<model>", builtin = true },
        { name = "usage", description = "Show plan usage", builtin = true },
        {
          name = "effort",
          description = "Set effort level for model usage",
          argument_hint = "<low|medium|high|xhigh|max|auto|ultracode [on|off]>",
          builtin = true,
        },
      },
    })
    assert.are.same({ "model", "usage", "effort", "resume" }, names())
    assert.are.same("[model]", completion.commands[1].argument_hint)
    assert.are.same("[level]", completion.commands[3].argument_hint)
    -- Claude Code's hint offers words that do more than set a level.
    local menu = vim.inspect(completion.command_items(0, 1))
    assert.is_nil(menu:find("ultracode", 1, true), menu)
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

  local haiku = {
    value = "haiku",
    name = "Haiku 5.5",
    resolved = "claude-haiku-5-5",
    effort_levels = { "low", "medium", "high", "xhigh", "max" },
  }
  local old = { value = "claude-haiku-4-5-20251001", name = "Haiku 4.5", resolved = "claude-haiku-4-5-20251001" }

  local function footer()
    return table.concat(vim.tbl_map(function(c)
      return c[1]
    end, input.footer(100)))
  end

  local function last_line()
    local all = buf_lines(transcript.buf())
    return all[#all]
  end

  it("/effort <level> sets the effort, and a restart keeps it", function()
    local config = require("anvim.config")
    sessions.models, state.model = { haiku, old }, "claude-haiku-5-5"
    config.options.effort = "medium"
    assert.are.same("medium", sessions.start_command().effort)
    helpers.capture_sends(function(sent)
      assert(sessions.command("/effort high"))
      assert.are.same({ { type = "set_effort", effort = "high" } }, sent)
      assert.are.same("✻ Set effort to high", last_line())
      assert.are.same("high", sessions.start_command().effort)
      assert.are.same("high", sessions.start_command({ resume = "s1" }).effort)

      -- The default wins over the option, also after a restart, which starts
      -- without an effort, as a new session does.
      assert(sessions.command("/effort default"))
      assert.are.same({ type = "set_effort", effort = vim.NIL }, sent[2])
      assert.are.same("✻ Set effort to default (your settings, else the model's)", last_line())
      assert.is_nil(sessions.start_command().effort)
      assert.is_nil(sessions.start_command({ resume = "s1" }).effort)
    end)
  end)

  it("the footer shows the effort that Claude Code reports, and drops it in a narrow column", function()
    state.model = "claude-haiku-5-5"
    assert.is_nil(footer():find("Haiku 5.5 ·", 1, true), footer())
    sidecar.dispatch({ type = "effort", level = "xhigh" })
    assert(footer():find("Haiku 5.5 · xhigh", 1, true), footer())
    -- A model without effort. JSON's null arrives as nil.
    sidecar.dispatch({ type = "effort" })
    assert.is_nil(state.effort)
    assert.is_nil(footer():find("Haiku 5.5 ·", 1, true), footer())

    sidecar.dispatch({ type = "effort", level = "high" })
    local function text(width)
      return table.concat(vim.tbl_map(function(c)
        return c[1]
      end, input.footer(width)))
    end
    local wide = text(200)
    assert(wide:find("Haiku 5.5 · high", 1, true), wide)
    -- The effort goes once the dots and the other parts that go first are gone.
    local width = vim.api.nvim_strwidth((wide:gsub("%s+$", ""))) - 6
    while text(width):find(" · high", 1, true) do
      width = width - 1
    end
    local narrow = text(width)
    assert(narrow:find("Haiku 5.5", 1, true), narrow)
    assert.is_nil(narrow:find("shift+tab", 1, true), narrow)
  end)

  it("/effort opens a picker of the model's levels, whose first item is the default", function()
    local choices, pick = nil, 1
    local _, unselect = stub(vim.ui, "select", function(items, opts, on_choice)
      choices = vim.tbl_map(opts.format_item, items)
      on_choice(items[pick])
    end)
    sessions.models, state.model = { haiku, old }, "claude-haiku-5-5"
    local default = "default (your settings, else the model's)"
    helpers.capture_sends(function(sent)
      -- Without a choice in this session, no row is the current one.
      sessions.effort_choice, pick = nil, nil
      assert(sessions.command("/effort"))
      assert.are.same({ "  " .. default, "  low", "  medium", "  high", "  xhigh", "  max" }, choices)
      assert.are.same({}, sent)
      sessions.effort_choice, pick = "medium", 1
      assert(sessions.command("/effort"))
      assert.are.same({ "  " .. default, "  low", "⏺ medium", "  high", "  xhigh", "  max" }, choices)
      assert.are.same({ type = "set_effort", effort = vim.NIL }, sent[1])
      pick = nil
      assert(sessions.command("/effort"))
      assert.are.same("⏺ " .. default, choices[1])

      -- Without Claude Code's list, as in a replay, it offers every level.
      sessions.models, choices, pick = nil, nil, 3
      assert(sessions.command("/effort"))
      assert.are.same(6, #choices)
      assert.are.same({ type = "set_effort", effort = "medium" }, sent[2])

      -- A model without effort levels gets a notice.
      sessions.models, state.model, choices = { haiku, old }, old.resolved, nil
      assert(sessions.command("/effort"))
      assert.is_nil(choices)
      assert.are.same("✻ Haiku 4.5 has no effort levels.", last_line())
      assert.are.same(2, #sent)
    end)
    unselect()
  end)

  it("refuses a level that the model lacks or that anvim does not offer, and sends nothing", function()
    sessions.models, state.model =
      { vim.tbl_extend("force", haiku, { effort_levels = { "low", "medium", "high" } }) }, "claude-haiku-5-5"
    helpers.capture_sends(function(sent)
      assert(sessions.command("/effort max"))
      assert.are.same("✻ Haiku 5.5 has no max effort. It has low, medium and high.", last_line())
      assert(sessions.command("/effort turbo"))
      assert.are.same("✻ /effort takes low, medium, high or default.", last_line())
      -- Claude Code takes words for /effort that turn on more than an effort.
      for _, text in ipairs({ "/effort ultracode", "/effort ultracode on", "/effort ULTRACODE off" }) do
        assert(sessions.command(text), text)
        assert.are.same("✻ /effort takes low, medium, high or default.", last_line())
      end
      local buf = input.buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/effort ultracode on" })
      input.submit()
      assert.are.same({}, sent)
      -- Claude Code answers these itself.
      assert.is_false(sessions.command("/effort current"))
    end)
    assert.is_nil(sessions.effort())
  end)

  it("keeps the effort over a model switch, as Claude Code does, and says so when the model lacks it", function()
    sessions.models, state.model, sessions.effort_choice = { haiku, old }, "claude-haiku-5-5", "high"
    helpers.capture_sends(function(sent)
      sessions.set_model(old)
      assert.are.same({ type = "set_model", model = old.value }, sent[1])
      assert.are.same("✻ Haiku 4.5 has no high effort. Claude Code keeps it for a model that has it.", last_line())
      assert.are.same("high", sessions.start_command().effort)
      sessions.set_model(haiku)
      assert.are.same("✻ Set model to Haiku 5.5", last_line())
      -- The default follows the model, so a switch says nothing about it.
      sessions.effort_choice = false
      sessions.set_model(old)
      assert.are.same("✻ Set model to Haiku 4.5", last_line())
    end)
  end)

  it("drops an effort option that is no level, with a warning", function()
    local config = require("anvim.config")
    local options = config.options
    local notes, unnotify = stub(vim, "notify")
    config.setup({ effort = "turbo" })
    local dropped = config.options.effort
    config.setup({ effort = "" })
    local empty = config.options.effort
    config.setup({ effort = "xhigh" })
    local kept = config.options.effort
    config.options = options
    vim.wait(100, function()
      return #notes > 0
    end)
    unnotify()
    assert.are.same({ nil, nil, "xhigh" }, { dropped, empty, kept })
    assert.are.same(1, #notes)
    assert(notes[1][1]:find('"turbo" is unknown', 1, true), notes[1][1])
    assert.are.same(vim.log.levels.WARN, notes[1][2])
    helpers.capture_sends(function(sent)
      assert.is_nil(sessions.start_command().effort)
      assert.are.same({}, sent)
    end)
  end)

  it("refuses a typed built-in that does nothing here, and sends the rest to Claude", function()
    local completion = require("anvim.completion")
    local commands, terminal = completion.commands, completion.terminal
    completion.commands = {
      { name = "color", description = "Set the prompt bar color", builtin = true },
      { name = "usage", description = "Show plan usage", aliases = { "cost" }, builtin = true },
      { name = "focus", description = "A user's own command" },
    }
    completion.terminal = { "color", "focus" }
    local buf = input.buf()
    helpers.capture_sends(function(sent)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/color red" })
      input.submit()
      assert.are.same({}, sent)
      assert.are.same("✻ /color works only in Claude Code's terminal. Run `claude` for it.", last_line())
      assert.are.same({ "" }, buf_lines(buf))
      for _, text in ipairs({ "/usage", "/cost", "/focus on", "/help" }) do
        assert.is_false(sessions.command(text), text)
      end
    end)
    completion.commands, completion.terminal = commands, terminal
  end)

  it("starts no paid cloud review, also before Claude Code's list came", function()
    local completion = require("anvim.completion")
    local commands = completion.commands
    completion.commands = {}
    local buf = input.buf()
    helpers.capture_sends(function(sent)
      for _, text in ipairs({ "/ultrareview", "/ultrareview 42", "/code-review ultra", "/code-review Ultra --post" }) do
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
        input.submit()
        assert.are.same({}, sent, text)
        assert.are.same(
          "✻ anvim starts no paid cloud review. Run /ultrareview or /code-review ultra in Claude Code.",
          last_line(),
          text
        )
      end
      for _, text in ipairs({ "/code-review", "/code-review high", "/code-review ultrafast" }) do
        assert.is_false(sessions.command(text), text)
      end
    end)
    completion.commands = commands
  end)
end)
