---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local rewind = require("anvim.rewind")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

-- Replaces fn on a module while the test runs, and records its calls.
local function stub(mod, name)
  local calls, orig = {}, mod[name]
  mod[name] = function(...)
    calls[#calls + 1] = { ... }
  end
  return calls, function()
    mod[name] = orig
  end
end

describe("/rewind", function()
  before_each(helpers.fresh)

  after_each(function()
    state.busy, state.resume_at = false, nil
    vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("picks a prompt, and a conversation restore resumes before it with the prompt's text", function()
    state.session_id, state.turns = "s1", 2
    local shown, unshow = stub(rewind, "show_picker")
    local menus, unmenu = stub(rewind, "show_menu")
    local restarts, unrestart = stub(sidecar, "restart")
    local ok, err = pcall(helpers.capture_sends, function(sent)
      state.busy = true
      rewind.open()
      assert.are.same(0, #sent)
      helpers.contains(helpers.buf_lines(transcript.buf()), "stop Claude first")
      state.busy = false

      rewind.open()
      assert.are.same({ type = "rewind_points", session_id = "s1" }, sent[1])
      sidecar.dispatch({
        type = "rewind_points",
        session_id = "s1",
        points = {
          { uuid = "p1", text = "Count the lines" },
          { uuid = "p2", text = "Add a comment\nat the top", before = "a1" },
        },
      })
      local items = shown[1][1]
      assert.are.same({ "Add a comment", "Count the lines" }, { items[1].text, items[2].text })

      rewind.pick(items[1].point)
      assert.are.same({ type = "rewind_files", uuid = "p2", dry_run = true }, sent[2])
      local dry = { type = "rewind_files", uuid = "p2", dry_run = true, can_rewind = true, files = { "/a" } }
      sidecar.dispatch(dry)
      assert.are.same({ items[1].point, dry }, menus[1])
      local choices = vim.tbl_map(function(c)
        return c.choice
      end, rewind.choices(dry))
      assert.are.same({ "both", "conversation", "code", "cancel" }, choices)

      rewind.restore(items[1].point, "conversation")
    end)
    unshow()
    unmenu()
    unrestart()
    assert(ok, err)
    assert.are.same(1, #restarts)
    local cmd = restarts[1][1]
    assert.are.same({ "s1", "a1", true }, { cmd.resume, cmd.resume_at, cmd.history })
    assert.are.same({ "Add a comment", "at the top" }, helpers.buf_lines(input.buf()))
    assert.are_not.same("i", vim.api.nvim_get_mode().mode)
  end)

  it("a code restore takes a file that it deleted off the code window", function()
    local layout = require("anvim.layout")
    local path = helpers.tmp .. "/rewound.txt"
    vim.fn.writefile({ "hello" }, path)
    local win = layout.code_win()
    local buf = require("anvim.follow").load(path)
    vim.api.nvim_win_set_buf(win, buf)
    helpers.capture_sends(function()
      rewind.restore({ uuid = "p1", text = "Write rewound.txt" }, "code", { path })
      os.remove(path)
      sidecar.dispatch({ type = "rewind_files", uuid = "p1", can_rewind = true })
    end)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.are.same(win, layout.code_win())
  end)
end)
