---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

-- The text of the virtual lines under the prompt box.
local function under_box()
  local ns = vim.api.nvim_get_namespaces()["anvim.input"]
  local ret = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(input.buf(), ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      local text = ""
      for _, chunk in ipairs(line) do
        text = text .. chunk[1]
      end
      ret[#ret + 1] = text
    end
  end
  return ret
end

local function in_transcript(text)
  return vim.tbl_contains(helpers.buf_lines(transcript.buf()), "❯ " .. text)
end

describe("a prompt sent while Claude works", function()
  before_each(function()
    helpers.start()
  end)

  it("waits under the prompt box until Claude Code takes it, and never splits the reply", function()
    input.set_busy(true)
    transcript.text_delta("The first half of the reply")
    helpers.capture_sends(function(sent)
      input.send("Also say hi")
      input.send("And bye")
      assert.are.same("prompt", sent[1].type)
      assert.truthy(sent[1].id:match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$"), sent[1].id)
      assert.is_false(in_transcript("Also say hi"))
      assert(helpers.contains(under_box(), "❯ Also say hi  queued"))

      -- The reply goes on in its own block.
      local before = #helpers.buf_lines(transcript.buf())
      transcript.text_delta(", and the second half.")
      assert.are.same(before, #helpers.buf_lines(transcript.buf()))
      local reply = "The first half of the reply, and the second half%.$"
      assert(helpers.contains(helpers.buf_lines(transcript.buf()), reply))

      -- Claude Code folds the first one into the turn after a tool result.
      sidecar.dispatch({ type = "prompt_state", id = sent[1].id, state = "started" })
      assert.is_true(in_transcript("Also say hi"))
      assert.is_false(in_transcript("And bye"))
      assert(helpers.contains(under_box(), "❯ And bye  queued"))
    end)

    -- The rest start as the next turn.
    sidecar.dispatch({ type = "turn_end", num_turns = 1 })
    assert.is_true(in_transcript("And bye"))
    for _, line in ipairs(under_box()) do
      assert.is_nil(line:find("queued"), line)
    end
  end)
end)
