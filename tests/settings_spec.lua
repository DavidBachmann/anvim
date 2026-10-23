---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")

describe("settings", function()
  before_each(function()
    helpers.start()
  end)

  it("/status shows the login, and <Tab> goes through the usage, the context, MCP and Chrome", function()
    local layout = require("anvim.layout")
    vim.api.nvim_set_current_win(layout.wins.input)
    local buf
    helpers.capture_sends(function(sent)
      vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "/status" })
      input.submit()
      buf = vim.api.nvim_get_current_buf()
      assert.are.same("anvim_settings", vim.bo[buf].filetype)
      sidecar.dispatch({
        type = "session_info",
        info = { version = "2.1.304", login = "Claude Team account", email = "a@b.c", mcp = "1 connected" },
      })
      assert(helpers.contains(helpers.buf_lines(buf), "^ Email +a@b%.c$"))

      vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
      assert.are.same({ { type = "session_info" }, { type = "usage" } }, sent)
    end)
    sidecar.dispatch({
      type = "usage",
      usage = {
        session = { title = "Session", lines = { "Total cost: $1.00" } },
        limits = { { title = "Current session", percent = 50, resets_at = os.time() + 3600 } },
        windows = {},
      },
    })
    local lines = helpers.buf_lines(buf)
    assert(helpers.contains(lines, "^   Total cost: %$1%.00$"))
    assert(helpers.contains(lines, "^ " .. ("█"):rep(25) .. ("░"):rep(25) .. " 50%% used$"))
    assert.is_false(vim.bo[buf].modifiable)

    helpers.capture_sends(function(sent)
      vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
      assert.are.same({ { type = "context_usage" } }, sent)
    end)
    sidecar.dispatch({
      type = "context_usage",
      context = {
        title = "claude-opus-5-5 · 10k/1m tokens (1%)",
        grid = { { { glyph = "⛁", color = "claude" }, { glyph = "⛶", color = "promptBorder" } } },
        legend = { { glyph = "⛁", color = "claude", text = "Memory files: 10k tokens (1.0%)" } },
        sections = { { title = "Memory files", lines = { "Project: ~/dev/anvim/CLAUDE.md (4.4k)" } } },
      },
    })
    lines = helpers.buf_lines(buf)
    assert(helpers.contains(lines, "^ ⛁ ⛶   claude%-opus%-5%-5 · 10k/1m tokens %(1%%%)$"))
    assert(helpers.contains(lines, "^       ⛁ Memory files: 10k tokens"))

    helpers.capture_sends(function(sent)
      vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
      sidecar.dispatch({
        type = "mcp_servers",
        servers = {
          { name = "anvim", status = "connected", scope = "sdk", tools = { "show_user" }, own = true },
          { name = "notion", status = "disabled", scope = "claudeai", tools = {} },
        },
      })
      lines = helpers.buf_lines(buf)
      assert(helpers.contains(lines, "^ ✔ anvim   connected · 1 tool  sdk$"))
      assert.are.same(1, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
      assert(helpers.contains(helpers.buf_lines(buf), "^     show_user$"))
      vim.api.nvim_feedkeys("Gt", "mx", false)
      assert.are.same({ type = "mcp_action", action = "enable", server = "notion" }, sent[#sent])
      assert(helpers.contains(helpers.buf_lines(buf), "^ Turning on notion%.%.%.$"))
    end)

    local chrome = {
      allowed = true,
      subscriber = true,
      wsl = false,
      installed = true,
      status = "connected",
      browser = "Browser 1",
      enabled_by_default = false,
      skips_checks = true,
      urls = { install = "i", reconnect = "r", permissions = "p" },
    }
    helpers.capture_sends(function(sent)
      vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
      assert.are.same({ type = "chrome" }, sent[#sent])
      sidecar.dispatch({ type = "chrome", chrome = chrome })
      assert(helpers.contains(helpers.buf_lines(buf), "^ Browser: Browser 1$"))
      assert.are.same(" Select browser...", vim.api.nvim_get_current_line())
      vim.api.nvim_feedkeys("3j" .. vim.keycode("<CR>"), "mx", false)
      assert.are.same({ type = "chrome_default", enabled = true }, sent[#sent])
    end)

    -- Without Chrome in this session, Reconnect restarts Claude with it.
    local sessions = require("anvim.sessions")
    local restart = sessions.restart
    local restarted
    sessions.restart = function()
      restarted = sessions.chrome_flag()
    end
    sidecar.dispatch({ type = "chrome", chrome = vim.tbl_extend("force", chrome, { status = "absent" }) })
    local ok, err = pcall(function()
      vim.api.nvim_feedkeys("k", "mx", false)
      assert.are.same(" Reconnect extension", vim.api.nvim_get_current_line())
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "mx", false)
    end)
    sessions.restart, sessions.chrome = restart, nil
    assert(ok, err)
    assert.is_true(restarted)
    assert.are.same(-1, vim.fn.bufwinid(buf))
  end)

  it("q closes the window", function()
    local layout = require("anvim.layout")
    vim.api.nvim_set_current_win(layout.wins.input)
    require("anvim.settings").open("status")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_feedkeys("q", "mx", false)
    assert.are.same(-1, vim.fn.bufwinid(buf))
    assert.are.same(layout.wins.input, vim.api.nvim_get_current_win())
  end)
end)
