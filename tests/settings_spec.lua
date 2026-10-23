---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")

describe("settings", function()
  before_each(function()
    helpers.start()
  end)

  it("/status shows the login, <Tab> goes through the usage, the context and MCP, and q closes the window", function()
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

    vim.api.nvim_feedkeys("q", "mx", false)
    assert.are.same(-1, vim.fn.bufwinid(buf))
    assert.are.same(layout.wins.input, vim.api.nvim_get_current_win())
  end)
end)
