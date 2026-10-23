---@module "luassert"

local helpers = require("helpers")
local notify = require("anvim.notify")
local sidecar = require("anvim.sidecar")

local api = vim.api

local turn_end =
  { type = "turn_end", subtype = "success", is_error = false, duration_ms = 5, cost_usd = 0, num_turns = 1 }

-- What the notifications would run or write, instead of running it.
local calls
local env = {}

local function set_env(vars)
  for _, key in ipairs({ "CMUX_SOCKET_PATH", "CMUX_SURFACE_ID", "CMUX_BUNDLED_CLI_PATH" }) do
    vim.env[key] = vars[key]
  end
end

describe("notify", function()
  before_each(function()
    helpers.start()
    for _, key in ipairs({ "CMUX_SOCKET_PATH", "CMUX_SURFACE_ID", "CMUX_BUNDLED_CLI_PATH" }) do
      env[key] = vim.env[key]
    end
    calls = {}
    notify.system = function(cmd)
      calls[#calls + 1] = { cmd = cmd }
    end
    notify.ui_send = function(text)
      calls[#calls + 1] = { osc = text }
    end
  end)

  after_each(function()
    set_env(env)
    notify.system, notify.ui_send = vim.system, function(text)
      api.nvim_ui_send(text)
    end
    api.nvim_exec_autocmds("FocusGained", {})
  end)

  it("uses cmux notify for this surface while unfocused, and OSC 9 outside cmux", function()
    set_env({ CMUX_SOCKET_PATH = "/tmp/cmux.sock", CMUX_SURFACE_ID = "surface-1", CMUX_BUNDLED_CLI_PATH = "/bin/sh" })
    api.nvim_exec_autocmds("FocusLost", {})
    sidecar.dispatch({ type = "permission_request", req = 2, tool = "Bash", input = { command = "ls" } })
    require("anvim.permission").cancel_all()
    local bin = vim.fn.exepath("cmux") ~= "" and vim.fn.exepath("cmux") or "/bin/sh"
    assert.are.same({
      {
        cmd = {
          bin,
          "notify",
          "--surface",
          "surface-1",
          "--title",
          "anvim",
          "--body",
          "Claude needs your permission to use Bash",
        },
      },
    }, calls)

    calls = {}
    local host = { host = "example.com" }
    sidecar.dispatch({ type = "permission_request", req = 3, tool = "SandboxNetworkAccess", input = host })
    require("anvim.permission").cancel_all()
    assert.are.same("Claude needs your permission to connect to example.com", calls[1].cmd[8])

    calls = {}
    set_env({})
    sidecar.dispatch(turn_end)
    assert.are.same(1, #calls)
    local osc = assert(calls[1].osc, "OSC 9 outside cmux")
    assert(osc:match("^\27%]9;.+\7$"), vim.inspect(osc))
    assert.is_nil(osc:sub(2, -2):find("[\n\7\27]"), "no control characters inside")
  end)
end)
