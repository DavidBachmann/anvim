---@module "luassert"

local agentlog = require("anvim.agentlog")
local agents = require("anvim.agents")
local compose = require("anvim.compose")
local context = require("anvim.context")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local overview = require("anvim.overview")
local sidecar = require("anvim.sidecar")
local transcript = require("anvim.transcript")

local api = vim.api

local function start(id, extra)
  sidecar.dispatch(vim.tbl_extend("force", {
    type = "agent_start",
    agent_id = id,
    tool_use_id = "tu_" .. id,
    description = "Task " .. id,
    subagent_type = "general-purpose",
    depth = 1,
    background = false,
  }, extra or {}))
end

local function finish(id, status)
  sidecar.dispatch({ type = "agent_end", agent_id = id, status = status or "completed", summary = "done" })
end

-- The n-th tool call of agent `id`.
local function use(id, n)
  sidecar.dispatch({
    type = "tool_use",
    id = id .. "_" .. n,
    name = "Bash",
    input = { command = "echo " .. n },
    parent_id = "tu_" .. id,
    agent_id = id,
  })
end

-- Types keys, and lets the callbacks that they schedule run.
local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "x", false)
  vim.wait(30)
end

local function fresh()
  helpers.start()
  overview.close()
  context.clear()
  sidecar.dispatch({ type = "reset" })
  follow.forget()
  transcript.clear()
  layout.focus_input({ insert = false })
  vim.wait(20)
end

local function texts(item)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, overview.format(item)))
end

-- The bullet's group and the name's group of each row.
local function groups(item)
  local chunks = overview.format(item)
  return chunks[1][2] .. " " .. chunks[2][2]
end

