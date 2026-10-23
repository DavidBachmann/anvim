---@module "luassert"

local config = require("anvim.config")
local helpers = require("helpers")
local input = require("anvim.input")
local reload = require("anvim.reload")
local sessions = require("anvim.sessions")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

local api = vim.api

describe("reload", function()
  it("waits for the turn's end, and restarts with the session, its settings and the draft", function()
    helpers.start()
    local saved = {
      debug = config.options.debug,
      replay = config.options.replay,
      chosen = config.mode_chosen,
      id = state.session_id,
      mode = state.permission_mode,
      tui = reload.tui,
      exec = reload.exec,
    }
    local env = {}
    for _, name in ipairs(reload.vars) do
      env[name] = vim.env[name]
    end
    local seen
    -- The specs play a recording, which a real reload refuses.
    config.options.debug, config.options.replay, config.mode_chosen = true, nil, false
    reload.tui = function()
      return true
    end
    reload.exec = function()
      seen = {}
      for _, name in ipairs(reload.vars) do
        seen[name] = vim.env[name]
      end
    end
    state.session_id = "reload-session"
    sessions.model = "haiku"
    vim.env.ANVIM_CONTINUE = "1"
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "half a", "thought" })

    local ok, err = pcall(function()
      sidecar.dispatch({ type = "init", session_id = "reload-session", permission_mode = "bypassPermissions" })
      sidecar.dispatch({ type = "turn_start" })
      -- Shift-Tab chose plan mode.
      state.permission_mode = "plan"
      local reply = helpers.ask("reload", {})
      assert(reply.result and reply.result:find("End your turn"), vim.inspect(reply))
      vim.wait(200)
      assert.is_nil(seen, "the turn still runs")

      sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
      assert(
        vim.wait(2000, function()
          return seen ~= nil
        end),
        "no restart after the turn's end"
      )
      local marker = vim.json.decode(seen.ANVIM_RELOADED)
      seen.ANVIM_RELOADED = nil
      -- The start mode that nobody chose stays unchosen.
      assert.are.same({ ANVIM_RESUME = "reload-session", ANVIM_MODEL = "haiku" }, seen)
      assert.are.same({ session_id = "reload-session", mode = "plan", draft = { "half a", "thought" } }, marker)
    end)

    for name, value in pairs(env) do
      vim.env[name] = value
    end
    config.options.debug, config.options.replay, config.mode_chosen = saved.debug, saved.replay, saved.chosen
    state.session_id, state.permission_mode = saved.id, saved.mode
    reload.tui, reload.exec, sessions.model = saved.tui, saved.exec, nil
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    assert(ok, err)
  end)

  it("does not restart after the user stops Claude", function()
    helpers.start()
    local saved = {
      debug = config.options.debug,
      replay = config.options.replay,
      id = state.session_id,
      tui = reload.tui,
      exec = reload.exec,
    }
    local restarted = false
    config.options.debug, config.options.replay = true, nil
    reload.tui = function()
      return true
    end
    reload.exec = function()
      restarted = true
    end
    state.session_id = "reload-stop"

    local ok, err = pcall(helpers.capture_sends, function()
      sidecar.dispatch({ type = "init", session_id = "reload-stop", permission_mode = "bypassPermissions" })
      sidecar.dispatch({ type = "turn_start" })
      local reply = helpers.ask("reload", {})
      assert(reply.result, vim.inspect(reply))
      input.interrupt()
      sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
      vim.wait(300)
      assert.is_false(restarted, "the restart undid the stop")
    end)

    config.options.debug, config.options.replay, state.session_id = saved.debug, saved.replay, saved.id
    reload.tui, reload.exec = saved.tui, saved.exec
    assert(ok, err)
  end)

  it("starts with the marker: sends one prompt after the history, and clears the env", function()
    helpers.start()
    local id = state.session_id
    local env = {}
    for _, name in ipairs(reload.vars) do
      env[name] = vim.env[name]
    end
    vim.env.ANVIM_RELOADED = vim.json.encode({ session_id = "reloaded", draft = { "kept" } })
    vim.env.ANVIM_RESUME = "reloaded"

    local prompts = {}
    local ok, err = pcall(helpers.capture_sends, function(sent)
      reload.attach()
      for _, name in ipairs(reload.vars) do
        assert.is_nil(vim.env[name], name)
      end
      assert.are.same({ "kept" }, api.nvim_buf_get_lines(input.buf(), 0, -1, false))
      vim.wait(500)
      assert.are.same({}, sent, "no prompt before the history")
      sidecar.dispatch({ type = "history", session_id = "reloaded", events = {} })
      sidecar.dispatch({ type = "history", session_id = "reloaded", events = {} })
      vim.wait(2000, function()
        return #sent > 0
      end)
      vim.wait(200)
      prompts = vim.tbl_filter(function(msg)
        return msg.type == "prompt"
      end, sent)
    end)

    for name, value in pairs(env) do
      vim.env[name] = value
    end
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    state.session_id = id
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
    assert(ok, err)
    assert.are.same(1, #prompts)
    local text = prompts[1].text
    assert(text:find("^%[Sent by anvim, not by the user%]%(mcp__anvim__reload%): ") and text:find("commit %x+"), text)
    local shown = table.concat(api.nvim_buf_get_lines(require("anvim.transcript").buf(), 0, -1, false), "\n")
    assert(shown:find("✻ anvim restarted") and not shown:find("❯ %[Sent by anvim"), shown)
  end)
end)
