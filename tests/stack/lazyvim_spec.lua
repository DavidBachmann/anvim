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
    if key:match("^XDG_") or key:match("^LAZY_") or key:match("^NVIM") then
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
end

-- The global statusline's text, from the current window's lualine value.
local function statusline()
  return lua([[
    require("lualine").refresh({ force = true, place = { "statusline" } })
    local win = vim.api.nvim_get_current_win()
    return vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win }).str
  ]])
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
    assert(out.footer:find("^ anvim Opus 5%.5 +⏵⏵ bypass permissions on"), out.footer)
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
    assert.are.same({ { type = "prompt", text = word } }, sent)
  end)

  it("quits cleanly and leaves the main Neovim untouched", function()
    start()
    pcall(vim.rpcrequest, chan, "nvim_command", "qa!")
    chan = nil
    assert.are.same({ 0 }, vim.fn.jobwait({ job }, 5000), "the child did not exit")
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