-- Waits for the real picker, with its list and preview windows.
local function open()
  overview.open()
  assert(
    vim.wait(3000, function()
      local p = overview.get()
      if not (p and p.list.win:win_valid() and p.preview.win:win_valid() and #p:items() > 0) then
        return false
      end
      local buf = api.nvim_win_get_buf(p.preview.win.win)
      return vim.b[buf].anvim_transcript or vim.b[buf].anvim_agentlog
    end),
    "the Overview did not open"
  )
  return assert(overview.get())
end

local function current(p)
  local item = p:current()
  return item and (item.agent_id or "claude")
end

describe("the Agent Overview", function()
  local notify = vim.notify
  local said = {}
  before_each(function()
    said = {}
    vim.notify = function(msg, level)
      said[#said + 1] = { msg, level }
    end
  end)
  after_each(function()
    vim.notify = notify
    overview.close()
    vim.wait(50)
    sidecar.dispatch({ type = "reset" })
  end)

  it("lists Claude, the running agents by slot, the one without a slot, then the ended ones, newest first", function()
    fresh()
    start("x1")
    start("x2")
    finish("x1", "failed")
    finish("x2")
    start("a1", { subagent_type = "Explore", description = "Find x" })
    start("a2", { background = true })
    start("a3")
    start("a4")
    start("a5", { subagent_type = "Explore" })
    sidecar.dispatch({ type = "agent_progress", agent_id = "a1", description = "Reading a.lua" })
    local items = overview.items()
    assert.are.same("◉ Claude      idle", texts(items[1]))
    follow.set_focus("a2")
    assert.are.same({
      "⏺ Claude      idle",
      "⏺ Explore 1   Reading a.lua",
      "◉ Agent 2     bg · working",
      "⏺ Agent 3     working",
      "⏺ Agent 4     working",
      "⏺ Explore     no slot · working",
      "⏺ Agent       done · Task x2",
      "⏺ Agent       failed · Task x1",
    }, vim.tbl_map(texts, items))
    assert.are.same({
      "AnvimClaude AnvimClaude",
      "AnvimAgent1 AnvimAgent1",
      "AnvimAgent2 AnvimAgent2",
      "AnvimAgent3 AnvimAgent3",
      "AnvimAgent4 AnvimAgent4",
      "Comment Comment",
      "AnvimToolOk Comment",
      "AnvimToolError Comment",
    }, vim.tbl_map(groups, items))
    assert.are.same("Explore 1 · Find x · running · 0 tool uses", overview.title("a1"))
    sidecar.dispatch({
      type = "agent_end",
      agent_id = "a3",
      status = "stopped",
      tool_uses = 2,
      tokens = 37100,
      duration_ms = 5600,
    })
    assert.are.same("Agent · Task a3 · stopped · 2 tool uses · 37.1k tokens · 5.6s", overview.title("a3"))
    assert.are.same("Claude · idle", overview.title(nil))
  end)

  it("keeps at most 8 ended tabs, and drops them after the next prompt", function()
    fresh()
    for i = 1, 10 do
      start("e" .. i)
      finish("e" .. i)
    end
    local items = overview.items()
    assert.are.same(9, #items)
    assert.are.same({ "e10", "e3" }, { items[2].agent_id, items[9].agent_id })
    agents.prompt_sent()
    assert.are.same(1, #overview.items())
  end)

  it("shows the transcript for Claude and the log for an agent, and clears b:snacks_previewed", function()
    fresh()
    start("v1")
    for i = 1, 60 do
      use("v1", i)
    end
    local p = open()
    assert.are.same("claude", current(p))
    local win = p.preview.win.win
    assert.are.same(transcript.buf(), api.nvim_win_get_buf(win))
    assert.is_nil(vim.b[transcript.buf()].snacks_previewed)
    assert.are.same(
      { true, 2, false, "" },
      { vim.wo[win].wrap, vim.wo[win].conceallevel, vim.wo[win].number, vim.wo[win].statuscolumn }
    )
    api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
    assert(
      vim.wait(1000, function()
        return api.nvim_win_get_buf(win) == agentlog.buf("v1")
      end),
      "<Tab> showed no log"
    )
    local log = agentlog.buf("v1")
    assert.is_nil(vim.b[log].snacks_previewed)
    -- No window showed the log before, so it takes the float's own values,
    -- which a non-minimal float copies from the prompt.
    assert.are.same("", vim.wo[win].statuscolumn)
    -- The prompt lines link to CursorLine, which snacks maps to Visual.
    assert.is_nil(vim.wo[win].winhighlight:find("CursorLine:", 1, true))
    assert.is_truthy(vim.wo[win].winhighlight:find("SnacksPickerPreview", 1, true))
    -- A new tab starts at its end, and a view at the end follows new lines.
    assert.are.same(api.nvim_buf_line_count(log), api.nvim_win_get_cursor(win)[1])
    use("v1", 61)
    assert.are.same({ 61, 61 }, { api.nvim_buf_line_count(log), api.nvim_win_get_cursor(win)[1] })
    -- A view that the user scrolled up stays, also over a find for a new tab.
    api.nvim_win_set_cursor(win, { 5, 0 })
    api.nvim_win_call(win, function()
      vim.cmd("normal! zt")
    end)
    use("v1", 62)
    start("v2")
    assert(
      vim.wait(1000, function()
        return #p:items() == 3
      end),
      "the new agent got no tab"
    )
    vim.wait(100)
    assert.are.same(
      { "v1", log, 5, 5 },
      { current(p), api.nvim_win_get_buf(win), api.nvim_win_get_cursor(win)[1], vim.fn.line("w0", win) }
    )
    -- The title names the agent, its state and its totals, and follows them.
    local title = function()
      return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, api.nvim_win_get_config(win).title or {}))
    end
    assert.are.same(" Agent 1 · Task v1 · running · 62 tool uses ", title())
    use("v1", 63)
    assert(
      vim.wait(1000, function()
        return title() == " Agent 1 · Task v1 · running · 63 tool uses "
      end),
      title()
    )
  end)

  it("redraws a row when its agent reports progress", function()
    fresh()
    start("r1")
    local p = open()
    local function rows()
      return api.nvim_buf_get_lines(p.list.win.buf, 0, 2, false)
    end
    assert.are.same({ "◉ Claude      idle", "⏺ Agent 1     working" }, vim.tbl_map(vim.trim, rows()))
    sidecar.dispatch({ type = "agent_progress", agent_id = "r1", description = "Reading a.lua" })
    assert(
      vim.wait(1000, function()
        return vim.trim(rows()[2]) == "⏺ Agent 1     Reading a.lua"
      end),
      vim.inspect(rows())
    )
    follow.set_focus("r1")
    assert(
      vim.wait(1000, function()
        return vim.trim(rows()[2]) == "◉ Agent 1     Reading a.lua"
      end),
      vim.inspect(rows())
    )
  end)

  it("selects the agent of a slot with 0 to 4, and says when a slot is empty", function()
    fresh()
    start("s1")
    start("s2", { subagent_type = "Explore" })
    local p = open()
    feed("2")
    assert.are.same("s2", current(p))
    feed("0")
    assert.are.same("claude", current(p))
    feed("1")
    assert.are.same("s1", current(p))
    feed("3")
    assert.are.same("s1", current(p))
    assert.are.same({ { "No agent in slot 3", vim.log.levels.INFO } }, said)
    -- The list wraps around.
    feed("<Tab><Tab>")
    assert.are.same("claude", current(p))
    feed("<S-Tab>")
    assert.are.same("s2", current(p))
  end)

  it("keeps the selected agent selected when tabs come and go", function()
    fresh()
    start("k1")
    start("k2")
    local p = open()
    feed("2")
    start("k3")
    assert(
      vim.wait(1000, function()
        return #p:items() == 4
      end),
      "the new agent got no tab"
    )
    vim.wait(50)
    assert.are.same("k2", current(p))
    finish("k1")
    finish("k2")
    assert(
      vim.wait(1000, function()
        return p:items()[3].agent_id == "k2"
      end),
      "the ended agents kept their places"
    )
    vim.wait(50)
    assert.are.same({ "k2", 3 }, { current(p), p.list.cursor })
    -- After the next prompt, the ended tabs go, and the cursor goes to Claude.
    agents.prompt_sent()
    assert(
      vim.wait(1000, function()
        return #p:items() == 2
      end),
      "the ended tabs stayed"
    )
    vim.wait(50)
    assert.are.same("claude", current(p))
  end)

  it("puts the tabs on top below 120 columns, one row each", function()
    fresh()
    local columns = vim.o.columns
    vim.o.columns = 100
    local ok, err = pcall(function()
      start("n1")
      local p = open()
      local function rows()
        return api.nvim_win_get_height(p.list.win.win)
      end
      local list, preview = api.nvim_win_get_position(p.list.win.win), api.nvim_win_get_position(p.preview.win.win)
      assert.are.same({ 2, true }, { rows(), list[1] < preview[1] })
      start("n2")
      assert(
        vim.wait(1000, function()
          return #p:items() == 3 and p.list.win:win_valid() and rows() == 3
        end),
        "the list did not grow"
      )
      feed("2")
      assert.are.same("n2", current(p))
      for i = 3, 8 do
        start("n" .. i)
      end
      assert(
        vim.wait(1000, function()
          return #p:items() == 9 and p.list.win:win_valid() and rows() == overview.narrow_rows
        end),
        "the list grew past its rows"
      )
      vim.wait(50)
      assert.are.same("n2", current(p))
    end)
    vim.o.columns = columns
    assert(ok, err)
  end)

  it("follows a running agent from the prompt, the code window and the compose window", function()
    fresh()
    start("f1")
    start("f2")
    open()
    feed("1<CR>")
    assert(
      vim.wait(1000, function()
        return follow.focus == "f1"
      end),
      "<CR> took no focus"
    )
    assert.is_nil(overview.get())
    assert.are.same({ layout.wins.input, "n" }, { api.nvim_get_current_win(), api.nvim_get_mode().mode })

    -- From the code window, with a pinned selection: the pin goes, and the
    -- cursor goes to the prompt.
    api.nvim_set_current_win(layout.code_win())
    vim.cmd.edit(helpers.tmp .. "/matchparen.lua")
    feed("Vj<Esc>")
    assert(context.selection(), "no pin")
    open()
    feed("2<CR>")
    assert(
      vim.wait(1000, function()
        return follow.focus == "f2"
      end),
      "<CR> from the code window took no focus"
    )
    assert.are.same({ layout.wins.input, "n" }, { api.nvim_get_current_win(), api.nvim_get_mode().mode })
    assert.is_nil(context.selection())
    assert.are.same("◉ following Agent 2", follow.status())

    -- The compose window is the prompt too, so the cursor stays there.
    compose.open()
    local win = compose.win()
    vim.cmd.stopinsert()
    open()
    feed("0<CR>")
    assert(
      vim.wait(1000, function()
        return follow.focus == nil
      end),
      "<CR> on Claude took no focus"
    )
    assert.are.same(win, api.nvim_get_current_win())
    -- <C-w>p enters the compose window under the Overview, which closes then.
    open()
    feed("<C-w>p")
    assert(
      vim.wait(500, function()
        return overview.get() == nil
      end),
      "<C-w>p left the Overview open"
    )
    assert.are.same(win, api.nvim_get_current_win())
    compose.close()
    assert.are.same({}, said)
  end)

  it("follows Claude with a notice when the agent ended", function()
    fresh()
    start("d1", { subagent_type = "Explore" })
    start("d2")
    follow.set_focus("d2")
    finish("d1")
    local p = open()
    assert.are.same("d1", p:items()[3].agent_id)
    feed("<S-Tab><CR>")
    assert(
      vim.wait(1000, function()
        return #said > 0
      end),
      "no notice"
    )
    assert.are.same({ { "Explore finished · following Claude", vim.log.levels.INFO } }, said)
    assert.is_nil(follow.focus)
    -- An agent that ends before the focus runs counts as ended too.
    said = {}
    start("d3")
    follow.follow("d3")
    sidecar.dispatch({ type = "agent_end", agent_id = "d3", status = "failed" })
    assert(
      vim.wait(1000, function()
        return #said > 0
      end),
      "no notice"
    )
    assert.are.same({ { "Agent failed · following Claude", vim.log.levels.INFO } }, said)
    assert.is_nil(follow.focus)
  end)

  it("drops the agents' tabs on /clear, and deletes a shown log once the preview moves", function()
    fresh()
    start("c1")
    local p = open()
    feed("1")
    local log = assert(agentlog.buf("c1"))
    assert(
      vim.wait(1000, function()
        return api.nvim_win_get_buf(p.preview.win.win) == log
      end),
      "the log did not show"
    )
    sidecar.dispatch({ type = "reset" })
    assert(
      vim.wait(1000, function()
        return #p:items() == 1 and api.nvim_win_get_buf(p.preview.win.win) == transcript.buf()
      end),
      "the tabs stayed"
    )
    assert(
      vim.wait(1000, function()
        return not api.nvim_buf_is_valid(log)
      end),
      "the log stayed"
    )
    assert.are.same({ "claude", true }, { current(p), p.preview.win:win_valid() })
  end)

  it("closes with q, <Esc>, <leader>ca and a window change, and changes no focus", function()
    fresh()
    start("q1")
    follow.set_focus("q1")
    for _, keys in ipairs({ "q", "<Esc>", (vim.g.mapleader or "\\") .. "ca" }) do
      open()
      feed(keys)
      assert(
        vim.wait(500, function()
          return overview.get() == nil
        end),
        keys .. " left the Overview open"
      )
      assert.are.same(layout.wins.input, api.nvim_get_current_win(), keys)
    end
    -- q in a log and in Claude's conversation, after <a-w>.
    for _, tab in ipairs({ "1", "0" }) do
      open()
      feed(tab)
      vim.wait(50)
      feed("<a-w>")
      local p = assert(overview.get())
      assert.are.same(p.preview.win.win, api.nvim_get_current_win())
      feed("q")
      assert(
        vim.wait(500, function()
          return overview.get() == nil
        end),
        "q in the conversation left the Overview open"
      )
      assert.are.same(layout.wins.input, api.nvim_get_current_win())
    end
    -- The transcript's q gives the cursor back to the window that opened it.
    api.nvim_set_current_win(layout.code_win())
    open()
    feed("0")
    feed("<a-w>")
    feed("q")
    assert(
      vim.wait(500, function()
        return overview.get() == nil
      end),
      "q in Claude's conversation left the Overview open"
    )
    assert.are.same(layout.code_win(), api.nvim_get_current_win())
    layout.focus_input({ insert = false })
    vim.wait(20)
    -- snacks' keys that would move the picker to a sidebar, pick a window or
    -- fill the quickfix list are off.
    local p = open()
    local maps = {}
    for _, m in ipairs(api.nvim_buf_get_keymap(p.list.win.buf, "n")) do
      maps[vim.keycode(m.lhs)] = true
    end
    for _, lhs in ipairs({ "<S-CR>", "<C-Q>", "<C-W>H", "<C-W>J", "<C-W>K", "<C-W>L" }) do
      assert.is_nil(maps[vim.keycode(lhs)], lhs)
    end
    overview.close()
    vim.wait(20)
    open()
    api.nvim_set_current_win(layout.code_win())
    assert(
      vim.wait(500, function()
        return overview.get() == nil
      end),
      "entering the code window left the Overview open"
    )
    assert.are.same({ "q1", layout.code_win() }, { follow.focus, api.nvim_get_current_win() })
  end)
end)
