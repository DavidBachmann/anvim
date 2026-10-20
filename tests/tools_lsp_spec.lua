---@module "luassert"

-- The LSP tools against a real lua_ls, from the mason dir that scripts/test-deps fills.
local helpers = require("helpers")

local lua_ls = helpers.root .. "/.tests/anvim/mason/bin/lua-language-server"
local dir = helpers.tmp .. "/lsp"
-- Outside the cwd, like a real install. Without these flags lua_ls writes its
-- log and its stdlib files into mason's install dir.
local state = vim.fn.resolve(vim.fn.tempname())
local cmd = { lua_ls, "--logpath=" .. state .. "/log", "--metapath=" .. state .. "/meta" }
-- Only open files get diagnostics, so a file's first report comes after it loads.
local settings = { Lua = { diagnostics = { workspaceDelay = -1 } } }

local lib = {
  "local M = {}",
  "",
  "--- Returns the first n bytes of s.",
  "local function take(s, n)",
  "  return s:sub(1, n)",
  "end",
  "",
  "function M.head(s)",
  "  return take(s, 1)",
  "end",
  "",
  "function M.tail(s)",
  "  return take(s:reverse(), 1)",
  "end",
  "",
  "return M",
}

local ready = false

-- lua_ls attaches on FileType, the way vim.lsp.enable starts servers, but only
-- to files in the fixture dir. So the tools load buffers and wait as they would live.
local function setup()
  helpers.start()
  if ready then
    return
  end
  ready = true
  assert(vim.fn.executable(lua_ls) == 1, "the LSP specs need lua-language-server at " .. lua_ls)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lib, dir .. "/lib.lua")
  vim.fn.writefile({ "local M = {}", "M.oops = undefined_global", "return M" }, dir .. "/broken.lua")
  vim.fn.writefile({ "return also_undefined" }, dir .. "/fresh.lua")
  vim.fn.writefile({ 'return string.rep("x", 2)' }, dir .. "/std.lua")
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("anvim.test.lua_ls", { clear = true }),
    pattern = "lua",
    callback = function(ev)
      if vim.startswith(vim.api.nvim_buf_get_name(ev.buf), dir .. "/") then
        vim.lsp.start({ name = "lua_ls", cmd = cmd, root_dir = dir, settings = settings }, { bufnr = ev.buf })
      end
    end,
  })
end

local function lines(reply)
  assert(reply.result, reply.error)
  return vim.split(reply.result, "\n", { plain = true })
end

describe("lsp tools", function()
  it("find a definition", function()
    setup()
    assert.are.same(
      { "Defined at lsp/lib.lua:4", "lsp/lib.lua:4: local function take(s, n)" },
      lines(helpers.ask("lsp_definition", { path = "lsp/lib.lua", line = 9, symbol = "take" }))
    )
  end)

  it("give no excerpt for a definition outside the cwd", function()
    setup()
    local out = lines(helpers.ask("lsp_definition", { path = "lsp/std.lua", line = 1, symbol = "string.rep" }))
    assert.are.same(2, #out, table.concat(out, "\n"))
    assert(out[2]:match("/string%.lua:%d+$"), "a location only: " .. out[2])
  end)

  it("list references", function()
    setup()
    assert.are.same({
      "3 references",
      "lsp/lib.lua:4: local function take(s, n)",
      "lsp/lib.lua:9: return take(s, 1)",
      "lsp/lib.lua:13: return take(s:reverse(), 1)",
    }, lines(helpers.ask("lsp_references", { path = dir .. "/lib.lua", line = 4, symbol = "take" })))
  end)

  it("ask about the last word of a dotted symbol", function()
    setup()
    assert.are.same(
      { "1 reference", "lsp/lib.lua:8: function M.head(s)" },
      lines(helpers.ask("lsp_references", { path = "lsp/lib.lua", line = 8, symbol = "M.head" }))
    )
  end)

  it("hover", function()
    setup()
    local text = helpers.ask("lsp_hover", { path = "lsp/lib.lua", line = 13, symbol = "take" }).result
    assert(text:find("function take(s: any, n: any)", 1, true), text)
    assert(text:find("Returns the first n bytes of s.", 1, true), text)
    assert.are.same(
      "function take(s: any, n: any)",
      require("anvim.tools").summary("lsp_hover", {}, text):match("%S.*")
    )
  end)

  it("outline a file without the locals of its functions", function()
    setup()
    local out = lines(helpers.ask("lsp_document_symbols", { path = "lsp/lib.lua" }))
    assert(out[1]:match("^%d+ symbols$"), out[1])
    helpers.contains(out, "^%a+ take  L4%-6$")
    helpers.contains(out, "^%a+ M%.head  L8%-10$")
    for _, line in ipairs(out) do
      assert(not line:find(" [sn]  L", 1), "parameters are left out: " .. line)
    end
  end)

  it("search workspace symbols, exact names first", function()
    setup()
    local out = lines(helpers.ask("lsp_workspace_symbols", { query = "take" }))
    assert.are.same("1 symbol", out[1], "loose matches such as table.unpack are dropped:\n" .. table.concat(out, "\n"))
    assert(out[2]:match(" take  lsp/lib%.lua:4$"), out[2])
    helpers.contains(lines(helpers.ask("lsp_workspace_symbols", { query = "tail" })), "tail  lsp/lib%.lua:12$")
  end)

  it("report diagnostics for a file they load, and for every open file", function()
    setup()
    local broken = vim.fn.bufnr(dir .. "/broken.lua")
    assert(broken == -1 or not vim.api.nvim_buf_is_loaded(broken), "broken.lua starts unloaded")
    local expected = "lsp/broken.lua:2:10 warning: Undefined global `undefined_global`. [Lua Diagnostics]"
    assert.are.same(
      { "1 diagnostic: 1 warning", expected },
      lines(helpers.ask("diagnostics", { path = "lsp/broken.lua" }))
    )
    helpers.contains(lines(helpers.ask("diagnostics", {})), "^" .. vim.pesc(expected) .. "$")
  end)

  it("wait for the first report when another tool loaded the file", function()
    setup()
    -- Every tool loads its file this way, and answers can come before the server reports.
    require("anvim.follow").load(dir .. "/fresh.lua")
    assert.are.same(
      { "1 diagnostic: 1 warning", "lsp/fresh.lua:1:8 warning: Undefined global `also_undefined`. [Lua Diagnostics]" },
      lines(helpers.ask("diagnostics", { path = "lsp/fresh.lua" }))
    )
  end)
end)
