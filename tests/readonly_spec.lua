---@module "luassert"

local helpers = require("helpers")
local layout = require("anvim.layout")
local readonly = require("anvim.readonly")

describe("readonly", function()
  it("keeps file buffers read-only and reloads them on change", function()
    helpers.start()
    local file = helpers.tmp .. "/readonly.lua"
    vim.fn.writefile({ "local M = {}", "return M" }, file)
    vim.api.nvim_win_call(layout.code_win(), function()
      vim.cmd.edit(file)
    end)
    local buf = vim.fn.bufnr(file)
    assert(not vim.bo[buf].modifiable, "file buffer is modifiable")
    local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, { "x" })
    assert(not ok, "edit was allowed")
    vim.fn.writefile({ "-- changed by Claude" }, file)
    vim.wait(50)
    readonly.reload()
    assert.are.same({ "-- changed by Claude" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert(not vim.bo[buf].modifiable, "reload made the buffer modifiable")
  end)

  it("refuses to write a locked buffer, before any BufWritePre hook", function()
    helpers.start()
    local file = helpers.tmp .. "/nowrite.lua"
    vim.fn.writefile({ "return 1" }, file)
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(layout.code_win())
    vim.cmd.edit(file)
    local stat = vim.uv.fs_stat(file)
    local pre, notes, notify = 0, {}, vim.notify
    local id = vim.api.nvim_create_autocmd("BufWritePre", {
      callback = function()
        pre = pre + 1
      end,
    })
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local ok, err = pcall(function()
      vim.cmd("write")
      vim.cmd("write!")
      vim.cmd("write " .. vim.fn.fnameescape(helpers.tmp .. "/copy.lua"))
      vim.cmd("saveas " .. vim.fn.fnameescape(helpers.tmp .. "/saved.lua"))
    end)
    vim.notify = notify
    vim.api.nvim_del_autocmd(id)
    assert(ok, err)
    assert.are.same(0, pre, "BufWritePre ran")
    assert.are.same(vim.fn["repeat"]({ "anvim is read-only" }, 4), notes)
    assert.are.same(stat.mtime, vim.uv.fs_stat(file).mtime, "the file was written")
    assert(not vim.uv.fs_stat(helpers.tmp .. "/copy.lua"), "a copy was written")
    assert(not vim.uv.fs_stat(helpers.tmp .. "/saved.lua"), ":saveas wrote a file")
    assert.are.same(file, vim.api.nvim_buf_get_name(0), ":saveas renamed the buffer")
    layout.focus_input()
  end)
end)
