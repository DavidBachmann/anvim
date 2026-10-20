---@module "luassert"

local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local tools = require("anvim.tools")
local transcript = require("anvim.transcript")

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

    sidecar.dispatch({ type = "turn_start" })
    assert.are.same({}, marks(buf), "the next prompt clears the marks")
    sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
  end)

  it("wraps a long note to the code window", function()
    helpers.start()
    local file = helpers.tmp .. "/wrap.lua"
    vim.fn.writefile({ "return 1" }, file)
    layout.focus_input()
    local long = ("word "):rep(100)
    helpers.ask("show_user", { path = file, start_line = 1, note = long })
    local note = vim.tbl_filter(function(m)
      return m[4].virt_lines ~= nil
    end, marks(vim.fn.bufnr(file)))[1]
    local win = layout.wins.code
    local width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    assert(#note[4].virt_lines > 1, "a long note wraps")
    for _, line in ipairs(note[4].virt_lines) do
      local text = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, line))
      assert(api.nvim_strwidth(text) <= width, "a note line fits the window: " .. text)
    end
    local view = api.nvim_win_call(win, vim.fn.winsaveview)
    assert.are.same(1, view.topline)
    assert.are.same(#note[4].virt_lines, view.topfill, "a note above line 1 shows")
    tools.clear()
  end)

  it("marks the range and points the statusline at it when the user reads elsewhere", function()
    helpers.start()
    local file = helpers.tmp .. "/elsewhere.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "return a" }, file)
    api.nvim_set_current_win(layout.wins.code)
    local before = api.nvim_win_get_buf(layout.wins.code)
    local reply = helpers.ask("show_user", { path = file, start_line = 2 })
    assert(reply.result:find("^Marked elsewhere%.lua#L2%. "), reply.result)
    assert.are.same(before, api.nvim_win_get_buf(layout.wins.code), "code window stays put")
    local status = follow.status()
    assert(status:find("Claude at elsewhere.lua:2", 1, true), status)
    assert.are.same(1, helpers.hl_groups(vim.fn.bufnr(file), "anvim.tools").AnvimShow)
    tools.clear()
  end)
end)

describe("editor requests", function()
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

  it("say so at once when the attached servers lack the method", function()
    helpers.start()
    local client = silent_server("bare", helpers.tmp .. "/bare.lua", {})
    local start = vim.uv.now()
    local reply = helpers.ask("lsp_hover", { path = "bare.lua", line = 1, symbol = "value" })
    client:stop(true)
    assert.are.same("No language server for bare.lua supports textDocument/hover (attached: bare).", reply.result)
    assert(vim.uv.now() - start < 1000, "no attach wait")
  end)

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

describe("editor tool lines", function()
  it("render like other tool lines, without the mcp prefix", function()
    helpers.start()
    local name = "mcp__anvim__lsp_references"
    sidecar.dispatch({ type = "tool_start", id = "et1", name = name })
    helpers.contains(helpers.buf_lines(transcript.buf()), "^⏺ lsp_references$")
    local input = { path = helpers.tmp .. "/lua/stream.lua", line = 42, symbol = "take" }
    sidecar.dispatch({ type = "tool_use", id = "et1", name = name, input = input })
    sidecar.dispatch({ type = "tool_result", id = "et1", is_error = false, text = "7 references\nlua/stream.lua:42: x" })

    name = "mcp__anvim__show_user"
    input = { path = "lua/stream.lua", start_line = 12, end_line = 30, note = "The pacing\nloop." }
    sidecar.dispatch({ type = "tool_start", id = "et2", name = name })
    sidecar.dispatch({ type = "tool_use", id = "et2", name = name, input = input })
    sidecar.dispatch({ type = "tool_result", id = "et2", is_error = false, text = "Showed lua/stream.lua#L12-30." })

    name = "mcp__anvim__lsp_hover"
    sidecar.dispatch({ type = "tool_start", id = "et3", name = name })
    sidecar.dispatch({ type = "tool_use", id = "et3", name = name, input = { path = "a.lua", line = 1, symbol = "f" } })
    sidecar.dispatch({ type = "tool_result", id = "et3", is_error = false, text = "```lua\nfunction f()\n```" })

    local lines = helpers.buf_lines(transcript.buf())
    helpers.contains(lines, "^⏺ lsp_references%(lua/stream%.lua:42 take%)$")
    helpers.contains(lines, "^  ⎿  7 references$")
    helpers.contains(lines, "^⏺ show_user%(lua/stream%.lua#L12%-30%)$")
    helpers.contains(lines, "^  ⎿  The pacing loop%.$")
    helpers.contains(lines, "^⏺ lsp_hover%(a%.lua:1 f%)$")
    helpers.contains(lines, "^  ⎿  function f%(%)$")
  end)

  it("render a recorded turn that finds where take is used", function()
    helpers.start()
    for _, frame in ipairs(vim.fn.readfile(helpers.root .. "/tests/fixtures/editor-tools.jsonl")) do
      local ev = vim.json.decode(frame:match("^%d+ (.*)$"), { luanil = { object = true, array = true } })
      if ev.type:match("^tool_") or ev.type:match("^text_") then
        sidecar.dispatch(ev)
      end
    end
    local lines = helpers.buf_lines(transcript.buf())
    helpers.contains(lines, "^⏺ lsp_workspace_symbols%(take%)$")
    helpers.contains(lines, "^  ⎿  5 symbols$")
    helpers.contains(lines, "^⏺ lsp_references%(lua/anvim/stream%.lua:189 take%)$")
    helpers.contains(lines, "^  ⎿  2 references$")
    helpers.contains(lines, "^⏺ show_user%(lua/anvim/stream%.lua#L189%-205%)$")
    helpers.contains(lines, "^  ⎿  The only real use of take is the local function here")
  end)
end)
