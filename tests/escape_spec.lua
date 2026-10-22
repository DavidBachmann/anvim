---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local permission = require("anvim.permission")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local api = vim.api

-- Keys as the user types them, which the check for other keys counts.
local function typed(str)
  api.nvim_feedkeys(api.nvim_replace_termcodes(str, true, false, true), "mxt", false)
end

local function focus()
  api.nvim_set_current_win(layout.wins.input)
  vim.cmd.stopinsert()
end

-- The activity line's text, and the group of its first character.
local function bar()
  local win = layout.wins.input
  local w = api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, highlights = true })
  return w.str, w.highlights[1] and w.highlights[1].group
end

local function count(sent, kind)
  return #vim.tbl_filter(function(msg)
    return msg.type == kind
  end, sent)
end

local next_req = 900

local function request(name, input_)
  next_req = next_req + 1
  local id = "esc" .. next_req
  sidecar.dispatch({ type = "tool_start", id = id, name = name })
  sidecar.dispatch({ type = "tool_use", id = id, name = name, input = input_ })
  sidecar.dispatch({ type = "permission_request", req = next_req, tool_use_id = id, tool = name, input = input_ })
  return next_req
end

-- The highlight groups of the transcript's line `n` from the end, 1 for the last.
local function groups(n)
  local buf = transcript.buf()
  local row = api.nvim_buf_line_count(buf) - n
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
    out[#out + 1] = m[4].hl_group
  end
  return out
end

-- The line of the transcript that holds `text`, counted from the end.
local function line_of(text)
  local lines = helpers.buf_lines(transcript.buf())
  for i = #lines, 1, -1 do
    if lines[i]:find(text, 1, true) then
      return #lines - i + 1
    end
  end
end

describe("esc in the prompt", function()
  local saved
  before_each(function()
    saved = { input.esc_pause_ms, input.esc_limit_ms, permission.guard_ms }
    helpers.start()
    focus()
    input.esc_pause_ms, input.esc_limit_ms, permission.guard_ms = 100, 3000, 0
  end)
  after_each(function()
    permission.cancel_all()
    -- A turn's end finishes the tool lines that got no result, so a later
    -- spec's turn end changes no line of this one.
    sidecar.dispatch({ type = "turn_end", subtype = "success", duration_ms = 1, cost_usd = 0, num_turns = 0 })
    assert(not state.busy)
    input.esc_pause_ms, input.esc_limit_ms, permission.guard_ms = unpack(saved)
  end)

  it("arms on the first press, waits on a press inside the pause, and stops Claude once after it", function()
    input.set_busy(true)
    helpers.capture_sends(function(sent)
      typed("<Esc>")
      assert.are.same(0, count(sent, "interrupt"), "the first press stopped Claude")
      assert.are.same("esc again to stop Claude", input.armed().text)
      local text, group = bar()
      assert(text:find("^esc again to stop Claude ─"), text)
      assert.are.same("AnvimDanger", group)
      -- Each press inside the pause starts it again, so a burst never acts.
      for _ = 1, 4 do
        vim.wait(60)
        typed("<Esc>")
        assert.are.same(0, count(sent, "interrupt"), "a press inside the pause stopped Claude")
        assert(input.armed(), "a press inside the pause disarmed it")
      end
      vim.wait(150)
      typed("<Esc>")
      assert.are.same(1, count(sent, "interrupt"))
      assert.is_nil(input.armed())
      assert(not bar():find("esc again", 1, true), bar())
      -- The next press arms again.
      typed("<Esc>")
      assert.are.same(1, count(sent, "interrupt"))
      assert(input.armed())
    end)
  end)

  it("does nothing while Claude is idle, but clears the search highlight", function()
    helpers.capture_sends(function(sent)
      vim.o.hlsearch = true
      vim.fn.setreg("/", "anvim")
      vim.cmd("let v:hlsearch = 1")
      typed("<Esc>")
      assert.are.same(0, vim.v.hlsearch, "the search highlight stayed")
      vim.wait(150)
      typed("<Esc>")
      assert.are.same({}, sent)
      assert.is_nil(input.armed())
    end)
  end)

  it("disarms when the sidecar cancels the request", function()
    helpers.capture_sends(function(sent)
      local req = request("Bash", { command = "make" })
      typed("<Esc>")
      assert(input.armed())
      sidecar.dispatch({ type = "permission_cancel", req = req })
      assert.is_nil(input.armed())
      assert(not bar():find("esc again", 1, true), bar())
      assert.are.same({}, sent)
    end)
  end)

  it("disarms at the end of the time limit, and the red text goes without a key", function()
    input.set_busy(true)
    input.esc_limit_ms = 200
    helpers.capture_sends(function(sent)
      typed("<Esc>")
      assert(bar():find("esc again to stop Claude", 1, true), bar())
      assert(
        vim.wait(1000, function()
          return input.armed() == nil
        end),
        "the time limit did not end"
      )
      assert(not bar():find("esc again", 1, true), bar())
      typed("<Esc>")
      assert.are.same(0, count(sent, "interrupt"), "a press after the time limit stopped Claude")
      assert(input.armed(), "a press after the time limit arms again")
    end)
  end)

  it("disarms on another key, on leaving the prompt, at a turn's end and when a request opens", function()
    input.set_busy(true)
    helpers.capture_sends(function(sent)
      typed("<Esc>")
      typed("l")
      assert(
        vim.wait(500, function()
          return input.armed() == nil
        end),
        "another key did not disarm"
      )
      -- A key between two presses makes the second a first one.
      typed("<Esc>")
      vim.wait(150)
      typed("l<Esc>")
      assert.are.same(0, count(sent, "interrupt"), "a key between the presses")
      assert(input.armed())

      api.nvim_set_current_win(layout.code_win())
      assert.is_nil(input.armed(), "leaving the prompt did not disarm")
      focus()

      typed("<Esc>")
      sidecar.dispatch({ type = "turn_end", subtype = "success", duration_ms = 1, cost_usd = 0, num_turns = 1 })
      assert.is_nil(input.armed(), "the turn's end did not disarm")
      input.set_busy(true)

      typed("<Esc>")
      assert.are.same("esc again to stop Claude", input.armed().text)
      request("Bash", { command = "make" })
      assert.is_nil(input.armed(), "the request did not disarm")
      vim.wait(150)
      typed("<Esc>")
      assert.are.same({}, sent, "the press after the request stopped Claude or answered it")
      assert.are.same("esc again to answer No", input.armed().text)
    end)
  end)

  it("arms for a request with red text and a red choice, and the second press answers No", function()
    helpers.capture_sends(function(sent)
      local req = request("Bash", { command = "make" })
      local no = "No, and tell Claude what to do differently (esc twice)"
      assert.are.same({ "AnvimChoice" }, groups(line_of("1. Yes")))
      assert.are.same({}, groups(line_of(no)))
      typed("<Esc>")
      assert.are.same({}, sent)
      local text, group = bar()
      assert(text:find("^esc again to answer No ─"), text)
      assert.are.same("AnvimDanger", group)
      assert.are.same({ "AnvimDanger" }, groups(line_of(no)))
      -- A move changes the request, so the red goes, and the next press arms again.
      typed("j")
      assert.is_nil(input.armed())
      assert.are.same({ "AnvimChoice" }, groups(line_of(no)), "the cursor's choice")
      typed("k")
      vim.wait(150)
      typed("<Esc>")
      assert.are.same({}, sent, "a press after a move answered")
      vim.wait(150)
      typed("<Esc>")
      assert.are.same({ { type = "permission_response", req = req, behavior = "deny" } }, sent)
      assert(not permission.waiting())
      assert.is_nil(input.armed())
    end)
  end)

  it("names what the second press does for a plan, a question and a network request", function()
    local form = { questions = { { question = "Which?", header = "Pick", options = { { label = "A" } } } } }
    local cases = {
      { "ExitPlanMode", { plan = "# Plan" }, "esc again to keep planning", "No, keep planning" },
      { "AskUserQuestion", form, "esc again to decline to answer" },
      { "SandboxNetworkAccess", { host = "example.com" }, "esc again to refuse the connection", "No, and tell" },
    }
    helpers.capture_sends(function(sent)
      for _, case in ipairs(cases) do
        local req = request(case[1], case[2])
        typed("<Esc>")
        assert.are.same(case[3], input.armed().text, case[1])
        -- A narrow column keeps the start of the text.
        local text = bar()
        local start = text:match("^(.-)%.%.%.") or text:match("^(.-) ─")
        assert(start and #start > 10 and vim.startswith(case[3], start), case[1] .. ": " .. text)
        if case[4] then
          assert.are.same({ "AnvimDanger" }, groups(line_of(case[4])), case[1])
        else
          local lines = helpers.buf_lines(transcript.buf())
          for n = 1, 4 do
            assert(not vim.tbl_contains(groups(n), "AnvimDanger"), case[1] .. ": " .. lines[#lines - n + 1])
          end
        end
        vim.wait(150)
        typed("<Esc>")
        assert.are.same({ type = "permission_response", req = req, behavior = "deny" }, sent[#sent], case[1])
      end
    end)
  end)

  it("stops Claude at once with <C-c>, in normal and insert mode", function()
    input.set_busy(true)
    helpers.capture_sends(function(sent)
      typed("<C-c>")
      assert.are.same(1, count(sent, "interrupt"))
      typed("i<C-c>")
      assert.are.same(2, count(sent, "interrupt"))
    end)
  end)
end)
