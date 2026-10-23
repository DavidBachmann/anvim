---@module "luassert"

local agents = require("anvim.agents")
local files = require("anvim.files")
local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")

local api = vim.api

local function file(name)
  local path = helpers.tmp .. "/" .. name
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a" }, path)
  return path
end

local ids = 0

-- A tool call and its result, of subagent `agent` or of the main agent for nil.
local function call(agent, name, input)
  ids = ids + 1
  local id = "tabs_tool" .. ids
  local from = { parent_id = agent and "tu_" .. agent or nil, agent_id = agent }
  sidecar.dispatch(vim.tbl_extend("force", { type = "tool_use", id = id, name = name, input = input }, from))
  sidecar.dispatch(vim.tbl_extend("force", { type = "tool_result", id = id, is_error = false, text = "" }, from))
end

-- The bar's text, and the text that the current tab's highlight covers.
local function bar()
  local win = layout.wins.code
  local r = api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, highlights = true })
  local current = {}
  for i, h in ipairs(r.highlights) do
    if h.group:find("^AnvimTabCurrent") then
      local stop = r.highlights[i + 1] and r.highlights[i + 1].start or #r.str
      current[#current + 1] = r.str:sub(h.start + 1, stop)
    end
  end
  return r.str, table.concat(current)
end

local function code_file()
  return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code))
end

describe("tabs", function()
  after_each(function()
    agents.clear()
    follow.forget()
    files.clear()
    sidecar.dispatch({ type = "reset" })
  end)

  it("shows the followed agent's last files, and a resume brings them back", function()
    helpers.start()
    files.clear()
    local a, b, c = file("tabs_a.lua"), file("tabs_b.lua"), file("tabs_c.lua")
    call(nil, "Read", { file_path = a })
    call(nil, "Edit", { file_path = b, old_string = "local b = 2", new_string = "local b = 3" })
    follow.show(follow.load(b), 1)
    local text, current = bar()
    assert(text:find("tabs_a.lua .*tabs_b.lua \226\128\162"), text)
    assert(current:find("tabs_b.lua") and not current:find("tabs_a.lua"), current)

    -- A focused subagent's bar has its own files.
    sidecar.dispatch({
      type = "agent_start",
      agent_id = "tabs1",
      tool_use_id = "tu_tabs1",
      description = "Task",
      subagent_type = "Explore",
      depth = 1,
      background = false,
    })
    follow.set_focus("tabs1")
    call("tabs1", "Read", { file_path = c })
    text = bar()
    assert(text:find("Explore 1 .*tabs_c.lua"), text)
    assert(not text:find("tabs_a.lua"), text)

    -- A file that is not in the bar shows at the left, and <S-l> opens the
    -- first tab from there.
    api.nvim_set_current_win(layout.wins.code)
    follow.show(follow.load(b), 1)
    text, current = bar()
    assert(text:find("tabs_b.lua .*tabs_c.lua"), text)
    assert(current:find("tabs_b.lua") and not current:find("tabs_c.lua"), current)
    api.nvim_feedkeys(vim.keycode("<S-l>"), "mxt", false)
    assert.are.same(c, code_file())
    assert(select(2, bar()):find("tabs_c.lua"))

    -- A resumed session replays the main agent's calls.
    sidecar.dispatch({
      type = "history",
      session_id = "tabs-session",
      events = {
        { type = "tool_use", id = "h1", name = "Read", input = { file_path = a }, time = 100 },
        { type = "tool_result", id = "h1", is_error = false, text = "" },
      },
    })
    text = bar()
    assert(text:find("tabs_c.lua .*tabs_a.lua") and not text:find("tabs_b.lua"), text)
    assert(not text:find("Explore"), text)
  end)

  it("shows the first tab after a resume when the code window has no file, and the cursor stays", function()
    helpers.start()
    local a, b = file("tabs_first_a.lua"), file("tabs_first_b.lua")
    api.nvim_win_set_buf(layout.wins.code, api.nvim_create_buf(false, true))
    api.nvim_set_current_win(layout.wins.input)
    sidecar.dispatch({
      type = "history",
      session_id = "tabs-first",
      events = {
        { type = "tool_use", id = "f1", name = "Read", input = { file_path = a }, time = 100 },
        { type = "tool_result", id = "f1", is_error = false, text = "" },
        { type = "tool_use", id = "f2", name = "Read", input = { file_path = b }, time = 101 },
        { type = "tool_result", id = "f2", is_error = false, text = "" },
      },
    })
    assert.are.same(a, code_file())
    assert.are.same(layout.wins.input, api.nvim_get_current_win())
  end)

  it("<leader>cf picks from the followed agent's files, and Enter opens one", function()
    helpers.start()
    files.clear()
    local a, b = file("pick_a.lua"), file("pick_b.lua")
    call(nil, "Edit", { file_path = a, old_string = "local a = 1", new_string = "local a = 3" })
    call(nil, "Read", { file_path = b })
    api.nvim_set_current_win(layout.wins.code)
    api.nvim_feedkeys(vim.keycode("<leader>cf"), "mxt", false)
    local picker
    vim.wait(2000, function()
      picker = Snacks.picker.get({ source = "anvim_files" })[1]
      return picker ~= nil and #picker:items() == 2
    end)
    assert(picker, "no picker")
    local items = picker:items()
    assert.are.same({ b, a }, { items[1].file, items[2].file })
    assert.are.same({ false, true }, { items[1].edited, items[2].edited })
    api.nvim_feedkeys(vim.keycode("j<CR>"), "mxt", false)
    vim.wait(1000, function()
      return code_file() == a
    end)
    assert.are.same(a, code_file())
    assert.are.same(layout.wins.code, api.nvim_get_current_win())
  end)
end)
