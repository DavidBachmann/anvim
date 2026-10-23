---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")

describe("settings", function()
  before_each(function()
    helpers.start()
  end)

  it("/status shows the login, <Tab> shows the usage, and q closes the window", function()
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

    vim.api.nvim_feedkeys("q", "mx", false)
    assert.are.same(-1, vim.fn.bufwinid(buf))
    assert.are.same(layout.wins.input, vim.api.nvim_get_current_win())
  end)
end)
