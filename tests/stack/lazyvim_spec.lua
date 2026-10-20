---@module "luassert"

-- Boots the real init.lua with the user's LazyVim config in a child Neovim,
-- as bin/anvim does. Its state, cache, config and data dirs are temporary.
-- Plugins, parsers and tools come from the main Neovim and must stay unchanged.
local helpers = require("helpers")

local home = assert(vim.env.HOME)
local nvim_config = home .. "/.config/nvim"
local nvim_data = home .. "/.local/share/nvim"
local xdg = helpers.tmp .. "/xdg"

---@type integer?
local chan
---@type integer?
local job
---@type integer The explorer's width at startup.
local tree_width
local stderr = {}

-- Paths whose mtime proves that nothing was installed, updated or written.
local function shared_paths()
  local paths = {
    nvim_config .. "/lazy-lock.json",
    nvim_config .. "/lazyvim.json",
    nvim_data .. "/lazy",
    nvim_data .. "/site/parser",
    nvim_data .. "/mason",
    nvim_data .. "/mason/bin",
    nvim_data .. "/mason/packages",
    nvim_data .. "/mason/registries/github/mason-org/mason-registry/registry.json",
  }
  for name in vim.fs.dir(nvim_data .. "/lazy") do
    paths[#paths + 1] = nvim_data .. "/lazy/" .. name
  end
  return paths
end

local function mtimes()
  local ret = {}
  for _, path in ipairs(shared_paths()) do
    local stat = vim.uv.fs_stat(path)
    ret[path] = stat and ("%d.%d"):format(stat.mtime.sec, stat.mtime.nsec) or "missing"
  end
  return ret
end

local before = mtimes()

local function lua(code, ...)
  return vim.rpcrequest(assert(chan, "child not started"), "nvim_exec_lua", code, { ... })
end

local function wait(ms, code, msg)
  assert(
    vim.wait(ms, function()
      return lua(code)
    end, 20),
    msg or code
  )
end

local function start()
  if chan then
    return
  end
  local env = vim.fn.environ()
  for key in pairs(env) do
    -- Without the cmux variables, the child posts no notifications.
    if key:match("^XDG_") or key:match("^LAZY_") or key:match("^NVIM") or key:match("^CMUX_") then
      env[key] = nil
    end
  end
  env.NVIM_APPNAME = "anvim"
  for _, name in ipairs({ "config", "data", "state", "cache" }) do
    env[("XDG_%s_HOME"):format(name:upper())] = xdg .. "/" .. name
  end
  env.ANVIM_REPLAY = helpers.recording
  env.ANVIM_REPLAY_SPEED = "50"
  env.ANVIM_MODEL = "haiku"
  local addr = helpers.tmp .. "/child.sock"
  job = vim.fn.jobstart({
    vim.v.progpath,
    "--headless",
    "--listen",
    addr,
    "--cmd",
    "set columns=200 lines=48",
    "-u",
    helpers.root .. "/init.lua",
  }, {
    cwd = helpers.tmp,
    env = env,
    clear_env = true,
    stdin = "null",
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          stderr[#stderr + 1] = line
        end
      end
    end,
  })
  assert(
    vim.wait(5000, function()
      local ok, ch = pcall(vim.fn.sockconnect, "pipe", addr, { rpc = true })
      chan = ok and ch or nil
      return ok
    end, 20),
    "child did not start"
  )
  -- A headless Neovim has no UI, so lazy.nvim waits for UIEnter before VeryLazy.
  lua([[vim.api.nvim_exec_autocmds("UIEnter", {})]])
  wait(5000, "return vim.g.did_very_lazy == true", "VeryLazy did not run")
  wait(5000, [[return require("anvim.state").process == "ready"]], "sidecar not ready")
  wait(2000, [[return vim.api.nvim_get_current_win() == require("anvim.layout").wins.input]], "input not focused")
  tree_width = lua([[
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local snacks_win = vim.w[win].snacks_win
      if vim.api.nvim_win_get_config(win).relative == "" and snacks_win and snacks_win.position == "left" then
        return vim.api.nvim_win_get_width(win)
      end
    end
  ]])
end

-- The global statusline's text, from the current window's lualine value.
local function statusline()
  return lua([[
    require("lualine").refresh({ force = true, place = { "statusline" } })
    local win = vim.api.nvim_get_current_win()
    return vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win }).str
  ]])
end

-- Types keys in the child. Its main loop runs them after this call returns,
-- through which-key and LazyVim's maps, as for a user.
local function keys(k)
  lua([[vim.api.nvim_feedkeys(vim.keycode(...), "t", false)]], k)
end

-- The anvim window with the cursor, or the filetype of another window, and the mode.
local function where()
  return lua([[
    local win = vim.api.nvim_get_current_win()
    for role, w in pairs(require("anvim.layout").wins) do
      if w == win then
        return { win = role, mode = vim.api.nvim_get_mode().mode }
      end
    end
    return { win = vim.bo.filetype, mode = vim.api.nvim_get_mode().mode }
  ]])
end

local function wait_where(want, msg)
  local got
  local ok = vim.wait(3000, function()
    got = where()
    return vim.deep_equal(got, want)
  end, 20)
  assert(ok, ("%s: %s"):format(msg, vim.inspect(got)))
end

-- Waits until the layout is whole again, then checks its shape.
local function assert_layout(what)
  wait(
    3000,
    [[
      local wins = require("anvim.layout").wins
      return vim.api.nvim_win_is_valid(wins.code)
        and vim.api.nvim_win_is_valid(wins.transcript)
        and vim.api.nvim_win_is_valid(wins.input)
    ]],
    what .. " left the layout broken"
  )
  local out = lua([[
    local wins = require("anvim.layout").wins
    local function box(win)
      local pos = vim.fn.win_screenpos(win)
      return { row = pos[1], col = pos[2], width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win) }
    end
    local tree
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local snacks_win = vim.w[win].snacks_win
      if vim.api.nvim_win_get_config(win).relative == "" and snacks_win and snacks_win.position == "left" then
        tree = box(win)
      end
    end
    return {
      code = box(wins.code),
      transcript = box(wins.transcript),
      input = box(wins.input),
      tree = tree,
      columns = vim.o.columns,
      bottom = vim.o.lines - vim.o.cmdheight - 1,
    }
  ]])
  assert(out.code.col < out.transcript.col, what .. ": the code window is left of the transcript")
  assert.are.same(out.code.row, out.transcript.row, what .. ": the Claude column starts at the top")
  assert.are.same(out.transcript.col, out.input.col, what .. ": the prompt is under the transcript")
  assert.are.same(math.floor(200 * 0.36), out.transcript.width, what .. ": the Claude column keeps its width")
  assert.are.same(3, out.input.height, what .. ": the prompt fits its text")
  assert.are.same(out.bottom, out.input.row + out.input.height - 1, what .. ": the prompt ends above the statusline")
  local left = 0
  if out.tree then
    assert.are.same(tree_width, out.tree.width, what .. ": the tree keeps its width")
    left = out.tree.width + 1
  end
  local width = out.columns - left - out.transcript.width - 1
  assert.are.same(width, out.code.width, what .. ": the code window takes the rest of the width")
end

