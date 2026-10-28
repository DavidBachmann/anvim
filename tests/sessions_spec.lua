---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sessions = require("anvim.sessions")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

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

  it("sends the sandbox option, which anvim's spec reads from ANVIM_SANDBOX", function()
    local config = require("anvim.config")
    local was, env = config.options.sandbox, vim.env.ANVIM_SANDBOX
    config.options.sandbox = false
    local sent_off = sessions.start_command().sandbox
    config.options.sandbox = true
    local sent_on = sessions.start_command().sandbox
    config.options.sandbox = was
    local spec = helpers.root .. "/lua/anvim/plugins/anvim.lua"
    vim.env.ANVIM_SANDBOX = "0"
    local spec_off = dofile(spec)[1].opts.sandbox
    vim.env.ANVIM_SANDBOX = nil
    local spec_on = dofile(spec)[1].opts.sandbox
    vim.env.ANVIM_SANDBOX = env
    assert.are.same({ false, true, false, true }, { sent_off, sent_on, spec_off, spec_on })
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

  it(":AnvimRestart restarts Claude with the default notice", function()
    local restarts, unrestart = stub(sidecar, "restart")
    local ok, err = pcall(vim.cmd.AnvimRestart)
    unrestart()
    assert(ok, err)
    assert.are.same(1, #restarts)
    helpers.contains(buf_lines(transcript.buf()), "Restarting Claude")
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
    local status = require("anvim.statusline").render()
    assert(status:find("Haiku 5.5", 1, true), status)
    local all = buf_lines(transcript.buf())
    assert.are.same("✻ Set model to Haiku 5.5", all[#all])
    -- A restart keeps the chosen model.
    assert.are.same("haiku", sessions.start_command().model)
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

  it("/reset sends /clear, and its reset deletes the todo list; a plain /clear keeps it", function()
    local todos = require("anvim.todos")
    local function todo_rows()
      return vim.tbl_filter(function(l)
        return l:find("Before the reset", 1, true) ~= nil
      end, buf_lines(transcript.buf()))
    end
    helpers.fresh()
    helpers.capture_sends(function(sent)
      todos.set({ { id = 1, subject = "Before the reset", status = "pending" } })
      assert.are.same(1, #todo_rows())
      vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "/reset" })
      input.submit()
      assert.are.same({ "prompt", "/clear" }, { sent[1].type, sent[1].text })
      sidecar.dispatch({ type = "reset" })
      assert.are.same({ type = "todo_reset" }, sent[2])
      -- No frame shows the old list after the clear.
      assert.are.same({}, todos.items)
      assert.are.same({}, todo_rows())
      -- A plain /clear sends no todo_reset.
      todos.set({ { id = 1, subject = "Before the reset", status = "pending" } })
      assert.is_false(sessions.command("/clear"))
      sidecar.dispatch({ type = "reset" })
      assert.are.same(2, #sent)
      assert.are.same(1, #todo_rows())
      assert(sessions.command("/undo-reset"))
      assert.are.same({ type = "todo_reset", undo = true }, sent[3])
      -- A /reset that <Up> took back from the queue deletes nothing.
      assert(sessions.command("/reset"))
      sidecar.dispatch({ type = "prompt_state", id = sent[4].id, state = "cancelled" })
      sidecar.dispatch({ type = "reset" })
      assert.are.same(4, #sent)
      assert.are.same(1, #todo_rows())
    end)
    input.set_busy(false)
    todos.set({})
  end)

  local haiku = {
    value = "haiku",
    name = "Haiku 5.5",
    resolved = "claude-haiku-5-5",
    effort_levels = { "low", "medium", "high", "xhigh", "max" },
  }
  local old = { value = "claude-haiku-4-5-20251001", name = "Haiku 4.5", resolved = "claude-haiku-4-5-20251001" }

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

  it("/codex-effort <level> keeps the level, and the next Codex run gets it", function()
    local prefs = require("anvim.prefs")
    helpers.capture_sends(function(sent)
      assert(sessions.command("/codex-effort low"))
      assert.are.same({ { type = "set_codex_defaults", model = vim.NIL, effort = "low" } }, sent)
      assert.are.same("low", prefs.get("codex_effort"))
      assert.are.same("low", sessions.start_command().codex_effort)
      assert(sessions.command("/codex-effort default"))
      assert.are.same({ type = "set_codex_defaults", model = vim.NIL, effort = vim.NIL }, sent[2])
      assert.is_nil(prefs.get("codex_effort"))
    end)
  end)

  it("/codex-model takes only a model in Codex's model list, when anvim has the list", function()
    local prefs = require("anvim.prefs")
    local saved = { state.codex, state.codex_config, state.codex_models }
    sidecar.dispatch({
      type = "codex",
      state = "on",
      models = {
        { slug = "gpt-6.1-terra", name = "GPT-6.1 Terra", hidden = false, efforts = { "low", "xhigh" } },
        { slug = "gpt-reserve", name = "GPT-Reserve", hidden = true, efforts = { "low" } },
      },
    })
    local ok, err = pcall(helpers.capture_sends, function(sent)
      assert(sessions.command("/codex-model 6.1-terra"))
      assert.are.same({}, sent)
      assert.matches("Its models: gpt%-6%.1%-terra %(GPT%-6%.1 Terra%)$", last_line())
      assert(sessions.command("/codex-model gpt-6.1-terra"))
      assert.are.same({ { type = "set_codex_defaults", model = "gpt-6.1-terra", effort = vim.NIL } }, sent)
      -- A hidden model is not listed, but Codex takes it.
      assert(sessions.command("/codex-model gpt-reserve"))
      assert.are.same({ type = "set_codex_defaults", model = "gpt-reserve", effort = vim.NIL }, sent[2])
    end)
    prefs.set("codex_model", nil)
    state.codex, state.codex_config, state.codex_models = unpack(saved)
    assert(ok, err)
  end)

  it("starts in default mode without a sandbox, unless the user chose a mode", function()
    local config = require("anvim.config")
    local saved = { config.options, config.mode_chosen, config.mode_reason }
    local function start(opts)
      config.setup(opts)
      local cmd = sessions.start_command()
      return { cmd.permission_mode, cmd.permission_mode_chosen, cmd.sandbox }
    end
    local ok, err = pcall(function()
      assert.are.same({ "bypassPermissions", false, true }, start({}))
      -- An empty ANVIM_MODE chooses nothing.
      assert.are.same({ "bypassPermissions", false, true }, start({ permission_mode = "" }))
      assert.are.same({ "default", false, false }, start({ sandbox = false }))
      assert.are.same("the sandbox is off, and no mode was chosen", config.mode_reason)
      assert.are.same(
        { "bypassPermissions", true, false },
        start({ sandbox = false, permission_mode = "bypassPermissions" })
      )
      assert.are.same({ "acceptEdits", true, false }, start({ sandbox = false, permission_mode = "acceptEdits" }))
      assert.are.same({ "plan", true, true }, start({ permission_mode = "plan" }))
    end)
    config.options, config.mode_chosen, config.mode_reason = unpack(saved)
    assert(ok, err)
  end)

  it("takes the sidecar's fallback to default mode as the start mode, for one start", function()
    local config = require("anvim.config")
    local saved = {
      config.options.permission_mode,
      state.permission_mode,
      config.mode_reason,
      config.mode_chosen,
      config.fell_back,
    }
    local ok, err = pcall(function()
      config.options.permission_mode, state.permission_mode = "bypassPermissions", "bypassPermissions"
      config.mode_chosen = false
      require("anvim.sidecar").dispatch({ type = "start_mode", mode = "default" })
      assert.are.same({ "default", "default" }, { config.options.permission_mode, state.permission_mode })
      assert.are.same("the sandbox cannot start, and no mode was chosen", config.mode_reason)
      assert.are.same({ "default", "acceptEdits", "plan" }, input.modes(), "Shift-Tab offers no bypass")
      local status = require("anvim.statusline").render()
      assert(not status:find("manual mode", 1, true), status)
      -- The next start, as after :AnvimRestart or /resume, lets the sidecar check the sandbox again.
      local cmd = sessions.start_command()
      assert.are.same({ "bypassPermissions", false }, { cmd.permission_mode, cmd.permission_mode_chosen })
      assert.are.same(
        { "bypassPermissions", "bypassPermissions" },
        { config.options.permission_mode, state.permission_mode }
      )
      assert.are.same("it is anvim's default, and the sandbox is on", config.mode_reason)
      assert.is_false(config.fell_back)
    end)
    config.options.permission_mode, state.permission_mode, config.mode_reason, config.mode_chosen, config.fell_back =
      unpack(saved)
    assert(ok, err)
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
