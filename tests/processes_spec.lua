---@module "luassert"

local helpers = require("helpers")
local processes = require("anvim.processes")
local sidecar = require("anvim.sidecar")

describe("processes", function()
  local saved = {}
  for _, name in ipairs({ "ps", "kill", "clock", "interval" }) do
    saved[name] = processes[name]
  end
  local notify, select = vim.notify, vim.ui.select

  after_each(function()
    processes.close()
    for name, value in pairs(saved) do
      processes[name] = value
    end
    vim.notify, vim.ui.select = notify, select
    sidecar.dispatch({ type = "reset" })
  end)

  it("groups an app's helpers, this anvim and the Bash calls, and refuses to stop anvim", function()
    helpers.fresh()
    local server = vim.fn.getpid()
    local engine = "/x/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
    local firefox = "/Applications/Firefox.app/Contents/MacOS/"
    local helper = firefox .. "plugin-container.app/Contents/MacOS/plugin-container"
    local function sample(times, pcpu)
      return table.concat({
        "900 1 0.0 9000 0:01.00 nvim",
        ("%d 900 0.0 90000 0:02.00 nvim"):format(server),
        ("901 %d 0.0 50000 0:01.00 bun"):format(server),
        ("902 901 0.0 300000 0:10.00 %s"):format(engine),
        ("903 %d 0.0 20000 0:01.00 lua-language-server"):format(server),
        "904 902 0.0 3000 0:00.10 /bin/zsh",
        "905 904 0.0 4000 0:00.20 make",
        ("2000 1 %s 900000 %s %sfirefox"):format(pcpu, times[1], firefox),
        ("2001 2000 %s 400000 %s %s"):format(pcpu, times[2], helper),
        ("2002 2000 %s 300000 %s %s"):format(pcpu, times[3], helper),
      }, "\n")
    end
    local samples = {
      sample({ "10:00.00", "1:00.00", "0:30.00" }, "1.0"),
      -- 2 s of CPU time in 2 s of wall time.
      sample({ "10:00.50", "1:01.00", "0:30.50" }, "5.0"),
    }
    local cmdlines = {
      [904] = "/bin/zsh -c source /tmp/snap.sh && eval 'make test' < /dev/null && pwd -P >| /tmp/claude-1-cwd",
    }
    local now = 100
    processes.interval = 1e9
    processes.clock = function()
      return now
    end
    processes.ps = function(args, cb)
      local out
      if args[2] == "-axo" then
        out = #samples > 1 and table.remove(samples, 1) or samples[1]
      else
        local lines = {}
        for pid in args[#args]:gmatch("%d+") do
          lines[#lines + 1] = ("%s %s"):format(pid, cmdlines[tonumber(pid)] or "x")
        end
        out = table.concat(lines, "\n")
      end
      if cb then
        cb(out)
      end
      return out
    end
    local killed, asked, said = {}, {}, {}
    processes.kill = function(pid, signal)
      killed[#killed + 1] = { pid, signal }
      return 0
    end
    local first
    vim.ui.select = function(items, opts, cb)
      asked[#asked + 1], first = opts.prompt, items[1]
      cb(items[#items])
    end
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "ps1",
      tool_use_id = "tu_ps1",
      description = "Verify slice",
      depth = 1,
      background = false,
    })
    local call = { type = "tool_use", id = "bash_ps1", name = "Bash", agent_id = "ps1", parent_id = "tu_ps1" }
    call.input = { command = "make test" }
    sidecar.dispatch(call)
    local label = require("anvim.agents").label(require("anvim.agents").get("ps1"))

    processes.open()
    local buf = processes.get().buf
    assert(helpers.contains(helpers.buf_lines(buf), "Firefox %(3%)$"))
    now = 102
    processes.refresh()
    local lines = helpers.buf_lines(buf)
    assert(helpers.contains(lines, "^ +100%% .* Firefox %(3%)$"), vim.inspect(lines))
    assert(helpers.contains(lines, " anvim %(5%)$"))
    assert(helpers.contains(lines, (" Bash · %s · make test %%(2%%)$"):format(vim.pesc(label))))

    local function go(pattern)
      for i, line in ipairs(helpers.buf_lines(buf)) do
        if line:find(pattern) then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end
    go(" anvim %(5%)$")
    vim.api.nvim_feedkeys("x", "mx", false)
    assert.are.same({}, killed)
    assert.are.same({}, asked)
    assert.are.same(1, #said)

    -- A group's signal goes to its roots: the main Firefox process.
    go("Firefox %(3%)$")
    vim.api.nvim_feedkeys("x", "mx", false)
    assert.are.same({ "Send SIGTERM to Firefox (pid 2000)?" }, asked)
    assert.are.same("Cancel", first, "x and then <CR> sends nothing")
    assert.are.same({ { 2000, "sigterm" } }, killed)
  end)
end)
