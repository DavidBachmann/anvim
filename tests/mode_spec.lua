---@module "luassert"

local compose = require("anvim.compose")
local follow = require("anvim.follow")
local helpers = require("helpers")
local keyview = require("anvim.keyview")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")

local api = vim.api

---@type integer
local changes = 0
api.nvim_create_autocmd("User", {
  pattern = "AnvimMode",
  callback = function()
    changes = changes + 1
  end,
})

local file = helpers.tmp .. "/mode.lua"
local other = helpers.tmp .. "/mode_other.lua"

local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "mxt", false)
  vim.wait(20)
end

-- The gutter of a window, by default the code window.
local function numbers(win)
  local wo = vim.wo[win or layout.wins.code]
  return {
    number = wo.number,
    relativenumber = wo.relativenumber,
    statuscolumn = wo.statuscolumn,
    signcolumn = wo.signcolumn,
  }
end

-- The bare specs run without snacks' statuscolumn. Their files have fewer
-- than 1000 lines, so review's columns are 4 for the numbers and 2 for a sign.
local NONE = {
  number = false,
  relativenumber = false,
  statuscolumn = "%@v:lua.require'anvim.follow'.click_gutter@  %s%T",
  signcolumn = "yes:2",
}
local REVIEW = { number = true, relativenumber = true, statuscolumn = "", signcolumn = "yes" }

local function to_code(path)
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.wins.code)
  if path then
    vim.cmd.edit(path)
  end
end

local function to_prompt()
  layout.focus_input({ insert = false })
end

local function fresh()
  helpers.start()
  if compose.win() then
    api.nvim_win_close(compose.win(), true)
  end
  keyview.close()
  vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a" }, file)
  vim.fn.writefile({ "return 'other'" }, other)
  to_code(file)
end

-- Windows that a case opened, which the next cases must not see.
---@type integer[]
local extra = {}

