---@module "luassert"

local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local stream = require("anvim.stream")

local field, buf_lines, hl_groups = helpers.field, helpers.buf_lines, helpers.hl_groups

describe("stream", function()
  it("streams an Edit into the real buffer while following", function()
    helpers.start()
    local file = helpers.tmp .. "/stream.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "return a" }, file)
    layout.focus_input()
    helpers.capture_sends(function(sent)
      sidecar.dispatch({ type = "tool_start", id = "e1", name = "Edit" })
      field("e1", "Edit", "file_path", "start")
      field("e1", "Edit", "file_path", "end", file)
      field("e1", "Edit", "old_string", "start")
      field("e1", "Edit", "old_string", "end", "local b = 2")
      local buf = vim.fn.bufnr(file)
      assert.are.same(buf, vim.api.nvim_win_get_buf(layout.wins.code), "code window shows the edited file")
      assert(not vim.diagnostic.is_enabled({ bufnr = buf }), "diagnostics are off during the preview")
      field("e1", "Edit", "new_string", "start")
      field("e1", "Edit", "new_string", "delta", "local b = 3\nlocal c")
      field("e1", "Edit", "new_string", "delta", " = 4")
      field("e1", "Edit", "new_string", "end", "local b = 3\nlocal c = 4")
      sidecar.dispatch({ type = "await_preview", req = 7, tool_use_id = "e1" })
      assert(
        vim.wait(2000, function()
          return #sent > 0
        end),
        "preview_done was not sent"
      )
      assert.are.same({ type = "preview_done", req = 7 }, sent[1])
      assert.are.same({ "local a = 1", "local b = 2", "local b = 3", "local c = 4", "return a" }, buf_lines(buf))
      local groups = hl_groups(buf, "anvim.stream")
      assert.are.same(1, groups.AnvimDelete, "old text is struck through")
      assert.are.same(1, groups.AnvimInsert, "new text is marked")
      assert(not vim.bo[buf].modifiable and not vim.bo[buf].modified, "buffer stays read-only and unmodified")

      vim.fn.writefile({ "local a = 1", "local b = 3", "local c = 4", "return a" }, file)
      sidecar.dispatch({
        type = "tool_result",
        id = "e1",
        is_error = false,
        text = "ok",
        result = {
          structuredPatch = {
            { newStart = 1, lines = { " local a = 1", "-local b = 2", "+local b = 3", "+local c = 4", " return a" } },
          },
        },
      })
      assert.are.same({ "local a = 1", "local b = 3", "local c = 4", "return a" }, buf_lines(buf))
      assert.are.same({}, hl_groups(buf, "anvim.stream"), "preview marks are gone")
      assert(vim.diagnostic.is_enabled({ bufnr = buf }), "diagnostics are back after the reload")
      assert.are.same(2, hl_groups(buf, "anvim.follow").AnvimInsert, "added lines flash")
      assert.are.same(2, vim.api.nvim_win_get_cursor(layout.wins.code)[1], "cursor on the first added line")
    end)
  end)

  it("streams a Write into a paced preview, then shows the file", function()
    helpers.start()
    local file = helpers.tmp .. "/new_file.lua"
    local content = ("-- x\n"):rep(150)
    layout.focus_input()
    helpers.capture_sends(function()
      sidecar.dispatch({ type = "tool_start", id = "w1", name = "Write" })
      field("w1", "Write", "file_path", "end", file)
      field("w1", "Write", "content", "start")
      field("w1", "Write", "content", "delta", content)
      vim.wait(20)
      local preview = vim.api.nvim_win_get_buf(layout.wins.code)
      assert.are.same(file, vim.b[preview].anvim_preview)
      assert.are.same("lua", vim.bo[preview].filetype)
      local shown = #table.concat(buf_lines(preview), "\n")
      assert(
        shown > 0 and shown < #content,
        ("the preview is paced, but showed %d of %d bytes"):format(shown, #content)
      )
      field("w1", "Write", "content", "end", content)
      assert(
        vim.wait(2000, function()
          return stream.idle("w1")
        end),
        "preview never caught up"
      )
      assert.are.same(151, #buf_lines(preview))
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), file, "b")
      sidecar.dispatch({ type = "tool_result", id = "w1", is_error = false, text = "ok", result = { type = "create" } })
      local buf = vim.api.nvim_win_get_buf(layout.wins.code)
      assert.are.same(file, vim.api.nvim_buf_get_name(buf))
      assert.are.same(150, #buf_lines(buf))
      assert(not vim.api.nvim_buf_is_valid(preview), "preview buffer was deleted")
    end)
  end)

  it("brings the view back to the left edge after a long line without wrap, but leaves the user's view", function()
    helpers.start()
    local file = helpers.tmp .. "/long_line.lua"
    vim.fn.writefile({ "local a = 1", "return a" }, file)
    local long = "local b = " .. ("a + "):rep(60) .. "1"
    local win = layout.wins.code
    local function view()
      local v = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      return { lnum = v.lnum, col = v.col, leftcol = v.leftcol }
    end
    layout.set_wrap(false)
    layout.focus_input()
    local ok, err = pcall(helpers.capture_sends, function(sent)
      sidecar.dispatch({ type = "tool_start", id = "l1", name = "Edit" })
      field("l1", "Edit", "file_path", "end", file)
      field("l1", "Edit", "old_string", "end", "local a = 1")
      field("l1", "Edit", "new_string", "delta", "local a = 1\n" .. long)
      local buf = vim.fn.bufnr(file)
      assert(
        vim.wait(2000, function()
          return buf_lines(buf)[3] == long
        end),
        "the long line did not stream"
      )
      assert(view().leftcol > 0, "the cursor at the end of the long line scrolls the view")
      field("l1", "Edit", "new_string", "end", "local a = 1\n" .. long)
      sidecar.dispatch({ type = "await_preview", req = 8, tool_use_id = "l1" })
      assert(
        vim.wait(2000, function()
          return #sent > 0 and view().col == 0
        end),
        "preview_done was not sent, or the view stayed right"
      )
      assert.are.same({ lnum = 3, col = 0, leftcol = 0 }, view(), "the preview caught up")

      vim.fn.writefile({ "local a = 1", long, "return a" }, file)
      sidecar.dispatch({
        type = "tool_result",
        id = "l1",
        is_error = false,
        text = "ok",
        result = { structuredPatch = { { newStart = 1, lines = { " local a = 1", "+" .. long, " return a" } } } },
      })
      assert.are.same({ lnum = 2, col = 0, leftcol = 0 }, view(), "the reload")

      -- In review mode, the user scrolled right, and a preview leaves the view.
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 2, #long - 1 })
      local user = view()
      assert(user.leftcol > 0)
      sidecar.dispatch({ type = "tool_start", id = "l2", name = "Edit" })
      field("l2", "Edit", "file_path", "end", file)
      field("l2", "Edit", "old_string", "end", "return a")
      field("l2", "Edit", "new_string", "delta", "return b")
      field("l2", "Edit", "new_string", "end", "return b")
      assert(
        vim.wait(2000, function()
          return stream.idle("l2")
        end),
        "the preview never caught up"
      )
      assert.are.same(user, view(), "the preview moved the user's view")
      sidecar.dispatch({ type = "tool_result", id = "l2", is_error = true, text = "error" })
      assert.are.same(user, view(), "the reload moved the user's view")
    end)
    layout.set_wrap(true)
    layout.focus_input()
    assert(ok, err)
  end)

  it("releases a preview's buffer when the sidecar exits", function()
    helpers.start()
    local file = helpers.tmp .. "/crash.lua"
    vim.fn.writefile({ "local a = 1", "return a" }, file)
    local ended = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "AnvimPreviewEnd",
      callback = function(ev)
        ended[#ended + 1] = ev.data.buf
      end,
    })
    helpers.capture_sends(function()
      sidecar.dispatch({ type = "tool_start", id = "c1", name = "Edit" })
      field("c1", "Edit", "file_path", "end", file)
      field("c1", "Edit", "old_string", "end", "local a = 1")
      local buf = vim.fn.bufnr(file)
      assert(not vim.diagnostic.is_enabled({ bufnr = buf }), "diagnostics are off during the preview")
      sidecar.dispatch({ type = "exit", code = 1 })
      assert(vim.diagnostic.is_enabled({ bufnr = buf }), "diagnostics stay off after the exit")
      assert.are.same({ buf }, ended)
      assert.are.same({ "local a = 1", "return a" }, buf_lines(buf), "the buffer shows the file again")
    end)
    vim.api.nvim_del_autocmd(id)
    -- Only the event was fake. The replay sidecar still runs for the next specs.
    require("anvim.state").process = "ready"
  end)
end)