describe("LazyVim stack", function()
  it("opens the layout in the user's LazyVim", function()
    start()
    local info = lua([[
      local layout = require("anvim.layout")
      local ret = { tree = false, laststatus = vim.o.laststatus, lazyvim = package.loaded["lazyvim.config"] ~= nil }
      for role, win in pairs(layout.wins) do
        local buf = vim.api.nvim_win_get_buf(win)
        ret[role] = { ft = vim.bo[buf].filetype, spell = vim.wo[win].spell, ts = vim.treesitter.highlighter.active[buf] ~= nil }
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        ret.tree = ret.tree or vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_picker_list"
      end
      return ret
    ]])
    assert(info.lazyvim, "LazyVim is not loaded")
    assert.are.same(3, info.laststatus)
    assert(info.tree, "the explorer is not open")
    assert.are.same({ ft = "anvim_transcript", spell = false, ts = true }, info.transcript)
    assert.are.same({ ft = "anvim_input", spell = false, ts = true }, info.input)
    assert(info.code, "code window missing")
  end)

  it("reads the user's extras from a copy of lazyvim.json, and passes ANVIM_MODEL on", function()
    start()
    local out = lua([[
      return {
        json = vim.g.lazyvim_json,
        extras = require("lazyvim.config").json.data.extras,
        model = require("anvim.config").options.model,
      }
    ]])
    assert.are.same(xdg .. "/state/anvim/lazyvim.json", out.json)
    local user = vim.json.decode(table.concat(vim.fn.readfile(nvim_config .. "/lazyvim.json"), "\n"))
    assert.are.same(user.extras, out.extras)
    assert.are.same("haiku", out.model)
  end)

  it("starts without errors", function()
    start()
    local out = lua([[
      local errors = {}
      for _, n in ipairs(Snacks.notifier.get_history()) do
        if n.level == "error" or n.level == "warn" then
          errors[#errors + 1] = n.msg
        end
      end
      return { messages = vim.api.nvim_exec2("messages", { output = true }).output, notes = errors, errmsg = vim.v.errmsg }
    ]])
    assert.are.same("", out.messages)
    assert.are.same({}, out.notes)
    assert.are.same("", out.errmsg)
    assert.are.same({}, stderr)
  end)

  it("renders a replayed turn and follows it", function()
    start()
    lua([[require("anvim.input").send("Add a comment")]])
    wait(10000, [[return not require("anvim.state").busy]], "turn did not end")
    local out = lua([[
      local layout = require("anvim.layout")
      return {
        lines = vim.api.nvim_buf_get_lines(require("anvim.transcript").buf(), 0, -1, false),
        code = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(layout.wins.code)),
        listed = vim.tbl_map(function(b)
          return b.name
        end, vim.fn.getbufinfo({ buflisted = 1 })),
      }
    ]])
    helpers.contains(out.lines, "^❯ Add a comment$")
    helpers.contains(out.lines, "^⏺ Edit%(matchparen%.lua%)$")
    helpers.contains(out.lines, "^  ⎿  Added %d+ lines?, removed %d+ lines?$")
    assert.are.same(helpers.tmp .. "/matchparen.lua", out.code)
    assert.are.same({ helpers.tmp .. "/matchparen.lua" }, out.listed, "only files get a bufferline tab")
  end)

  it("keeps lua-language-server's logs out of the shared mason dir", function()
    start()
    wait(5000, [[return #vim.lsp.get_clients({ name = "lua_ls" }) > 0]], "lua_ls did not start")
    local cmd = lua([[return vim.lsp.get_clients({ name = "lua_ls" })[1].config.cmd]])
    assert(vim.tbl_contains(cmd, "--logpath=" .. xdg .. "/state/anvim/lua_ls"), vim.inspect(cmd))
    assert(vim.tbl_contains(cmd, "--metapath=" .. xdg .. "/cache/anvim/lua_ls/meta"), vim.inspect(cmd))
    assert(
      vim.wait(5000, function()
        return vim.uv.fs_stat(xdg .. "/state/anvim/lua_ls/service.log") ~= nil
      end, 50),
      "lua_ls wrote no log in anvim's state dir"
    )
  end)

  it("answers the LSP editor tools with the lua_ls that LazyVim's lspconfig starts", function()
    start()
    wait(5000, [[return #vim.lsp.get_clients({ name = "lua_ls" }) > 0]], "lua_ls did not start")
    lua([[
      local sidecar = require("anvim.sidecar")
      _G.answers, _G.send = {}, sidecar.send
      sidecar.send = function(msg)
        if msg.type == "editor_response" then
          _G.answers[msg.req] = msg
        else
          _G.send(msg)
        end
      end
      local ask = function(req, method, params)
        sidecar.dispatch({ type = "editor_request", req = req, method = method, params = params })
      end
      ask(9001, "lsp_definition", { path = "matchparen.lua", line = 100, symbol = "char_at" })
      ask(9002, "lsp_document_symbols", { path = "matchparen.lua" })
    ]])
    wait(15000, [[return _G.answers[9001] ~= nil and _G.answers[9002] ~= nil]], "no answers from the editor tools")
    local answers = lua([[
      require("anvim.sidecar").send = _G.send
      return { _G.answers[9001], _G.answers[9002] }
    ]])
    assert.is_nil(answers[1].error, answers[1].error)
    assert(answers[1].result:find("matchparen.lua:12", 1, true), answers[1].result)
    assert(answers[2].result:find("highlight_matching_pair", 1, true), answers[2].result)
  end)

  it("keeps the layout through terminal resizes with the prompt focused", function()
    start()
    lua([[require("anvim.layout").focus_input()]])
    local cmdheight = lua([[return vim.o.cmdheight]])
    for _, size in ipairs({ { 160, 40 }, { 120, 30 }, { 90, 24 }, { 200, 48 } }) do
      lua([[vim.o.columns, vim.o.lines = ...]], size[1], size[2])
      vim.wait(300)
      local out = lua([[
        local layout = require("anvim.layout")
        local showing = vim.tbl_filter(function(win)
          return vim.api.nvim_win_get_buf(win) == require("anvim.input").buf()
        end, vim.api.nvim_list_wins())
        local input, transcript = layout.wins.input, layout.wins.transcript
        return {
          cmdheight = vim.o.cmdheight,
          showing = #showing,
          focused = vim.api.nvim_get_current_win() == input,
          top = vim.fn.win_screenpos(transcript)[1],
          code_top = vim.fn.win_screenpos(layout.wins.code)[1],
          bottom = vim.fn.win_screenpos(input)[1] + vim.api.nvim_win_get_height(input) - 1,
          lines = vim.o.lines,
          errmsg = vim.v.errmsg,
        }
      ]])
      local at = ("at %dx%d"):format(size[1], size[2])
      assert.are.same(cmdheight, out.cmdheight, at)
      assert.are.same(1, out.showing, "one window shows the prompt " .. at)
      assert(out.focused, "the prompt keeps focus " .. at)
      assert.are.same(out.code_top, out.top, "the Claude column starts at the top " .. at)
      assert.are.same(out.lines - out.cmdheight - 1, out.bottom, "the prompt ends above the statusline " .. at)
      assert.are.same("", out.errmsg, at)
    end
  end)

  it("uses the main Neovim's parsers and tools", function()
    start()
    local out = lua([[
      return {
        parser = vim.api.nvim_get_runtime_file("parser/tsx.so", false)[1],
        ts = vim.treesitter.highlighter.active[vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)] ~= nil,
        mason = package.loaded["mason"] and require("mason.settings").current.install_root_dir,
      }
    ]])
    assert.are.same(nvim_data .. "/site/parser/tsx.so", out.parser)
    assert(out.ts, "no treesitter highlighting in the code window")
    assert.are.same(nvim_data .. "/mason", out.mason)
  end)

  it("shows the follow status in lualine from any window", function()
    start()
    assert(statusline():find("◉ following", 1, true), statusline())
    lua([[vim.api.nvim_set_current_win(require("anvim.layout").wins.code)]])
    local file = helpers.tmp .. "/matchparen.lua"
    lua(
      [[require("anvim.sidecar").dispatch({ type = "tool_use", id = "r9", name = "Read", input = { file_path = ... } })]],
      file
    )
    local text = statusline()
    assert(text:find("⏺ Claude at matchparen.lua:1 +1", 1, true), text)
    assert(text:find("(<leader>j)", 1, true), text)
    lua([[require("anvim.layout").focus_input()]])
  end)

  it("puts the activity line in the winbar and the footer under the prompt", function()
    start()
    local out = lua([[
      local input = require("anvim.input")
      local win = require("anvim.layout").wins.input
      local marks = vim.api.nvim_buf_get_extmarks(input.buf(), -1, 0, -1, { details = true })
      local footer = {}
      for _, mark in ipairs(marks) do
        for _, line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(line) do
            footer[#footer + 1] = chunk[1]
          end
        end
      end
      return {
        winbar = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str,
        footer = table.concat(footer),
        height = vim.api.nvim_win_get_height(win),
        width = vim.api.nvim_win_get_width(win),
      }
    ]])
    assert(out.winbar:find("^%d+%.%ds · %$%d+%.%d%d ─"), out.winbar)
    assert(out.footer:find("^ anvim Opus 5%.5  ⧉ In [%w._-]+ +⏵⏵ bypass permissions on"), out.footer)
    assert.are.same(out.width, vim.fn.strdisplaywidth(out.footer))
    assert.are.same(3, out.height, "one prompt line, the footer and the winbar")
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "a", "b", "c" })]])
    wait(
      2000,
      [[return vim.api.nvim_win_get_height(require("anvim.layout").wins.input) == 5]],
      "the prompt did not grow"
    )
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })]])
    wait(
      2000,
      [[return vim.api.nvim_win_get_height(require("anvim.layout").wins.input) == 3]],
      "the prompt did not shrink"
    )
  end)

  it("does not write locked buffers, nor run BufWritePre", function()
    start()
    local file = helpers.tmp .. "/matchparen.lua"
    local stat = assert(vim.uv.fs_stat(file))
    local out = lua(
      [[
      local file = ...
      local layout = require("anvim.layout")
      vim.api.nvim_set_current_win(layout.wins.code)
      vim.cmd.edit(file)
      local pre = 0
      vim.api.nvim_create_autocmd("BufWritePre", { callback = function() pre = pre + 1 end })
      local results = {}
      for _, cmd in ipairs({ "write", "write!", "update" }) do
        local ok, err = pcall(vim.cmd, cmd)
        results[#results + 1] = ok and "ok" or err
      end
      vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "xt", false)
      local maps = {}
      for _, key in ipairs({ "i", "a" }) do
        local map = vim.fn.maparg(key, "n", false, true)
        maps[key] = { desc = map.desc, buffer = map.buffer }
      end
      layout.focus_input()
      return { results = results, pre = pre, errmsg = vim.v.errmsg, maps = maps }
    ]],
      file
    )
    assert.are.same({ "ok", "ok", "ok" }, out.results)
    assert.are.same(0, out.pre, "BufWritePre ran")
    assert.are.same("", out.errmsg)
    local talk = { desc = "Talk to Claude", buffer = 1 }
    assert.are.same({ i = talk, a = talk }, out.maps)
    assert.are.same(stat.mtime, vim.uv.fs_stat(file).mtime, "the file was written")
  end)

  it("pins a buffer in hbac and turns its diagnostics off while a preview runs", function()
    start()
    local file = helpers.tmp .. "/pinned.lua"
    vim.fn.writefile({ "local a = 1", "return a" }, file)
    local out = lua(
      [[
      local file = ...
      local sidecar = require("anvim.sidecar")
      local function field(key, phase, x)
        sidecar.dispatch({ type = "tool_field", id = "p1", name = "Edit", key = key, phase = phase, value = x, text = x })
      end
      local function probe(buf)
        return { pinned = require("hbac.state").is_pinned(buf), diagnostics = vim.diagnostic.is_enabled({ bufnr = buf }) }
      end
      local send = sidecar.send
      sidecar.send = function() end
      sidecar.dispatch({ type = "tool_start", id = "p1", name = "Edit" })
      field("file_path", "end", file)
      local buf = vim.fn.bufnr(file)
      local during = probe(buf)
      sidecar.dispatch({ type = "tool_result", id = "p1", is_error = true, text = "no" })
      sidecar.send = send
      return { during = during, after = probe(buf) }
    ]],
      file
    )
    assert.are.same({ pinned = true, diagnostics = false }, out.during)
    assert.are.same({ pinned = false, diagnostics = true }, out.after)
  end)

  it("sends with <CR> when the menu is closed, and accepts an item when it is open", function()
    start()
    lua([[
      local sidecar = require("anvim.sidecar")
      _G.sent, _G.send = {}, sidecar.send
      sidecar.send = function(msg)
        table.insert(_G.sent, msg)
      end
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "matchpar" })
    ]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "n"]])
    lua([[vim.api.nvim_input("A")]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "i"]], "not in insert mode")
    lua([[require("blink.cmp").show({ providers = { "buffer" } })]])
    wait(3000, [[return require("blink.cmp").is_menu_visible()]], "the menu did not open")
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return vim.api.nvim_get_current_line():find("^matchparen") ~= nil]], "the item was not accepted")
    local word = lua([[return vim.api.nvim_get_current_line()]])
    assert.are.same({}, lua([[return _G.sent]]), "the prompt was sent")
    lua([[require("blink.cmp").hide()]])
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return #_G.sent > 0]], "the prompt was not sent")
    local sent = lua([[
      require("anvim.sidecar").send = _G.send
      require("anvim.input").set_busy(false)
      return _G.sent
    ]])
    assert.are.same(1, #sent)
    assert.are.same({ "prompt", word }, { sent[1].type, sent[1].text })
    assert(sent[1].context and sent[1].context.file, "the prompt has no editor context")

    -- Enter on a slash command completes it and sends it, as in Claude Code.
    -- A command that needs an argument is only completed.
    lua([[
      local sidecar = require("anvim.sidecar")
      _G.sent = {}
      sidecar.send = function(msg)
        table.insert(_G.sent, msg)
      end
      sidecar.dispatch({ type = "commands", commands = {
        { name = "compact", description = "Free up context", argument_hint = "<optional custom summarization instructions>" },
        { name = "batch", description = "Plan a large change", argument_hint = "<instruction>" },
      } })
    ]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "i" and vim.api.nvim_get_current_line() == ""]])
    lua([[vim.api.nvim_input("/compa")]])
    wait(3000, [[return require("blink.cmp").is_menu_visible()]], "no menu after /compa")
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return #_G.sent > 0]], "Enter on /compact did not send it")
    sent = lua([[return _G.sent]])
    assert.are.same({ "prompt", "/compact" }, { sent[1].type, sent[1].text })
    wait(2000, [[return vim.api.nvim_get_current_line() == "" and not require("blink.cmp").is_menu_visible()]])
    lua([[
      require("anvim.input").set_busy(false)
      vim.api.nvim_input("/bat")
    ]])
    wait(3000, [[return require("blink.cmp").is_menu_visible()]], "no menu after /bat")
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return vim.api.nvim_get_current_line() == "/batch "]], "Enter did not complete /batch")
    lua([[vim.wait(300)]])
    assert.are.same(1, #lua([[return _G.sent]]), "Enter sent /batch, which needs an argument")
    lua([[
      require("anvim.sidecar").send = _G.send
      require("blink.cmp").hide()
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      require("anvim.input").set_busy(false)
    ]])
  end)

  it("<Up> moves in blink's menu while it is open, and goes back through past prompts otherwise", function()
    start()
    lua([[
      local sidecar = require("anvim.sidecar")
      local input = require("anvim.input")
      _G.send = sidecar.send
      sidecar.send = function() end
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      for _, text in ipairs({ "first past prompt", "second past prompt" }) do
        vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { text })
        input.submit()
      end
      input.set_busy(false)
      vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "matchpar" })
    ]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "n"]])
    lua([[vim.api.nvim_input("A")]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "i"]], "not in insert mode")
    lua([[require("blink.cmp").show({ providers = { "buffer" } })]])
    wait(3000, [[return require("blink.cmp").is_menu_visible()]], "the menu did not open")
    lua([[vim.api.nvim_input("<Up>")]])
    wait(2000, [[return require("blink.cmp").get_selected_item() ~= nil]], "<Up> selected no item")
    local line = lua([[return vim.api.nvim_get_current_line()]])
    assert(not line:find("past prompt"), "<Up> went to a past prompt while the menu was open: " .. line)
    -- hide() closes the menu from a scheduled callback.
    lua([[require("blink.cmp").hide()]])
    wait(2000, [[return not require("blink.cmp").is_menu_visible()]], "the menu did not close")
    lua([[
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my draft" })
      vim.api.nvim_input("<Up>")
    ]])
    wait(2000, [[return vim.api.nvim_get_current_line() == "second past prompt"]], "<Up> did not go back")
    lua([[vim.api.nvim_input("<Down>")]])
    wait(2000, [[return vim.api.nvim_get_current_line() == "my draft"]], "<Down> did not bring the draft back")
    lua([[
      require("anvim.sidecar").send = _G.send
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    ]])
  end)

  it("pins a visual selection for the prompt, until the cursor moves in the code window", function()
    start()
    local function probe()
      return lua([[
        local footer = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(require("anvim.input").buf(), -1, 0, -1, { details = true })) do
          for _, line in ipairs(mark[4].virt_lines or {}) do
            for _, chunk in ipairs(line) do
              footer[#footer + 1] = chunk[1]
            end
          end
        end
        local sel = require("anvim.context").selection()
        return { footer = table.concat(footer), sel = sel and { sel.start_line, sel.end_line, sel.mode } or false }
      ]])
    end
    lua(
      [[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
      vim.cmd.edit(...)
    ]],
      helpers.tmp .. "/matchparen.lua"
    )
    keys("2GVjj<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l> from visual mode")
    local out = probe()
    assert.are.same({ 2, 4, "line" }, out.sel)
    assert(out.footer:find("⧉ 3 lines selected", 1, true), out.footer)
    keys("<Esc><C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    vim.wait(200)
    assert.are.same({ 2, 4, "line" }, probe().sel, "going back to the code window dropped the pin")
    keys("j")
    wait(2000, [[return require("anvim.context").selection() == nil]], "j kept the pin")
    assert(probe().footer:find("⧉ In matchparen.lua", 1, true), probe().footer)
    keys("5Gvj")
    local pos = lua([[
      local pos = vim.fn.win_screenpos(require("anvim.layout").wins.input)
      return { row = pos[1], col = pos[2] + 3 }
    ]])
    lua(
      [[
      vim.api.nvim_input_mouse("left", "press", "", 0, ...)
      vim.api.nvim_input_mouse("left", "release", "", 0, ...)
    ]],
      pos.row,
      pos.col
    )
    wait_where({ win = "input", mode = "n" }, "a click on the prompt from visual mode")
    assert.are.same({ 5, 6, "char" }, probe().sel)
    lua([[require("anvim.context").clear()]])
    keys("<Esc>")
  end)

  it("pauses follow mode while a selection is pinned, and follows again after the prompt", function()
    start()
    local file, other = helpers.tmp .. "/matchparen.lua", helpers.tmp .. "/pin_other.lua"
    vim.fn.writefile({ "local x = 1", "local yy = 22", "return x" }, other)
    local function read(id)
      lua(
        [[require("anvim.sidecar").dispatch({ type = "tool_use", id = ..., name = "Read", input = { file_path = select(2, ...) } })]],
        id,
        other
      )
    end
    local function code_file()
      return lua([[return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("anvim.layout").wins.code))]])
    end
    -- Types a prompt and sends it, and returns what the plugin sent.
    local function ask()
      lua([[
        local sidecar = require("anvim.sidecar")
        _G.sent, _G.send = {}, sidecar.send
        sidecar.send = function(msg)
          table.insert(_G.sent, msg)
        end
      ]])
      keys("Awhat is this?")
      wait(2000, [[return vim.api.nvim_get_current_line() == "what is this?"]], "the prompt was not typed")
      lua([[require("blink.cmp").hide()]])
      keys("<CR>")
      wait(2000, [[return #_G.sent > 0]], "the prompt was not sent")
      return lua([[
        require("anvim.sidecar").send = _G.send
        require("anvim.input").set_busy(false)
        return _G.sent[1]
      ]])
    end
    local function in_code()
      lua(
        [[
        vim.cmd.stopinsert()
        vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
        vim.cmd.edit(...)
      ]],
        file
      )
    end

    -- Claude reads another file after the user pinned and went to the prompt.
    in_code()
    keys("10G")
    vim.wait(300)
    keys("Vj<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l> with a selection")
    read("pin1")
    vim.wait(100)
    assert.are.same(file, code_file(), "follow mode left the pinned file")
    local text = statusline()
    assert(text:find("⏸ pinned · Claude at pin_other.lua:1 +1", 1, true), text)
    local sent = ask()
    assert.are.same({ 10, 11 }, { sent.context.selection.start_line, sent.context.selection.end_line })
    wait(
      2000,
      ([[return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)) == %q]]):format(
        other
      ),
      "follow mode did not catch up after the prompt"
    )
    assert(statusline():find("◉ following", 1, true), statusline())

    -- Claude reads another file while the user reads, and the user then points.
    keys("<Esc>")
    in_code()
    read("pin2")
    keys("10G")
    vim.wait(300)
    keys("Vj<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l> with a selection")
    vim.wait(100)
    assert.are.same(file, code_file(), "entering the prompt took the pinned file away")
    sent = ask()
    assert.are.same({ "matchparen.lua", 10, 11 }, {
      sent.context.file,
      sent.context.selection.start_line,
      sent.context.selection.end_line,
    })
    keys("<Esc>")
  end)

  it("gives a file that follow mode catches up to its filetype and the read-only lock", function()
    start()
    local fresh = helpers.tmp .. "/caught_up.lua"
    vim.fn.writefile({ "local fresh = 1", "return fresh" }, fresh)
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
    ]])
    lua(
      [[require("anvim.sidecar").dispatch({ type = "tool_use", id = "fresh1", name = "Read", input = { file_path = ... } })]],
      fresh
    )
    keys("<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l>")
    local out = lua(
      [[
      local buf = vim.fn.bufnr(...)
      return {
        shown = vim.api.nvim_win_get_buf(require("anvim.layout").wins.code) == buf,
        ft = vim.bo[buf].filetype,
        modifiable = vim.bo[buf].modifiable,
        ts = vim.treesitter.highlighter.active[buf] ~= nil,
      }
    ]],
      fresh
    )
    assert.are.same({ shown = true, ft = "lua", modifiable = false, ts = true }, out)
    keys("<Esc>")
  end)

  it("puts references in the prompt with visual c, c{motion} and cc, and with @ in the explorer", function()
    start()
    local file = helpers.tmp .. "/matchparen.lua"
    local function prompt()
      return lua([[return vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false)[1] ]])
    end
    local function to_code()
      keys("<Esc><C-h>")
      wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    end
    lua(
      [[
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
      vim.cmd.edit(...)
    ]],
      file
    )
    keys("3GVjc")
    wait_where({ win = "input", mode = "i" }, "visual c")
    assert.are.same("@matchparen.lua#L3-4 ", prompt())
    to_code()
    -- `c` starts the operator at once. Neither mini.surround's `cs` nor
    -- which-key makes it wait for more keys.
    keys("10Gc")
    vim.wait(100)
    assert.are.same("no", vim.rpcrequest(chan, "nvim_get_mode").mode, "c waits for more keys")
    keys("j")
    wait_where({ win = "input", mode = "i" }, "cj")
    assert.are.same("@matchparen.lua#L3-4 @matchparen.lua#L10-11 ", prompt())
    to_code()
    keys("5G2cc")
    wait_where({ win = "input", mode = "i" }, "2cc")
    assert.are.same("@matchparen.lua#L3-4 @matchparen.lua#L10-11 @matchparen.lua#L5-6 ", prompt())

    lua(
      [[
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
      Snacks.explorer.reveal({ file = ... })
      Snacks.picker.get({ source = "explorer" })[1]:focus()
    ]],
      file
    )
    wait_where({ win = "snacks_picker_list", mode = "n" }, "the tree has the cursor")
    wait(
      2000,
      [[return Snacks.picker.get({ source = "explorer" })[1]:current().file:find("matchparen.lua", 1, true) ~= nil]]
    )
    keys("@")
    wait_where({ win = "input", mode = "n" }, "@ in the explorer")
    assert.are.same("@matchparen.lua ", prompt())
    assert.are.same({ 1, #"@matchparen.lua" }, lua([[return vim.api.nvim_win_get_cursor(0)]]), "on the space after it")
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })]])
    keys("<Esc>")
  end)

  it("completes files after @ in the prompt", function()
    start()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "n"]])
    lua([[vim.api.nvim_input("A")]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "i"]], "not in insert mode")
    keys("look at @matchp")
    wait(3000, [[return require("blink.cmp").is_menu_visible()]], "the menu did not open")
    local first = lua([[
      local item = require("blink.cmp").get_items()[1]
      return { item.source_id, item.label }
    ]])
    assert.are.same({ "anvim", "matchparen.lua" }, first)
    keys("<CR>")
    wait(2000, [[return vim.api.nvim_get_current_line() == "look at @matchparen.lua "]], "the file was not accepted")
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })]])
    keys("<Esc>")
  end)

  it("writes the prompt in the compose window with <C-g>, completes there, and :wq brings it back", function()
    start()
    lua([[
      local sidecar = require("anvim.sidecar")
      _G.sent, _G.send = {}, sidecar.send
      sidecar.send = function(msg)
        table.insert(_G.sent, msg)
      end
      sidecar.dispatch({ type = "commands", commands = { { name = "compact", description = "Free up context" } } })
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "n"]])
    lua([[vim.api.nvim_input("A")]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "i"]], "not in insert mode")
    local ok, err = pcall(function()
      keys("first line<C-g>")
      wait(2000, [[return require("anvim.compose").win() == vim.api.nvim_get_current_win()]], "<C-g> opened no window")
      local look = lua([[
      local config = vim.api.nvim_win_get_config(0)
      local tree = 0
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_picker_list" then
          tree = vim.api.nvim_win_get_config(win).zindex
        end
      end
      return {
        size = { config.width, config.height },
        border = config.border ~= nil and config.border ~= "none",
        above_tree = tree > 0 and config.zindex > tree,
        mode = vim.api.nvim_get_mode().mode,
        number = vim.wo.number,
      }
    ]])
      assert.are.same({ size = { 100, 30 }, border = true, above_tree = true, mode = "i", number = true }, look)
      keys("<Esc>osee @matchp")
      wait(
        3000,
        [[
          local cmp = require("blink.cmp")
          local item = cmp.get_items()[1]
          return cmp.is_menu_visible() and item ~= nil and item.label == "matchparen.lua"
        ]],
        "matchparen.lua is not the first item after @"
      )
      keys("<CR>")
      wait(2000, [[return vim.api.nvim_get_current_line() == "see @matchparen.lua "]], "Enter did not accept the file")
      keys("<Esc>ggO/compa")
      wait(
        3000,
        [[
          local cmp = require("blink.cmp")
          local item = cmp.get_items()[1]
          return cmp.is_menu_visible() and item ~= nil and item.label == "/compact"
        ]],
        "/compact is not the first item"
      )
      keys("<CR>")
      wait(2000, [[return vim.api.nvim_get_current_line() == "/compact "]], "Enter did not complete /compact")
      lua([[vim.wait(300)]])
      assert.are.same({}, lua([[return _G.sent]]), "Enter sent from the compose window")
      keys("<Esc>:wq<CR>")
      wait_where({ win = "input", mode = "n" }, ":wq in the compose window")
      assert.are.same(
        { "/compact ", "first line", "see @matchparen.lua " },
        lua([[return vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false)]])
      )
      -- Leaving from normal mode: the prompt gets the compose window's cursor,
      -- in normal mode.
      keys("<C-g>")
      wait(2000, [[return require("anvim.compose").win() == vim.api.nvim_get_current_win()]], "<C-g> opened no window")
      keys("<Esc><C-w>h")
      wait(2000, [[return require("anvim.compose").win() == nil]], "<C-w>h left the window open")
      wait_where({ win = "input", mode = "n" }, "<C-w>h from the compose window")
      keys("anow")
      wait(2000, [[return vim.api.nvim_get_current_line() == "/compact now"]], "typing went on elsewhere")
    end)
    lua([[
      local compose = require("anvim.compose").win()
      if compose then
        vim.api.nvim_win_close(compose, true)
      end
      require("anvim.sidecar").send = _G.send
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    keys("<Esc>")
    assert(ok, err)
  end)

  it("opens Claude's trail with <leader>kt, newest first, and <CR> goes there", function()
    start()
    local file = helpers.tmp .. "/matchparen.lua"
    lua(
      [[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local read = { file_path = ..., offset = 20, limit = 5 }
      require("anvim.sidecar").dispatch({ type = "tool_use", id = "trail1", name = "Read", input = read })
    ]],
      file
    )
    keys("<leader>kt")
    wait(
      3000,
      [[
      local picker = Snacks.picker.get({ source = "anvim_trail" })[1]
      local item = picker and picker:current()
      return item ~= nil and item.where == "matchparen.lua#L20-24"
    ]],
      "the trail does not start with the newest read"
    )
    keys("<CR>")
    wait_where({ win = "code", mode = "n" }, "<CR> in the trail")
    local out = lua([[
      local win = require("anvim.layout").wins.code
      return { name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), line = vim.api.nvim_win_get_cursor(win)[1] }
    ]])
    assert.are.same({ name = file, line = 20 }, out)
    lua([[require("anvim.layout").focus_input()]])
  end)

  it("moves between the code window, the prompt and the tree with window keys", function()
    start()
    lua([[require("anvim.layout").focus_input()]])
    keys("<Esc>")
    wait_where({ win = "input", mode = "n" }, "<Esc> in the prompt")
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    keys("gg<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l> from the top row of the code window")
    keys("<Esc><C-h>G<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l> from the bottom row of the code window")
    keys("<Esc><C-k>")
    wait_where({ win = "input", mode = "n" }, "<C-k> from the prompt")
    keys("<C-w>k")
    wait_where({ win = "input", mode = "n" }, "<C-w>k from the prompt")
    keys("<C-w>p")
    wait_where({ win = "code", mode = "n" }, "<C-w>p goes back to the code window")
    for _, key in ipairs({ "<C-w>l", "<C-l>" }) do
      lua([[
        require("anvim.layout").focus_input()
        vim.cmd.stopinsert()
        Snacks.picker.get({ source = "explorer" })[1]:focus()
      ]])
      wait_where({ win = "snacks_picker_list", mode = "n" }, "the tree has the cursor")
      keys(key)
      wait_where({ win = "code", mode = "n" }, key .. " from the tree")
    end
  end)

  it(
    "resumes typing where it stopped with a in a file buffer, and a click on the prompt moves the cursor there",
    function()
      start()
      local function prompt()
        return lua([[return vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false)[1] ]])
      end
      lua([[require("anvim.layout").focus_input()]])
      wait_where({ win = "input", mode = "i" }, "the prompt")
      keys("hello wor<Esc><C-h>ald")
      wait(2000, [[return vim.api.nvim_get_current_line() == "hello world"]], "typing went on elsewhere: " .. prompt())
      -- The prompt's text starts under the winbar and after "❯ ".
      local pos = lua([[
      local pos = vim.fn.win_screenpos(require("anvim.layout").wins.input)
      return { row = pos[1], col = pos[2] - 1 + 2 + #"hello " }
    ]])
      keys("<Esc><C-h>")
      wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
      lua(
        [[
      vim.api.nvim_input_mouse("left", "press", "", 0, ...)
      vim.api.nvim_input_mouse("left", "release", "", 0, ...)
    ]],
        pos.row,
        pos.col
      )
      wait_where({ win = "input", mode = "n" }, "a click on the prompt")
      keys("ibig ")
      wait(
        2000,
        [[return vim.api.nvim_get_current_line() == "hello big world"]],
        "the click inserted elsewhere: " .. prompt()
      )
      lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })]])
    end
  )

  it("folds splits from window keys, LazyVim keys and pickers back into the code window", function()
    start()
    local file = helpers.tmp .. "/matchparen.lua"
    local function in_code(path)
      lua(
        [[
        vim.cmd.stopinsert()
        vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
        vim.cmd.edit(...)
        vim.api.nvim_win_set_cursor(0, { 20, 0 })
      ]],
        path
      )
    end
    local function assert_folded(what, line)
      local out
      local ok = vim.wait(3000, function()
        out = lua([[
          local code, count = require("anvim.layout").wins.code, 0
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_config(win).relative == "" and require("anvim.layout").is_code(vim.api.nvim_win_get_buf(win)) then
              count = count + 1
            end
          end
          return {
            count = count,
            current = vim.api.nvim_get_current_win() == code,
            name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code)),
            line = vim.api.nvim_win_get_cursor(code)[1],
          }
        ]])
        return out.count == 1 and out.current and out.name == file
      end, 20)
      assert(ok, what .. ": " .. vim.inspect(out))
      if line then
        assert.are.same(line, out.line, what)
      end
    end
    for _, key in ipairs({ "<C-w>v", "<C-w>s", "<leader>-", "<leader>|", ":vsplit<CR>" }) do
      in_code(file)
      keys(key)
      assert_folded(key, 20)
    end
    in_code(helpers.tmp .. "/session.jsonl")
    lua([[Snacks.picker.files()]])
    -- The picker opens once its finder has results, later while a language
    -- server loads, and starts insert mode after that. Keys typed before go
    -- to the code window, or run as normal-mode commands in the picker.
    wait(
      5000,
      [[return vim.bo.filetype == "snacks_picker_input" and vim.api.nvim_get_mode().mode == "i"]],
      "the picker did not open"
    )
    keys("matchparen.lua")
    wait(
      5000,
      [[
        local picker = Snacks.picker.get({ source = "files" })[1]
        local item = picker and picker:current()
        return item ~= nil and item.file:find("matchparen.lua", 1, true) ~= nil
      ]],
      "the picker did not find the file"
    )
    keys("<C-v>")
    assert_folded("the picker's vsplit")
    local notes = lua([[
      local notes = {}
      for _, note in ipairs(Snacks.notifier.get_history()) do
        if note.msg:find("one code window", 1, true) then
          notes[#notes + 1] = note.msg
        end
      end
      return notes
    ]])
    assert.are.same(1, #notes, "the notice shows once")
    lua([[require("anvim.layout").focus_input()]])
  end)

  it("keeps help and quickfix windows, and :q there closes only them", function()
    start()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
    ]])
    for _, cmd in ipairs({ ":help help<CR>", ":copen<CR>" }) do
      keys(cmd)
      local ft = cmd == ":copen<CR>" and "qf" or "help"
      wait_where({ win = ft, mode = "n" }, cmd)
      vim.wait(200)
      wait_where({ win = ft, mode = "n" }, cmd .. " keeps its window")
      keys(":q<CR>")
      wait(
        2000,
        ([[
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == %q then
              return false
            end
          end
          return true
        ]]):format(ft),
        ":q did not close the " .. ft .. " window"
      )
      assert_layout(":q in the " .. ft .. " window")
      lua([[vim.api.nvim_set_current_win(require("anvim.layout").wins.code)]])
    end
  end)

  it("enters and leaves read mode, with keys under <leader>k only", function()
    start()
    lua([[
      require("anvim.layout").focus_input()
      vim.cmd.stopinsert()
    ]])
    for _, key in ipairs({ "q", "<Esc>", "i" }) do
      keys("<leader>kr")
      wait_where({ win = "transcript", mode = "n" }, "<leader>kr")
      keys(key)
      wait_where({ win = "input", mode = key == "i" and "i" or "n" }, key .. " in read mode")
      keys("<Esc>")
      wait_where({ win = "input", mode = "n" }, "<Esc> in the prompt")
    end
    keys("<C-h><C-l><Esc><leader>kr")
    wait_where({ win = "transcript", mode = "n" }, "<leader>kr")
    keys("q<Esc><C-w>p")
    wait_where({ win = "code", mode = "n" }, "<C-w>p after read mode goes to the window before the prompt")
    keys("<leader>kr")
    wait_where({ win = "transcript", mode = "n" }, "<leader>kr")
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from read mode")
    keys("gg<C-l>")
    wait_where({ win = "input", mode = "n" }, "leaving the transcript ended read mode")
    keys("<Esc>")
    local out = lua([[
      local maps = {}
      for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
        if map.lhs:sub(1, 2) == vim.g.mapleader .. "k" then
          maps[map.lhs:sub(2)] = map.desc
        end
      end
      local groups = {}
      for _, m in ipairs(require("which-key.config").mappings) do
        if m.lhs == "<leader>k" then
          groups[#groups + 1] = { desc = m.desc, group = m.group }
        end
      end
      return { maps = maps, groups = groups }
    ]])
    assert.are.same({
      kj = "Jump to where Claude is",
      km = "Choose the model",
      kr = "Read the transcript",
      ks = "Resume a session",
      kt = "Claude's trail",
      ky = "Yank Claude's last reply",
    }, out.maps)
    assert.are.same({ { desc = "claude", group = true } }, out.groups)
  end)

  it("reopens a closed code window between the tree and the Claude column", function()
    start()
    for _, key in ipairs({ ":close<CR>", "<C-w>c", "<leader>wd" }) do
      lua(
        [[
        vim.cmd.stopinsert()
        vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
        vim.cmd.edit(...)
      ]],
        helpers.tmp .. "/matchparen.lua"
      )
      keys(key)
      wait_where({ win = "code", mode = "n" }, key .. " puts the cursor in the new code window")
      assert_layout(key .. " in the code window")
      local name =
        lua([[return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("anvim.layout").wins.code))]])
      assert.are.same(helpers.tmp .. "/matchparen.lua", name, key .. " keeps the file")
    end
  end)

  it("reopens closed windows after :only and <C-w>c", function()
    start()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
    ]])
    keys(":only<CR>")
    assert_layout(":only in the code window")
    wait_where({ win = "code", mode = "n" }, ":only keeps the cursor in the code window")
    keys("<C-l><Esc><C-w>c")
    assert_layout("<C-w>c in the prompt")
    wait_where({ win = "input", mode = "n" }, "<C-w>c in the prompt")
    keys("<Esc><C-w>o")
    assert_layout("<C-w>o in the prompt")
    lua([[require("anvim.layout").focus_input()]])
  end)

  it("keeps a scrolled-up transcript in place, and a click in it lands in the prompt", function()
    start()
    lua([[
      require("anvim.layout").focus_input()
      for i = 1, 80 do
        require("anvim.transcript").notice("warn", "line " .. i)
      end
    ]])
    local function view()
      return lua([[
        local win = require("anvim.layout").wins.transcript
        return { top = vim.fn.line("w0", win), bottom = vim.fn.line("w$", win), last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) }
      ]])
    end
    local pos = lua([[
      local pos = vim.fn.win_screenpos(require("anvim.layout").wins.transcript)
      return { row = pos[1] - 1 + 10, col = pos[2] - 1 + 10 }
    ]])
    local at_end = view()
    assert.are.same(at_end.last, at_end.bottom, "the transcript shows its end")
    for _ = 1, 2 do
      lua([[vim.api.nvim_input_mouse("wheel", "up", "", 0, ...)]], pos.row, pos.col)
    end
    assert(
      vim.wait(2000, function()
        return view().top < at_end.top
      end, 20),
      "the wheel did not scroll the transcript"
    )
    wait_where({ win = "input", mode = "i" }, "the wheel leaves the cursor in the prompt")
    local top = view().top
    lua([[require("anvim.transcript").notice("warn", "more")]])
    vim.wait(100)
    assert.are.same(top, view().top, "new output leaves the scrolled view alone")
    keys("<Esc><C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    lua(
      [[
      vim.api.nvim_input_mouse("left", "press", "", 0, ...)
      vim.api.nvim_input_mouse("left", "release", "", 0, ...)
    ]],
      pos.row,
      pos.col
    )
    wait_where({ win = "input", mode = "n" }, "a click in the transcript")
    keys("<Esc>")
  end)

  it("selects text with a mouse drag in the transcript, at its top and its bottom", function()
    start()
    lua([[
      require("anvim.layout").focus_input()
      for i = 1, 60 do
        require("anvim.transcript").notice("warn", "row text " .. i)
      end
    ]])
    local function drag(row, what, moving)
      local tr = lua([[
        local win = require("anvim.layout").wins.transcript
        local pos = vim.fn.win_screenpos(win)
        return { row = pos[1] - 1, col = pos[2] - 1, top = vim.fn.line("w0", win) }
      ]])
      lua([[vim.api.nvim_input_mouse("left", "press", "", 0, ...)]], tr.row + row, tr.col + 4)
      for i = 1, 4 do
        vim.wait(60)
        lua([[vim.api.nvim_input_mouse("left", "drag", "", 0, ...)]], tr.row + row + i, tr.col + 8)
      end
      vim.wait(60)
      lua([[vim.api.nvim_input_mouse("left", "release", "", 0, ...)]], tr.row + row + 4, tr.col + 8)
      wait_where({ win = "transcript", mode = "v" }, what .. " selects in the transcript")
      if not moving then
        local got = lua([[return { vim.fn.getpos("v")[2], vim.fn.line(".") }]])
        assert.are.same({ tr.top + row, tr.top + row + 4 }, got, what)
      end
      keys("<Esc>q")
      wait_where({ win = "input", mode = "n" }, "q after the drag")
    end
    drag(2, "a drag from the top row")
    lua([[require("anvim.windows").scroll("<C-u>")]])
    -- snacks.scroll animates the view. Drag once it stands still.
    local top
    vim.wait(2000, function()
      local now = lua([[return vim.fn.line("w0", require("anvim.layout").wins.transcript)]])
      local still = now == top
      top = now
      return still
    end, 100)
    local height = lua([[return vim.api.nvim_win_get_height(require("anvim.layout").wins.transcript)]])
    drag(height - 6, "a drag near the bottom row")
    -- The steps of the scroll animation must not cancel the drag.
    lua([[require("anvim.windows").scroll("<C-u>")]])
    drag(10, "a drag while the view scrolls", true)
    keys("<Esc>")
  end)

  it("keeps the prompt in normal mode while a request waits", function()
    start()
    local pos = lua([[
      require("anvim.state").waiting = "To answer: esc, then 1-3"
      vim.cmd.stopinsert()
      local pos = vim.fn.win_screenpos(require("anvim.layout").wins.input)
      return { row = pos[1], col = pos[2] + 3 }
    ]])
    local ok, err = pcall(function()
      keys("<C-h>gg<C-l>")
      wait_where({ win = "input", mode = "n" }, "<C-l> while a request waits")
      keys("<C-h>")
      wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
      lua(
        [[
        vim.api.nvim_input_mouse("left", "press", "", 0, ...)
        vim.api.nvim_input_mouse("left", "release", "", 0, ...)
      ]],
        pos.row,
        pos.col
      )
      wait_where({ win = "input", mode = "n" }, "a click on the prompt while a request waits")
    end)
    lua([[require("anvim.state").waiting = nil]])
    assert(ok, err)
  end)

  -- The permission cases press keys at a user's pace, so the 0.4 s guard is on.
  local function capture()
    lua([[
      local sidecar = require("anvim.sidecar")
      _G.sent, _G.send = {}, sidecar.send
      sidecar.send = function(msg)
        table.insert(_G.sent, msg)
      end
    ]])
  end

  local function release()
    return lua([[
      require("anvim.sidecar").send = _G.send
      return _G.sent
    ]])
  end

  local function ask(req, command)
    lua(
      [[
      local req, command = ...
      local sidecar, id, input = require("anvim.sidecar"), "pq" .. req, { command = command }
      sidecar.dispatch({ type = "tool_start", id = id, name = "Bash" })
      sidecar.dispatch({ type = "tool_use", id = id, name = "Bash", input = input })
      sidecar.dispatch({ type = "permission_request", req = req, tool_use_id = id, tool = "Bash", input = input })
    ]],
      req,
      command
    )
  end

  local function answers()
    return lua([[
      return vim.tbl_filter(function(msg)
        return msg.type ~= "preview_done"
      end, _G.sent)
    ]])
  end

  local function prompt()
    return lua([[
      local win = require("anvim.layout").wins.input
      return {
        lines = vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false),
        mode = vim.api.nvim_get_mode().mode,
        col = vim.api.nvim_win_get_cursor(win)[2],
        waiting = require("anvim.permission").waiting(),
      }
    ]])
  end

  -- One key at a time, as a user types.
  local function type_keys(text, ms)
    for char in text:gmatch(".") do
      lua([[vim.api.nvim_input(...)]], char == "<" and "<lt>" or char)
      vim.wait(ms)
    end
  end

  it("shows a permission request in lualine and the winbar, and answers it from the prompt", function()
    start()
    capture()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
    ]])
    ask(77, "make")
    local out = lua([[
      local layout = require("anvim.layout")
      local win = layout.wins.input
      return {
        code = vim.api.nvim_get_current_win() == layout.wins.code,
        winbar = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str,
      }
    ]])
    assert(out.code, "the request took focus")
    assert(out.winbar:find("^⏺ To answer: esc, then 1%-2 or j/k and enter ─"), out.winbar)
    local text = statusline()
    assert(text:find("⏺ Claude is waiting", 1, true), text)
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
    ]])
    vim.wait(500)
    lua([[vim.api.nvim_input("1")]])
    wait(2000, [[return #_G.sent > 0]], "no answer was sent")
    assert.are.same({ { type = "permission_response", req = 77, behavior = "allow" } }, release())
    lua([[require("anvim.sidecar").dispatch({ type = "tool_result", id = "pq77", is_error = false, text = "ok" })]])
    assert(not statusline():find("Claude is waiting", 1, true), statusline())
  end)

  it("keeps typing when a request opens: prose, digits and enter never answer", function()
    start()
    capture()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    lua([[vim.api.nvim_input("i")]])
    vim.wait(100)
    type_keys("also fix ", 50)
    ask(78, "rm -rf build")
    type_keys("the test in step 2", 50)
    lua([[require("blink.cmp").hide()]])
    -- Past the guard, so only insert mode keeps enter from answering.
    vim.wait(500)
    lua([[vim.api.nvim_input("<CR>")]])
    vim.wait(300)
    local out = prompt()
    assert.are.same({}, answers(), "typing answered or sent something")
    assert(out.waiting, "the request is gone")
    assert.are.same({ "also fix the test in step 2" }, out.lines)
    assert.are.same("i", out.mode, "insert mode ended")
    -- Esc leaves insert mode, and 1 answers once the guard has passed.
    lua([[vim.api.nvim_input("<Esc>")]])
    vim.wait(500)
    lua([[vim.api.nvim_input("1")]])
    wait(2000, [[return #_G.sent > 0]], "1 did not answer")
    assert.are.same({ { type = "permission_response", req = 78, behavior = "allow" } }, answers())
    vim.wait(100)
    out = prompt()
    assert.are.same({ "also fix the test in step 2" }, out.lines)
    assert.are.same({ "i", #out.lines[1] }, { out.mode, out.col }, "typing goes on where it stopped")
    release()
    lua([[
      require("anvim.sidecar").dispatch({ type = "tool_result", id = "pq78", is_error = false, text = "ok" })
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
  end)

  it("never answers while enter is held down", function()
    start()
    capture()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
    ]])
    lua([[vim.api.nvim_input("i")]])
    vim.wait(50)
    -- Key repeat at 30 Hz, and the request opens at 0.3 s.
    local t0, opened = vim.uv.now(), false
    while vim.uv.now() - t0 < 1200 do
      if not opened and vim.uv.now() - t0 > 300 then
        ask(79, "git push --force")
        opened = true
      end
      lua([[vim.api.nvim_input("<CR>")]])
      vim.wait(33)
    end
    vim.wait(200)
    assert.are.same({}, answers())
    assert(prompt().waiting, "the request is gone")
    release()
    lua([[
      require("anvim.sidecar").dispatch({ type = "permission_cancel", req = 79 })
      require("anvim.sidecar").dispatch({ type = "tool_result", id = "pq79", is_error = true, text = "cancelled" })
      vim.cmd.stopinsert()
    ]])
  end)

  it("takes no answer from esc and enter, the habit of sending a prompt", function()
    start()
    capture()
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    lua([[vim.api.nvim_input("i")]])
    vim.wait(100)
    type_keys("ship it", 50)
    ask(80, "make deploy")
    vim.wait(1000)
    lua([[require("blink.cmp").hide()]])
    lua([[vim.api.nvim_input("<Esc>")]])
    vim.wait(150)
    lua([[vim.api.nvim_input("<CR>")]])
    vim.wait(300)
    assert.are.same({}, answers(), "esc and enter answered")
    assert(prompt().waiting, "the request is gone")
    -- Enter chooses after j or k.
    lua([[vim.api.nvim_input("jk")]])
    vim.wait(100)
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return #_G.sent > 0]], "j, k and enter did not answer")
    assert.are.same({ { type = "permission_response", req = 80, behavior = "allow" } }, answers())
    release()
    lua([[
      require("anvim.sidecar").dispatch({ type = "tool_result", id = "pq80", is_error = false, text = "ok" })
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
  end)

  it(":q in the prompt quits anvim with two tabs, cleanly, and leaves the main Neovim untouched", function()
    start()
    lua([[require("anvim.layout").focus_input()]])
    keys("<Esc>:tabnew<CR>")
    wait(2000, [[return #vim.api.nvim_list_tabpages() == 2]], ":tabnew opened no tab")
    keys("gT")
    wait_where({ win = "input", mode = "n" }, "gT goes back to the prompt")
    keys("<Esc>:q<CR>")
    chan = nil
    local code = vim.fn.jobwait({ job }, 5000)
    if code[1] == -1 then
      vim.fn.jobstop(job)
    end
    assert.are.same({ 0 }, code, ":q in the prompt did not quit")
    local path = xdg .. "/state/anvim/anvim.log"
    local log = vim.uv.fs_stat(path) and vim.fn.readfile(path) or {}
    for _, line in ipairs(log) do
      assert(not line:find("failed", 1, true), table.concat(log, "\n"))
    end
    assert.are.same(before, mtimes())
    for _, dir in ipairs({ "lazy", "mason", "site/parser" }) do
      assert(not vim.uv.fs_stat(xdg .. "/data/anvim/" .. dir), "anvim installed into its own " .. dir)
    end
  end)
end)