local function open(buf, enter, config)
  local win = api.nvim_open_win(buf or api.nvim_create_buf(false, true), enter, config)
  extra[#extra + 1] = win
  return win
end

describe("mode", function()
  after_each(function()
    for _, win in ipairs(extra) do
      pcall(api.nvim_win_close, win, true)
    end
    extra = {}
    vim.cmd.stopinsert()
  end)

  it("is follow in the prompt and review in the code window, with numbers only in review", function()
    fresh()
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
    to_prompt()
    assert.are.same("follow", follow.mode())
    assert.are.same(NONE, numbers())
    to_code()
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
  end)

  it("fires User AnvimMode once per change, and not on a WinEnter that keeps the mode", function()
    fresh()
    changes = 0
    to_prompt()
    assert.are.same(1, changes)
    to_code()
    assert.are.same(2, changes)
    -- The transcript moves the cursor on to the prompt.
    api.nvim_set_current_win(layout.wins.transcript)
    assert.are.same(layout.wins.input, api.nvim_get_current_win())
    assert.are.same(3, changes)
    local float = open(nil, true, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
    to_prompt()
    api.nvim_win_close(float, true)
    assert.are.same(3, changes, "a WinEnter that keeps follow mode fired it")
    to_code()
    assert.are.same(4, changes)
    local scratch = open(nil, true, { split = "below" })
    to_code()
    api.nvim_win_close(scratch, true)
    assert.are.same(4, changes, "a WinEnter that keeps review mode fired it")
  end)

  it("counts the compose window as the prompt, and the compose window keeps the numbers of review mode", function()
    fresh()
    to_prompt()
    feed("<C-g>")
    local win = assert(compose.win(), "<C-g> opened no window")
    assert.are.same(win, api.nvim_get_current_win())
    assert.are.same("follow", follow.mode())
    assert.are.same(NONE, numbers())
    assert.are.same(REVIEW, numbers(win))
    feed("<C-g>")
    assert(
      vim.wait(500, function()
        return compose.win() == nil
      end),
      "<C-g> did not close the window"
    )
    assert.are.same("follow", follow.mode())
  end)

  it("keeps the mode in the key view, from the prompt and from the code window", function()
    fresh()
    to_prompt()
    keyview.open()
    assert.are.same(keyview.win(), api.nvim_get_current_win())
    assert.are.same("follow", follow.mode())
    assert.are.same(NONE, numbers())
    keyview.close()
    assert.are.same(layout.wins.input, api.nvim_get_current_win())
    assert.are.same("follow", follow.mode())

    to_code()
    keyview.open()
    assert.are.same(keyview.win(), api.nvim_get_current_win())
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
    keyview.close()
    assert.are.same("review", follow.mode())
  end)

  it("keeps follow mode in a snacks picker from the prompt, and moves made meanwhile catch up", function()
    fresh()
    to_prompt()
    changes = 0
    Snacks.picker.pick({
      source = "anvim_mode_test",
      items = { { text = "one" }, { text = "two" } },
      format = "text",
      main = { current = true },
    })
    assert(
      vim.wait(2000, function()
        return vim.bo.filetype == "snacks_picker_input"
      end),
      "the picker took no focus"
    )
    assert.are.same("follow", follow.mode())
    assert.are.same(NONE, numbers())
    assert.is_false(follow.following(), "a picker follows")
    sidecar.dispatch({ type = "tool_use", id = "mode_r1", name = "Read", input = { file_path = other } })
    assert.are.same(api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)), file)
    Snacks.picker.get({ source = "anvim_mode_test" })[1]:close()
    assert(
      vim.wait(2000, function()
        return api.nvim_get_current_win() == layout.wins.input
      end),
      "the picker did not give the cursor back to the prompt"
    )
    assert(
      vim.wait(1000, function()
        return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)) == other
      end),
      "the Read did not catch up"
    )
    assert.are.same(0, changes, "the picker changed the mode")
    assert.are.same(NONE, numbers())
  end)

  it("is review in a float on a split, as the explorer's list is", function()
    fresh()
    to_prompt()
    local split = open(nil, false, { split = "left", win = -1, width = 20 })
    local float = { relative = "win", win = split, row = 0, col = 0, width = 20, height = 5 }
    api.nvim_set_current_win(open(nil, false, float))
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
    -- A window that opens with the cursor shows the old buffer at its
    -- WinEnter, here the prompt's. SafeState comes before the redraw.
    to_prompt()
    open(nil, true, float)
    api.nvim_exec_autocmds("SafeState", {})
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
  end)

  it("keeps the numbers of the mode when the code window shows another buffer", function()
    fresh()
    -- Neovim brings back a buffer's own window options when a window shows it again.
    to_prompt()
    sidecar.dispatch({ type = "tool_use", id = "mode_r2", name = "Read", input = { file_path = other } })
    assert.are.same(other, api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)))
    assert.are.same(NONE, numbers())
    sidecar.dispatch({ type = "tool_use", id = "mode_r3", name = "Read", input = { file_path = file } })
    assert.are.same(file, api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)))
    assert.are.same(NONE, numbers())

    to_code()
    vim.cmd.edit(other)
    assert.are.same(REVIEW, numbers())
    feed("<C-o>")
    assert.are.same(file, api.nvim_buf_get_name(0))
    assert.are.same(REVIEW, numbers())
    -- The reload after Claude's edit.
    vim.cmd("silent! edit!")
    assert.are.same(REVIEW, numbers())
    to_prompt()
    api.nvim_buf_call(api.nvim_win_get_buf(layout.wins.code), function()
      vim.cmd("silent! keepjumps edit!")
    end)
    assert.are.same(NONE, numbers())
  end)

  it("keeps the numbers of the mode when a non-nested autocmd shows a buffer, which fires no BufWinEnter", function()
    fresh()
    vim.cmd.edit(other)
    vim.cmd.edit(file)
    to_prompt()
    local group = api.nvim_create_augroup("anvim.mode_spec", {})
    api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AnvimModeSpec",
      callback = function()
        follow.show(vim.fn.bufnr(other), 1)
      end,
    })
    vim.cmd.doautocmd("User AnvimModeSpec")
    api.nvim_del_augroup_by_id(group)
    assert.are.same(other, api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)))
    assert.are.same(NONE, numbers())
  end)

  it("hides the numbers for a Write preview while following, and shows them in review", function()
    fresh()
    to_prompt()
    local path = helpers.tmp .. "/mode_new.lua"
    sidecar.dispatch({ type = "turn_start" })
    sidecar.dispatch({ type = "tool_start", id = "mode_w1", name = "Write" })
    helpers.field("mode_w1", "Write", "file_path", "end", path)
    helpers.field("mode_w1", "Write", "content", "start")
    helpers.field("mode_w1", "Write", "content", "delta", ("local x = 1\n"):rep(12))
    assert(
      vim.wait(2000, function()
        return vim.b[api.nvim_win_get_buf(layout.wins.code)].anvim_preview == path
      end),
      "the code window shows no preview"
    )
    assert.are.same(NONE, numbers())
    to_code()
    assert.are.same(REVIEW, numbers())
    sidecar.dispatch({ type = "tool_result", id = "mode_w1", is_error = true, text = "denied" })
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
  end)

  it("gives the code window the gutter of the mode after :vsplit from the prompt, not the prompt's", function()
    fresh()
    -- A buffer that the code window never showed takes the split's options,
    -- which the split copied from the prompt.
    local probe = helpers.tmp .. "/mode_probe.txt"
    vim.fn.writefile({ "PROBE", "PROBE" }, probe)
    to_prompt()
    vim.cmd.vsplit(probe)
    assert(
      vim.wait(1000, function()
        return api.nvim_buf_get_name(api.nvim_win_get_buf(layout.wins.code)) == probe
          and #vim.tbl_filter(function(w)
              return api.nvim_win_get_config(w).relative == ""
            end, api.nvim_tabpage_list_wins(0))
            == 3
      end),
      "the split did not fold into the code window"
    )
    assert.are.same(layout.wins.code, api.nvim_get_current_win())
    assert.are.same("review", follow.mode())
    assert.are.same(REVIEW, numbers())
  end)

  it("gives follow mode a gutter as wide as review's, which keeps its width while the buffer grows", function()
    fresh()
    local code = layout.wins.code
    -- Without a UI nothing draws, so only Neovim's own columns have a width.
    local function review()
      return vim.fn.getwininfo(code)[1].textoff
    end
    assert.are.same(review(), follow.review_width(code))
    for _, wo in ipairs({ { numberwidth = 6 }, { foldcolumn = "1" } }) do
      for name, value in pairs(wo) do
        vim.wo[code][name] = value
      end
      assert.are.same(review(), follow.review_width(code), vim.inspect(wo))
      vim.wo[code].numberwidth, vim.wo[code].foldcolumn = 4, "0"
    end
    to_prompt()
    local gutter = vim.wo[code].statuscolumn
    assert.are.same(NONE.statuscolumn, gutter)
    -- A preview that writes 1000 lines and more, while following.
    local buf = api.nvim_win_get_buf(code)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(("x\n"):rep(1200), "\n"))
    vim.bo[buf].modifiable = false
    vim.cmd.doautocmd("SafeState")
    assert.are.same(gutter, vim.wo[code].statuscolumn)
    to_code()
    assert.are.same(7, review())
    assert.are.same(review(), follow.review_width(code))
    to_prompt()
    assert.are.same("%@v:lua.require'anvim.follow'.click_gutter@   %s%T", vim.wo[code].statuscolumn)
    to_code()
    vim.cmd.edit({ bang = true })
  end)

  it("gives a new code window from layout repair the numbers of the mode", function()
    fresh()
    to_prompt()
    api.nvim_win_close(layout.wins.code, true)
    local win = layout.code_win()
    assert.are_not.same(layout.wins.input, win)
    assert.are.same(NONE, numbers())
    -- The buffer brings back its options from the closed window, which
    -- were those of follow mode. Read mode is review mode.
    api.nvim_win_close(layout.wins.code, true)
    require("anvim.windows").read()
    assert.are.same("review", follow.mode())
    win = layout.code_win()
    assert.are_not.same(layout.wins.transcript, win)
    assert.are.same(REVIEW, numbers())
    to_code(file)
  end)
end)
