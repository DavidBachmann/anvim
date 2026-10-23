---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")
local refs = require("anvim.refs")

local api = vim.api
local file = helpers.tmp .. "/refs.lua"

local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "mxt", false)
end

-- The code window shows the file, in normal mode.
local function in_code()
  helpers.start()
  if not vim.uv.fs_stat(file) then
    local lines = {}
    for i = 1, 40 do
      lines[i] = ("local v%d = %d"):format(i, i)
    end
    vim.fn.writefile(lines, file)
  end
  vim.cmd.stopinsert()
  api.nvim_set_current_win(layout.wins.code)
  vim.cmd.edit(file)
  feed("gg")
end

local function prompt(lines)
  if lines then
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, lines)
  end
  return api.nvim_buf_get_lines(input.buf(), 0, -1, false)
end

describe("references", function()
  after_each(function()
    prompt({ "" })
  end)

  it("inserts references with visual c, c{motion}, cc and a count, where typing stopped", function()
    in_code()
    prompt({ "" })
    feed("2GVjc")
    assert.are.same(layout.wins.input, api.nvim_get_current_win())
    assert.are.same({ "@refs.lua#L2-3 " }, prompt())
    api.nvim_set_current_win(layout.wins.code)
    feed("5G2cc")
    api.nvim_set_current_win(layout.wins.code)
    feed("10Gcj")
    api.nvim_set_current_win(layout.wins.code)
    feed("20Gcc")
    assert.are.same({ "@refs.lua#L2-3 @refs.lua#L5-6 @refs.lua#L10-11 @refs.lua#L20 " }, prompt())

    prompt({ "why does fail?" })
    api.nvim_win_set_cursor(layout.wins.input, { 1, 9 })
    feed("i<Esc>")
    api.nvim_set_current_win(layout.wins.code)
    feed("3Gcc")
    assert.are.same({ "why does @refs.lua#L3 fail?" }, prompt())
    assert.are.same({ 1, 22 }, api.nvim_buf_get_mark(input.buf(), "^"), "typing goes on after the reference")

    prompt({ "" })
    refs.files({ { path = file }, { path = helpers.tmp .. "/sub", dir = true } })
    vim.cmd.stopinsert()
    assert.are.same({ "@refs.lua @sub/ " }, prompt())
  end)

  it("inserts the selection or the whole file with <leader>cb, in normal mode", function()
    in_code()
    prompt({ "" })
    feed("4G<C-v>2j<Leader>cb")
    assert.are.same({ layout.wins.input, "n" }, { api.nvim_get_current_win(), api.nvim_get_mode().mode })
    assert.are.same({ "@refs.lua#L4-6 " }, prompt())
    api.nvim_set_current_win(layout.wins.code)
    feed("<Leader>cb")
    assert.are.same({ "@refs.lua#L4-6 @refs.lua " }, prompt())
  end)
end)
