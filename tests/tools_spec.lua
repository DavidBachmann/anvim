---@module "luassert"

local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local tools = require("anvim.tools")

local api = vim.api

local function marks(buf)
  local ns = api.nvim_get_namespaces()["anvim.tools"]
  return api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("show_user", function()
  it("shows the range with the note above it while following, until the next prompt", function()
    helpers.start()
    local file = helpers.tmp .. "/show.lua"
    local lines = {}
    for i = 1, 80 do
      lines[i] = ("local x%d = %d"):format(i, i)
    end
    lines[40] = "  local indented = true"
    vim.fn.writefile(lines, file)
    layout.focus_input()
    local reply =
      helpers.ask("show_user", { path = "show.lua", start_line = 40, end_line = 42, note = "The work happens here." })
    assert.are.same(
      { type = "editor_response", req = reply.req, result = "Showed show.lua#L40-42 to the user." },
      reply
    )

    local win, buf = layout.wins.code, vim.fn.bufnr(file)
    assert.are.same(buf, api.nvim_win_get_buf(win), "code window shows the file")
    assert.are.same(40, api.nvim_win_get_cursor(win)[1])
    local top, bottom = vim.fn.line("w0", win), vim.fn.line("w$", win)
    assert(top < 40 and bottom >= 42, ("range and note are visible, view is %d-%d"):format(top, bottom))
    assert.are.same(3, helpers.hl_groups(buf, "anvim.tools").AnvimShow, "every line of the range is marked")

    local notes = vim.tbl_filter(function(m)
      return m[4].virt_lines ~= nil
    end, marks(buf))
    assert.are.same(1, #notes)
    local note = notes[1]
    assert.are.same(39, note[2], "the note sits on the first line of the range")
    assert(note[4].virt_lines_above, "above it")
    assert.are.same(
      { { "  " }, { "⏺ ", "AnvimClaude" }, { "The work happens here.", "AnvimNote" } },
      vim.tbl_map(function(chunk)
        return vim.tbl_filter(function(v)
          return type(v) == "string"
        end, chunk)
      end, note[4].virt_lines[1]),
      "the note has the range's indent"
    )

    -- A background agent's end starts a turn without a prompt.
    sidecar.dispatch({ type = "turn_start" })
    assert(#marks(buf) > 0, "a turn without a prompt keeps the marks")
    helpers.capture_sends(function()
      require("anvim.input").send("next")
    end)
    assert(#marks(buf) > 0, "a prompt that waits for Claude keeps the marks")
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
    assert.are.same({}, marks(buf), "the next prompt clears the marks once Claude takes it")
  end)
end)

describe("editor requests", function()
  it("group the repeats of a diagnostic into one line, errors first", function()
    helpers.start()
    local file = helpers.tmp .. "/repeats.lua"
    vim.fn.writefile({ "a", "b", "c", "d", "e" }, file)
    local buf = follow.load(file)
    local ns = api.nvim_create_namespace("anvim.test.repeats")
    local function warn(lnum, message)
      return { lnum = lnum, col = 0, severity = vim.diagnostic.severity.WARN, message = message, source = "test" }
    end
    local broken = { lnum = 4, col = 0, severity = vim.diagnostic.severity.ERROR, message = "Broken.", source = "test" }
    vim.diagnostic.set(ns, buf, { warn(0, "Same."), warn(1, "Other."), warn(2, "Same."), warn(3, "Same."), broken })
    local reply = helpers.ask("diagnostics", { path = "repeats.lua" })
    vim.diagnostic.reset(ns, buf)
    assert.are.same({
      "5 diagnostics: 1 error, 4 warnings",
      "repeats.lua:5:1 error: Broken. [test]",
      "repeats.lua:1:1 warning: Same. [test] (and 2 more, at lines 3, 4)",
      "repeats.lua:2:1 warning: Other. [test]",
    }, vim.split(reply.result or reply.error, "\n"))
  end)

  it("answer bad requests with an error", function()
    helpers.start()
    assert.are.same("anvim has no editor tool named nope.", helpers.ask("nope", {}).error)
    assert.are.same(
      "No such file: missing.lua",
      helpers.ask("show_user", { path = "missing.lua", start_line = 1 }).error
    )
    assert.are.same("path is required", helpers.ask("diagnostics", { path = "" }).error)
    assert.are.same("No such file: missing.lua", helpers.ask("diagnostics", { path = "missing.lua" }).error)
    vim.fn.writefile({ "local take_all = 1" }, helpers.tmp .. "/symbol.lua")
    assert.are.same(
      "missing is not on line 1 of symbol.lua. The line reads: local take_all = 1",
      helpers.ask("lsp_hover", { path = "symbol.lua", line = 1, symbol = "missing" }).error
    )
    assert.are.same(
      "Line 9 is outside symbol.lua, which has 1 lines.",
      helpers.ask("lsp_references", { path = "symbol.lua", line = 9, symbol = "x" }).error
    )
  end)

  it("read no file outside the cwd, except to show it", function()
    helpers.start()
    local outside = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(outside, "p")
    vim.fn.writefile({ "API_KEY=secret" }, outside .. "/env.lua")
    local rel = vim.fs.relpath(vim.fs.dirname(helpers.tmp), outside)
    vim.uv.fs_symlink(outside .. "/env.lua", helpers.tmp .. "/link.lua")
    local paths = { outside .. "/env.lua", "../" .. rel .. "/env.lua", "link.lua", outside .. "/missing.lua" }
    for _, path in ipairs(paths) do
      local hover = { path = path, line = 1, symbol = "nothere" }
      for method, params in pairs({
        lsp_hover = hover,
        lsp_document_symbols = { path = path },
        diagnostics = { path = path },
      }) do
        local reply = helpers.ask(method, params)
        assert.are.same(path .. " is outside the working directory, so the editor tools do not read it.", reply.error)
        assert(not vim.inspect(reply):find("API_KEY"), method .. " leaks file text")
      end
    end
    api.nvim_set_current_win(layout.wins.code)
    local reply = helpers.ask("show_user", { path = outside .. "/env.lua", start_line = 1 })
    assert(reply.result and not reply.result:find("API_KEY"), vim.inspect(reply))
    tools.clear()
  end)

  it("answer once when the buffer closes during the wait", function()
    helpers.start()
    local file = helpers.tmp .. "/closing.txt"
    vim.fn.writefile({ "plain text" }, file)
    helpers.capture_sends(function(sent)
      require("anvim.sidecar").dispatch({
        type = "editor_request",
        req = 77,
        method = "lsp_hover",
        params = { path = file, line = 1, symbol = "text" },
      })
      vim.cmd.bwipeout(vim.fn.bufnr(file))
      assert(vim.wait(3000, function()
        return #sent > 0
      end, 10))
      vim.wait(300)
      assert.are.same({
        {
          type = "editor_response",
          req = 77,
          error = "closing.txt was closed while the editor waited for its language server.",
        },
      }, sent)
    end)
  end)

  it("say so after a short wait when no language server is attached", function()
    helpers.start()
    vim.fn.writefile({ "plain text" }, helpers.tmp .. "/notes.txt")
    local start = vim.uv.now()
    local reply = helpers.ask("lsp_definition", { path = "notes.txt", line = 1, symbol = "text" })
    local waited = vim.uv.now() - start
    assert(waited >= 900 and waited < 2000, ("waited %d ms, not about 1 s"):format(waited))
    assert.are.same(
      { type = "editor_response", req = reply.req, result = "No language server is attached to notes.txt." },
      reply
    )
  end)

  -- An in-process server that initializes with the given capabilities and never answers anything else.
  local function silent_server(name, file, capabilities)
    vim.fn.writefile({ "local value = 1" }, file)
    local buf = require("anvim.follow").load(file)
    local id = 0
    local client_id = vim.lsp.start({
      name = name,
      root_dir = helpers.tmp,
      cmd = function(dispatchers)
        local closing = false
        return {
          request = function(method, _, callback)
            id = id + 1
            if method == "initialize" then
              callback(nil, { capabilities = capabilities })
            elseif method == "shutdown" then
              callback(nil, nil)
            end
            return true, id
          end,
          notify = function(method)
            if method == "exit" then
              dispatchers.on_exit(0, 15)
            end
            return true
          end,
          is_closing = function()
            return closing
          end,
          terminate = function()
            closing = true
          end,
        }
      end,
    }, { bufnr = buf })
    assert(vim.wait(2000, function()
      return #vim.lsp.get_clients({ bufnr = buf }) > 0
    end))
    return vim.lsp.get_client_by_id(client_id)
  end

  it("answer in time when a server hangs", function()
    helpers.start()
    local client = silent_server("hung", helpers.tmp .. "/hung.lua", { referencesProvider = true })
    local budget = tools.budget_ms
    tools.budget_ms = 200
    local reply = helpers.ask("lsp_references", { path = "hung.lua", line = 1, symbol = "value" })
    tools.budget_ms = budget
    client:stop(true)
    assert.are.same("No references found for value. hung did not answer in time.", reply.result)
  end)
end)

describe("editor tool lines", function() end)
