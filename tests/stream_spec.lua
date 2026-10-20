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
end)
