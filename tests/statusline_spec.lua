---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local state = require("anvim.state")
local statusline = require("anvim.statusline")

local api = vim.api

-- The statusline's text, as Neovim draws it for the window.
local function text(win)
  return api.nvim_eval_statusline("%!v:lua.require'anvim.statusline'.render()", { winid = win, maxwidth = 300 }).str
end

describe("statusline", function()
  local before = vim.g.colors_name or "default"
  after_each(function()
    vim.cmd.colorscheme(before)
    statusline.error = nil
  end)

  it("names Vim's mode and the file in the code window, and FOLLOW without a file in the prompt", function()
    helpers.start()
    local file = helpers.tmp .. "/100%.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "return a" }, file)
    vim.cmd.stopinsert()
    api.nvim_set_current_win(layout.code_win())
    vim.cmd.edit(vim.fn.fnameescape(file))
    api.nvim_win_set_cursor(0, { 2, 6 })
    local code = text(0)
    assert(code:find("^ anvim %S+ NORMAL "), code)
    assert(code:find(" 100%.lua ", 1, true), code)
    assert(code:find(" 66%%   2:7  $"), code)
    assert(not code:find("FOLLOW", 1, true), code)
    layout.focus_input({ insert = false })
    local prompt = text(layout.wins.input)
    assert(prompt:find("^ anvim %S+ FOLLOW "), prompt)
    assert(not prompt:find("100%", 1, true), prompt)
    assert(not prompt:find(":%d"), prompt)
    assert.is_nil(statusline.error)
  end)

  it("shows anvim, the mode, the branch, the context meter, the model, the effort and where Claude is", function()
    helpers.start()
    layout.focus_input({ insert = false })
    local saved = { state.branch, state.model, state.effort, state.permission_mode, vim.o.columns, state.context }
    local ok, err = pcall(function()
      state.branch, state.model, state.effort, vim.o.columns = "main", "claude-opus-5-5", "xhigh", 200
      state.context = { percent = 64, tokens = 640000, max = 1000000 }
      local line = text(layout.wins.input)
      local brand, block, branch = line:find("^ anvim "), line:find(" FOLLOW ", 1, true), line:find(" main ", 1, true)
      assert(brand and block and branch and brand < block and block < branch, line)
      local meter, model =
        line:find(" ▰▰▰▰▰▰▱▱▱▱ 64% ", 1, true), line:find(" Opus 5.5 · xhigh ", 1, true)
      assert(meter and model and meter < model, line)
      assert(line:find(" ◉ following ", 1, true), line)
      assert(not line:find("mode on", 1, true), "the start mode shows no label: " .. line)
      state.permission_mode = "plan"
      line = text(layout.wins.input)
      local plan = line:find(" ⏸ plan mode on ", 1, true)
      assert(plan and block < plan and plan < line:find(" main ", 1, true), line)
      local mark = api.nvim_buf_get_extmarks(input.buf(), -1, 0, -1, { details = true, type = "virt_lines" })[1]
      local footer = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, mark[4].virt_lines[#mark[4].virt_lines]))
      local rule = mark[4].virt_lines[1][1][1]
      assert(rule ~= "" and rule:gsub("─", "") == "", "a rule closes the prompt")
      assert(not footer:find("Opus", 1, true), footer)
    end)
    state.branch, state.model, state.effort, state.permission_mode, vim.o.columns, state.context = unpack(saved, 1, 6)
    assert(ok, err)
  end)

  it("shows the plan's usage after the email", function()
    helpers.start()
    layout.focus_input({ insert = false })
    local saved = { state.email, state.limits, vim.o.columns }
    local sidecar = require("anvim.sidecar")
    local ok, err = pcall(function()
      vim.o.columns = 200
      sidecar.dispatch({ type = "account", email = "me@home.com" })
      sidecar.dispatch({ type = "limits", session = 27, week = 80 })
      local line = text(layout.wins.input)
      assert(line:find(" me@home.com [S27%/W80%] ", 1, true), line)
      sidecar.dispatch({ type = "limits" })
      line = text(layout.wins.input)
      assert(not line:find("[", 1, true), line)
    end)
    state.email, state.limits, vim.o.columns = unpack(saved, 1, 3)
    assert(ok, err)
  end)

  it("leaves the busy label to the activity line, and shows a Write preview's real path with (writing)", function()
    helpers.start()
    input.set_busy(true)
    local ok, err = pcall(function()
      assert(not text(layout.wins.input):find("Working", 1, true), text(layout.wins.input))
      local buf = api.nvim_create_buf(false, true)
      vim.b[buf].anvim_preview = helpers.tmp .. "/made.lua"
      vim.bo[buf].filetype = "lua"
      local win = api.nvim_open_win(buf, false, { relative = "editor", row = 1, col = 1, width = 20, height = 2 })
      local writing = text(win)
      api.nvim_win_close(win, true)
      api.nvim_buf_delete(buf, { force = true })
      assert(writing:find(" made%.lua \238\130\177 %(writing%) "), writing)
      assert(not writing:find("Working", 1, true), writing)
    end)
    input.set_busy(false)
    assert(ok, err)
  end)
end)
