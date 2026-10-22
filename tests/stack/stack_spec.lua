---@module "luassert"

-- Boots the real init.lua in a child Neovim, as bin/anvim does. Its state,
-- cache, config and data dirs are temporary. Its plugins and mason packages
-- come from .tests/anvim, which scripts/test-deps fills, and must stay
-- unchanged. So must the main Neovim's dirs.
local helpers = require("helpers")

local home = assert(vim.env.HOME)
local nvim_config = home .. "/.config/nvim"
local nvim_data = home .. "/.local/share/nvim"
local install = helpers.root .. "/.tests/anvim"
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
    helpers.root .. "/lazy-lock.json",
    install .. "/lazy-lock.json",
    install .. "/stamp",
    install .. "/lazy",
    install .. "/site",
    install .. "/site/parser",
    install .. "/mason",
    install .. "/mason/bin",
    install .. "/mason/packages",
  }
  for _, dir in ipairs({ nvim_data .. "/lazy", install .. "/lazy" }) do
    if vim.uv.fs_stat(dir) then
      for name in vim.fs.dir(dir) do
        paths[#paths + 1] = dir .. "/" .. name
      end
    end
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

-- Starts a child with its dirs under `dir`, and connects `chan` to it.
-- With `personal`, its config dir holds a personal spec with those lines, as
-- in ~/.config/anvim/lua/plugins.
---@param dir string
---@param personal string[]?
---@param errors string[] Collects the child's stderr.
---@return integer job
local function spawn(dir, personal, errors)
  local env = vim.fn.environ()
  for key in pairs(env) do
    -- Without the cmux variables, the child posts no notifications. A shell
    -- profile can set ANVIM_MODE, ANVIM_EFFORT or ANVIM_SANDBOX, and the child
    -- runs in the default mode, with the default effort and the sandbox.
    if
      key:match("^XDG_")
      or key:match("^LAZY_")
      or key:match("^NVIM")
      or key:match("^CMUX_")
      or key == "ANVIM_MODE"
      or key == "ANVIM_EFFORT"
      or key == "ANVIM_SANDBOX"
    then
      env[key] = nil
    end
  end
  env.NVIM_APPNAME = "anvim"
  for _, name in ipairs({ "config", "data", "state", "cache" }) do
    env[("XDG_%s_HOME"):format(name:upper())] = dir .. "/" .. name
  end
  if personal then
    local plugins = dir .. "/config/anvim/lua/plugins"
    vim.fn.mkdir(plugins, "p")
    vim.fn.writefile(personal, plugins .. "/personal.lua")
  end
  env.ANVIM_INSTALL_DIR = install
  env.ANVIM_NO_INSTALL = "1"
  env.ANVIM_REPLAY = helpers.recording
  env.ANVIM_REPLAY_SPEED = "50"
  env.ANVIM_MODEL = "haiku"
  local addr = dir .. ".sock"
  local id = vim.fn.jobstart({
    vim.v.progpath,
    "--headless",
    "--listen",
    addr,
    "--cmd",
    "set columns=200 lines=48",
    "--cmd",
    "luafile " .. helpers.root .. "/tests/stack/record_keys.lua",
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
          errors[#errors + 1] = line
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
  return id
end

-- The child that most cases share. It has no personal spec.
local function start()
  if chan then
    return
  end
  job = spawn(xdg, nil, stderr)
  tree_width = lua([[
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local snacks_win = vim.w[win].snacks_win
      if vim.api.nvim_win_get_config(win).relative == "" and snacks_win and snacks_win.position == "left" then
        return vim.api.nvim_win_get_width(win)
      end
    end
  ]])
end

-- The global statusline's text, as Neovim draws it for the current window.
local function statusline()
  return lua([[
    local win = vim.api.nvim_get_current_win()
    return vim.api.nvim_eval_statusline(vim.go.statusline, { winid = win }).str
  ]])
end

-- The footer under the prompt, as drawn: its text, and the group of the
-- chunk that holds `needle`.
---@return { text: string, group: string? }
local function footer(needle)
  return lua(
    [[
    local needle = ...
    local ns = vim.api.nvim_get_namespaces()["anvim.input"]
    local mark = vim.api.nvim_buf_get_extmarks(require("anvim.input").buf(), ns, 0, -1, { details = true })[1]
    local text, group = {}, nil
    for _, chunk in ipairs(mark and mark[4].virt_lines[1] or {}) do
      text[#text + 1] = chunk[1]
      if needle ~= vim.NIL and not group and chunk[1]:find(needle, 1, true) then
        group = chunk[2]
      end
    end
    return { text = table.concat(text), group = group }
  ]],
    needle or vim.NIL
  )
end

-- Waits until the footer holds each text.
local function wait_footer(texts, msg)
  local got
  local ok = vim.wait(3000, function()
    got = footer().text
    for _, t in ipairs(texts) do
      if not got:find(t, 1, true) then
        return false
      end
    end
    return true
  end, 20)
  assert(ok, ("%s: %s"):format(msg, got))
end

-- Types keys in the child. Its main loop runs them after this call returns,
-- through which-key and anvim's maps, as for a user.
local function keys(k)
  lua([[vim.api.nvim_feedkeys(vim.keycode(...), "t", false)]], k)
end

-- Waits until the completion menu shows with its first item highlighted, and
-- returns the item.
local function menu_first(msg)
  wait(
    3000,
    [[return vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected == 0]],
    msg or "no menu with its first item highlighted"
  )
  return lua([[return vim.fn.complete_info({ "completed" }).completed]])
end

-- Closes the completion menu, which would take <CR>.
local function hide_menu()
  lua([[
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.keycode("<C-e>"), "n", false)
    end
  ]])
  wait(2000, [[return vim.fn.pumvisible() == 0]], "the menu did not close")
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

describe("stack", function()
  it("opens the layout without LazyVim or the main Neovim's dirs", function()
    start()
    local info = lua([[
      local layout = require("anvim.layout")
      local ret = { tree = false, laststatus = vim.o.laststatus, lazyvim = package.loaded["lazyvim.config"] ~= nil }
      ret.rtp = vim.opt.rtp:get()
      for role, win in pairs(layout.wins) do
        local buf = vim.api.nvim_win_get_buf(win)
        ret[role] = { ft = vim.bo[buf].filetype, spell = vim.wo[win].spell, ts = vim.treesitter.highlighter.active[buf] ~= nil }
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        ret.tree = ret.tree or vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_picker_list"
      end
      return ret
    ]])
    assert(not info.lazyvim, "LazyVim is loaded")
    for _, dir in ipairs(info.rtp) do
      assert(not vim.startswith(dir, nvim_config), dir)
      assert(not vim.startswith(dir, nvim_data), dir)
    end
    assert.are.same(3, info.laststatus)
    assert(info.tree, "the explorer is not open")
    assert.are.same({ ft = "anvim_transcript", spell = false, ts = true }, info.transcript)
    assert.are.same({ ft = "anvim_input", spell = false, ts = true }, info.input)
    assert(info.code, "code window missing")
  end)

  it("passes ANVIM_MODEL on", function()
    start()
    assert.are.same("haiku", lua([[return require("anvim.config").options.model]]))
  end)

  it("starts in the default permission mode without ANVIM_MODE, so Claude asks before it runs a tool", function()
    start()
    assert.are.same("default", lua([[return require("anvim.config").options.permission_mode]]))
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
    assert.are.same({ helpers.tmp .. "/matchparen.lua" }, out.listed, "only files are listed")
  end)

  it("starts mason's lua-language-server, with its logs out of the mason package", function()
    start()
    wait(5000, [[return #vim.lsp.get_clients({ name = "lua_ls" }) > 0]], "lua_ls did not start")
    assert.are.same(install .. "/mason/bin/lua-language-server", lua([[return vim.fn.exepath("lua-language-server")]]))
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

  it("answers the LSP editor tools with the lua_ls that anvim's lspconfig and mason start", function()
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

  it("takes plugins and mason packages from the install dir, and installs parsers there", function()
    start()
    local out = lua([[
      local plugins = {}
      for _, plugin in ipairs(require("lazy").plugins()) do
        plugins[plugin.name] = plugin.dir
      end
      return {
        root = require("lazy.core.config").options.root,
        plugins = plugins,
        parser_dir = require("nvim-treesitter.config").get_install_dir("parser"),
        parsers = vim.api.nvim_get_runtime_file("parser/*.so", true),
        rtp = vim.opt.rtp:get(),
        ts = vim.treesitter.highlighter.active[vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)] ~= nil,
        mason = package.loaded["mason"] and require("mason.settings").current.install_root_dir,
      }
    ]])
    assert.are.same(install .. "/lazy", out.root)
    for name, dir in pairs(out.plugins) do
      if name ~= "anvim" then
        assert.are.same(install .. "/lazy/" .. name, dir)
      end
    end
    assert.are.same(install .. "/site/parser", out.parser_dir)
    assert(vim.tbl_contains(out.rtp, install .. "/site"), "the install dir's parsers are not on the runtimepath")
    -- Neovim's own parsers, as test-deps installs none.
    for _, parser in ipairs(out.parsers) do
      assert(not vim.startswith(parser, nvim_data), parser)
    end
    assert(out.ts, "no treesitter highlighting in the code window")
    assert.are.same(install .. "/mason", out.mason)
  end)

  it("shows the follow status in the footer from any window, and not in the statusline", function()
    start()
    wait_footer({ "◉ following" }, "the footer in the prompt")
    assert(not statusline():find("following", 1, true), statusline())
    lua([[vim.api.nvim_set_current_win(require("anvim.layout").wins.code)]])
    local file = helpers.tmp .. "/matchparen.lua"
    lua(
      [[require("anvim.sidecar").dispatch({ type = "tool_use", id = "r9", name = "Read", input = { file_path = ... } })]],
      file
    )
    -- The narrow column takes the short form, without "Claude at".
    wait_footer({ "⏺ ", "matchparen.lua:1 +1" }, "the footer in the code window")
    assert(not statusline():find("matchparen.lua:1", 1, true), statusline())
    -- A column too narrow for it leaves the follow status to the statusline.
    lua([[vim.o.columns, vim.o.lines = 90, 24]])
    local ok = vim.wait(3000, function()
      return not footer().text:find("matchparen.lua:1", 1, true)
        and statusline():find("⏺ matchparen.lua:1 +1", 1, true) ~= nil
    end, 20)
    assert(ok, ("footer %q, statusline %q"):format(footer().text, statusline()))
    lua([[vim.o.columns, vim.o.lines = 200, 48]])
    wait_footer({ "⏺ ", "matchparen.lua:1 +1" }, "the footer at 200x48")
    assert(not statusline():find("matchparen.lua:1", 1, true), statusline())
    lua([[require("anvim.layout").focus_input()]])
  end)

  it("shows follow mode in the mode block, and line numbers only in review mode, as the config sets them", function()
    start()
    -- The mode block's text and color, the section separator after it, and
    -- the code window's numbers.
    local function block()
      return lua([[
        local win = vim.api.nvim_get_current_win()
        local code = require("anvim.layout").wins.code
        local stl = vim.api.nvim_eval_statusline(vim.go.statusline, { winid = win, highlights = true })
        local text = stl.str:match("^ (%u+) ")
        local function at(byte)
          local group
          for _, h in ipairs(stl.highlights) do
            if h.start <= byte then
              group = h.group
            end
          end
          return vim.api.nvim_get_hl(0, { name = group, link = false })
        end
        local sep = #text + 2
        local left = "\238\130\176"
        return {
          text = text,
          bg = at(0).bg,
          sep_fg = at(sep).fg,
          sep = stl.str:sub(sep + 1, sep + #left) == left,
          number = vim.wo[code].number,
          relativenumber = vim.wo[code].relativenumber,
          statuscolumn = vim.wo[code].statuscolumn,
          signcolumn = vim.wo[code].signcolumn,
          mode = require("anvim.follow").mode(),
        }
      ]])
    end
    ---@param relativenumber boolean What the config sets.
    local function check(relativenumber)
      local claude = lua([[return vim.api.nvim_get_hl(0, { name = "AnvimClaude", link = false }).fg]])
      lua([[require("anvim.layout").focus_input({ insert = false })]])
      local got = block()
      assert.are.same(
        { "FOLLOW", "follow", false, false, "yes:2" },
        { got.text, got.mode, got.number, got.relativenumber, got.signcolumn }
      )
      assert(got.statuscolumn:find("anvim.follow", 1, true), got.statuscolumn)
      assert.are.same(claude, got.bg, "the block is not in Claude's color")
      assert.is_true(got.sep, "no section separator after the block")
      assert.are.same(claude, got.sep_fg, "the separator after the block has another color")
      keys("i")
      wait(2000, [[return vim.api.nvim_get_mode().mode == "i"]], "not in insert mode")
      assert.are.same("FOLLOW", block().text, "typing in the prompt left follow mode")
      keys("<Esc>")
      -- The next request can come before the typed key.
      wait(2000, [[return vim.api.nvim_get_mode().mode == "n"]], "<Esc> did not end insert mode")
      lua([[vim.api.nvim_set_current_win(require("anvim.layout").wins.code)]])
      got = block()
      assert.are.same(
        { "NORMAL", "review", true, relativenumber, "yes" },
        { got.text, got.mode, got.number, got.relativenumber, got.signcolumn }
      )
      assert(got.statuscolumn:find("snacks.statuscolumn", 1, true), got.statuscolumn)
      assert.are_not.same(claude, got.bg)
      assert.are_not.same(claude, got.sep_fg)
      lua([[require("anvim.layout").focus_input({ insert = false })]])
      assert.are.same("FOLLOW", block().text)
    end
    check(true)
    -- A personal spec turns off 'relativenumber', in a child of its own.
    local shared, errors = chan, {}
    local id = spawn(helpers.tmp .. "/xdg-personal", { "vim.opt.relativenumber = false", "return {}" }, errors)
    local ok, err = pcall(check, false)
    pcall(vim.rpcnotify, chan, "nvim_command", "qa!")
    if vim.fn.jobwait({ id }, 5000)[1] == -1 then
      vim.fn.jobstop(id)
    end
    chan = shared
    assert(ok, err)
    assert.are.same({}, errors)
  end)

  it("follows an agent with <leader>c1 and the Agent Overview, and the footer names it in its color", function()
    start()
    -- A file of its own: a cursor that this case moves would make a later 2G scroll.
    local file = helpers.tmp .. "/focus_stack.lua"
    local lines = {}
    for i = 1, 40 do
      lines[i] = ("local line%d = %d"):format(i, i)
    end
    vim.fn.writefile(lines, file)
    -- Running agents would show in the next cases' footers.
    local ok, err = pcall(function()
      lua(
        [[
        require("anvim.layout").focus_input()
        vim.cmd.stopinsert()
        local sidecar = require("anvim.sidecar")
        for _, id in ipairs({ "s1", "s2" }) do
          sidecar.dispatch({
            type = "agent_start",
            agent_id = id,
            tool_use_id = "tu_" .. id,
            description = "Stack " .. id,
            subagent_type = id == "s2" and "Explore" or "general-purpose",
            depth = 1,
            background = false,
          })
        end
        local read = { file_path = ..., offset = 30 }
        sidecar.dispatch({ type = "tool_use", id = "s2r", name = "Read", input = read, parent_id = "tu_s2", agent_id = "s2" })
      ]],
        file
      )
      -- In the code window, with a pinned selection, an empty slot only says so.
      lua(
        [[
        vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
        vim.cmd.edit(...)
        _G.said, _G.notify = {}, vim.notify
        vim.notify = function(msg, ...)
          table.insert(_G.said, msg)
          return _G.notify(msg, ...)
        end
      ]],
        file
      )
      keys("2GVj<Esc>")
      wait(2000, [[return require("anvim.context").selection() ~= nil]], "Vj<Esc> pinned nothing")
      keys("<leader>c3")
      wait(3000, [[return vim.tbl_contains(_G.said, "No agent in slot 3")]], "<leader>c3 said nothing")
      local probe = [[
        local sel = require("anvim.context").selection()
        local follow = require("anvim.follow")
        return { focus = follow.focus or false, mode = follow.mode(), sel = sel and { sel.start_line, sel.end_line } or false }
      ]]
      assert.are.same({ win = "code", mode = "n" }, where(), "<leader>c3 moved the cursor")
      assert.are.same({ focus = false, mode = "review", sel = { 2, 3 } }, lua(probe))
      -- <leader>c1 goes to the prompt, unpins and follows the agent in slot 1.
      keys("<leader>c1")
      wait_where({ win = "input", mode = "n" }, "<leader>c1 from the code window")
      wait(3000, [[return require("anvim.follow").focus == "s1"]], "<leader>c1 took no focus")
      assert.are.same({ focus = "s1", mode = "follow", sel = false }, lua(probe))
      -- The focus redraws the footer, which colors the status with the agent's color.
      wait_footer({ "◉ ", "Agent 1" }, "the footer after the focus")
      local out = footer("Agent 1")
      local colors = lua(
        [[
        local function fg(name)
          return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
        end
        return { got = fg(...), want = fg("AnvimAgent1"), claude = fg("AnvimClaude") }
      ]],
        out.group
      )
      assert.are.same("AnvimAgent1", out.group, out.text)
      assert.are.same(colors.want, colors.got)
      assert.are_not.same(colors.claude, colors.got)
      assert(not statusline():find("Agent 1", 1, true), statusline())
      keys("<leader>ca")
      wait(
        3000,
        [[
        local picker = Snacks.picker.get({ source = "anvim_overview" })[1]
        return picker ~= nil and #picker:items() == 3 and picker.list.win:win_valid()
      ]],
        "<leader>ca opened no Overview"
      )
      local title = lua([[
        local picker = Snacks.picker.get({ source = "anvim_overview" })[1]
        local chunks = vim.api.nvim_win_get_config(picker.layout.root.win).title
        return vim.trim(table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, chunks)))
      ]])
      assert.are.same("Agent Overview", title)
      -- The Overview has no input. 2 selects the agent in slot 2.
      keys("2")
      wait(
        3000,
        [[
        local picker = Snacks.picker.get({ source = "anvim_overview" })[1]
        local item = picker and picker:current()
        return item ~= nil and item.agent_id == "s2"
      ]],
        "2 did not select Explore 2"
      )
      keys("<CR>")
      wait_where({ win = "input", mode = "n" }, "<CR> in the Overview")
      wait(3000, [[return require("anvim.follow").focus == "s2"]], "the Overview took no focus")
      out = lua([[
        local win = require("anvim.layout").wins.code
        return { name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), line = vim.api.nvim_win_get_cursor(win)[1] }
      ]])
      assert.are.same({ name = file, line = 30 }, out)
      wait_footer({ "◉ ", "Explore 2" }, "the footer after the Overview")
      -- <leader>c0 does the same for Claude, the main agent.
      lua([[vim.api.nvim_set_current_win(require("anvim.layout").wins.code)]])
      keys("5GVj<Esc>")
      wait(2000, [[return require("anvim.context").selection() ~= nil]], "Vj<Esc> pinned nothing")
      keys("<leader>c0")
      wait_where({ win = "input", mode = "n" }, "<leader>c0 from the code window")
      wait(3000, [[return require("anvim.follow").focus == nil]], "<leader>c0 kept the focus")
      assert.are.same({ focus = false, mode = "follow", sel = false }, lua(probe))
    end)
    lua([[
      vim.notify = _G.notify or vim.notify
      require("anvim.agents").clear()
      require("anvim.layout").focus_input({ insert = false })
    ]])
    assert(ok, err)
    wait_footer({ "◉ following" }, "the footer after the agents")
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
    -- The session started in default mode, so bypass shows. The model goes
    -- first, to leave room for the follow status.
    assert(out.footer:find("^ anvim   ⧉ In [%w._-]+ +◉ following  ⏵⏵ bypass permissions on $"), out.footer)
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

  it("follows each colorscheme in the Claude column, AnvimDelete and AnvimTodoDone, also after a repair", function()
    start()
    -- The background that each part draws with, through its window's 'winhighlight'.
    local function backgrounds()
      return lua([[
        local wins = require("anvim.layout").wins
        local function bg(win, from)
          local to = from
          for pair in vim.wo[win].winhighlight:gmatch("[^,]+") do
            local key, group = pair:match("^(.-):(.*)$")
            to = key == from and group or to
          end
          -- nvim_get_hl() resolves a group through the current window's
          -- 'winhighlight' too, as for Normal in the prompt.
          local hl = vim.api.nvim_win_call(win, function()
            return vim.api.nvim_get_hl(0, { name = to, link = false })
          end)
          return { bg = hl.bg or -1, fg = hl.fg or -1 }
        end
        local tree
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_picker_list" then
            tree = bg(win, "NormalFloat").bg
          end
        end
        local sep = bg(wins.transcript, "WinSeparator")
        return {
          tree = tree,
          code = bg(wins.code, "Normal").bg,
          column = {
            transcript = bg(wins.transcript, "Normal").bg,
            transcript_nc = bg(wins.transcript, "NormalNC").bg,
            prompt = bg(wins.input, "Normal").bg,
            prompt_nc = bg(wins.input, "NormalNC").bg,
            winbar = bg(wins.input, "WinBar").bg,
            winbar_nc = bg(wins.input, "WinBarNC").bg,
            separator = sep.bg,
          },
          separator_fg = sep.fg,
          global_separator_fg = vim.api.nvim_get_hl(0, { name = "WinSeparator", link = false }).fg or -1,
        }
      ]])
    end
    local function assert_column(what)
      local got = backgrounds()
      assert(got.tree, what .. ": no explorer list")
      assert.are_not.same(got.code, got.tree, what .. ": the colorscheme gives the tree its own background")
      for part, bg in pairs(got.column) do
        assert.are.same(got.tree, bg, ("%s: the %s has the tree's background"):format(what, part))
      end
      assert.are.same(got.global_separator_fg, got.separator_fg, what .. ": the row under the transcript")
      return got
    end
    -- tokyonight's first load does no :hi clear.
    local function assert_derived(what)
      local got = lua([[
        local function get(name)
          return vim.api.nvim_get_hl(0, { name = name, link = false })
        end
        return {
          done = get("AnvimTodoDone").fg,
          comment = get("Comment").fg,
          delete = get("AnvimDelete").bg,
          diff_delete = get("DiffDelete").bg,
        }
      ]])
      assert(got.comment and got.diff_delete, what .. ": the colorscheme sets Comment and DiffDelete")
      assert.are.same(got.comment, got.done, what .. ": AnvimTodoDone has the Comment color")
      assert.are.same(got.diff_delete, got.delete, what .. ": AnvimDelete has the DiffDelete background")
    end
    local tokyonight = assert_column("tokyonight")
    assert_derived("tokyonight")
    lua([[vim.cmd.colorscheme("habamax")]])
    local habamax = assert_column("habamax")
    assert_derived("habamax")
    assert.are_not.same(tokyonight.tree, habamax.tree)
    lua([[vim.cmd.colorscheme("tokyonight")]])
    assert.are.same(tokyonight, assert_column("tokyonight again"))
    assert_derived("tokyonight again")
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_win_close(require("anvim.layout").wins.transcript, true)
      vim.api.nvim_win_close(require("anvim.layout").wins.input, true)
    ]])
    assert_layout("closing the Claude column")
    assert.are.same(tokyonight, assert_column("the repaired Claude column"))
    lua([[require("anvim.layout").focus_input({ insert = false })]])
  end)

  it("draws its own statusline in tokyonight's lualine colors and in habamax's, without errors", function()
    start()
    local function look()
      return lua(
        [[
        local file = ...
        local layout = require("anvim.layout")
        local function get(name)
          return vim.api.nvim_get_hl(0, { name = name, link = false })
        end
        local function eval(win)
          local stl = vim.api.nvim_eval_statusline(vim.go.statusline, { winid = win, highlights = true })
          local hl = get(stl.highlights[1].group)
          return { text = stl.str, group = stl.highlights[1].group, fg = hl.fg, bg = hl.bg }
        end
        local locals = {}
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          locals[#locals + 1] = vim.wo[win][0].statusline ~= "" and vim.wo[win][0].statusline or nil
        end
        vim.cmd.stopinsert()
        vim.api.nvim_set_current_win(layout.wins.code)
        vim.cmd.edit(file)
        vim.b.gitsigns_status_dict = { added = 2, changed = 1, removed = 1 }
        local code = eval(layout.wins.code)
        -- Each group that the statusline made from another has that group's color.
        local made = {}
        local stl = vim.api.nvim_eval_statusline(vim.go.statusline, { winid = layout.wins.code, highlights = true })
        for _, h in ipairs(stl.highlights) do
          local from = h.group:match("^AnvimStatusC(%u.*)$")
          if from then
            local want = get(from)
            made[from] = get(h.group).fg == (want.fg or want.sp)
          end
        end
        vim.b.gitsigns_status_dict = nil
        layout.focus_input({ insert = false })
        return {
          option = vim.go.statusline,
          locals = locals,
          prompt = eval(layout.wins.input),
          code = code,
          claude = get("AnvimClaude").fg,
          pmenu = get("PmenuSel").bg,
          error = require("anvim.statusline").error or vim.NIL,
          made = made,
        }
      ]],
        helpers.tmp .. "/matchparen.lua"
      )
    end
    local function check(what)
      local got = look()
      assert.are.same("%!v:lua.require'anvim.statusline'.render()", got.option, what)
      assert.are.same({}, got.locals, what .. ": a window has a statusline of its own")
      assert.are.same(vim.NIL, got.error, what)
      assert(got.prompt.text:find("^ FOLLOW "), what .. ": " .. got.prompt.text)
      assert(got.code.text:find("^ NORMAL "), what .. ": " .. got.code.text)
      assert.are.same({ "AnvimStatusFollow", got.claude }, { got.prompt.group, got.prompt.bg }, what)
      assert.are.same("AnvimStatusNormal", got.code.group, what)
      for _, group in ipairs({ "GitSignsAdd", "GitSignsChange", "GitSignsDelete", "MiniIconsAzure" }) do
        assert.are.same(true, got.made[group], ("%s: the color of %s in %s"):format(what, group, vim.inspect(got.made)))
      end
      for group, same in pairs(got.made) do
        assert(same, ("%s: the color of %s"):format(what, group))
      end
      for _, part in ipairs({ got.prompt, got.code }) do
        assert(part.fg and part.bg and part.fg ~= part.bg, what .. ": " .. vim.inspect(part))
      end
      return got
    end
    local blue = lua([[return tonumber(require("lualine.themes._tokyonight").get().normal.a.bg:sub(2), 16)]])
    local tokyonight = check("tokyonight")
    assert.are.same(blue, tokyonight.code.bg, "tokyonight's lualine theme colors the mode")
    lua([[vim.cmd.colorscheme("habamax")]])
    local habamax = check("habamax")
    assert.are.same(habamax.pmenu, habamax.code.bg, "habamax's PmenuSel colors the mode")
    lua([[vim.cmd.colorscheme("tokyonight")]])
    assert.are.same(tokyonight, check("tokyonight again"))
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
      for _, key in ipairs(layout.insert_keys) do
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
    assert.are.same({ i = talk, a = talk, I = talk, A = talk, o = talk, O = talk }, out.maps)
    assert.are.same(stat.mtime, vim.uv.fs_stat(file).mtime, "the file was written")
  end)

  it("wraps markdown in the code window without spell checking, and no window checks spelling", function()
    start()
    local file = helpers.tmp .. "/notes.md"
    vim.fn.writefile({ "# Notes", "", "Some txet with a typo." }, file)
    local out = lua(
      [[
      local layout = require("anvim.layout")
      local code = layout.code_win()
      local before = vim.api.nvim_win_get_buf(code)
      vim.api.nvim_set_current_win(code)
      vim.cmd.edit(...)
      local out = { ft = vim.bo.filetype, wrap = vim.wo.wrap }
      for role, win in pairs(layout.wins) do
        out[role] = vim.wo[win].spell
      end
      -- The next cases expect the file that the code window showed.
      local notes = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(code, before)
      vim.api.nvim_buf_delete(notes, { force = true })
      layout.focus_input({ insert = false })
      return out
    ]],
      file
    )
    assert.are.same({ ft = "markdown", wrap = true, code = false, input = false, transcript = false }, out)
  end)

  it("turns a buffer's diagnostics off while a preview runs", function()
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
        return { diagnostics = vim.diagnostic.is_enabled({ bufnr = buf }) }
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
    assert.are.same({ diagnostics = false }, out.during)
    assert.are.same({ diagnostics = true }, out.after)
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
    keys("<C-Space>")
    menu_first("<C-Space> opened no menu")
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return vim.api.nvim_get_current_line():find("^matchparen") ~= nil]], "the item was not accepted")
    local word = lua([[return vim.api.nvim_get_current_line()]])
    assert.are.same({}, lua([[return _G.sent]]), "the prompt was sent")
    assert.are.same(0, lua([[return vim.fn.pumvisible()]]), "the menu stayed open")
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
    assert.are.same("/compact ", menu_first("no menu after /compa").word)
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return #_G.sent > 0]], "Enter on /compact did not send it")
    sent = lua([[return _G.sent]])
    assert.are.same({ "prompt", "/compact" }, { sent[1].type, sent[1].text })
    wait(2000, [[return vim.api.nvim_get_current_line() == "" and vim.fn.pumvisible() == 0]])
    lua([[
      require("anvim.input").set_busy(false)
      vim.api.nvim_input("/bat")
    ]])
    assert.are.same("/batch ", menu_first("no menu after /bat").word)
    lua([[vim.api.nvim_input("<CR>")]])
    wait(2000, [[return vim.api.nvim_get_current_line() == "/batch "]], "Enter did not complete /batch")
    lua([[vim.wait(300)]])
    assert.are.same(1, #lua([[return _G.sent]]), "Enter sent /batch, which needs an argument")
    lua([[
      require("anvim.sidecar").send = _G.send
      vim.cmd.stopinsert()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      require("anvim.input").set_busy(false)
    ]])
  end)

  it("<Up> moves in the completion menu while it is open, and goes back through past prompts otherwise", function()
    start()
    lua([[
      local sidecar = require("anvim.sidecar")
      local input = require("anvim.input")
      _G.send = sidecar.send
      sidecar.send = function() end
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.input)
      for _, text in ipairs({ "first past prompt", "second past matchpar" }) do
        vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { text })
        input.submit()
      end
      input.set_busy(false)
      vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "matchpar" })
    ]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "n"]])
    lua([[vim.api.nvim_input("A")]])
    wait(2000, [[return vim.api.nvim_get_mode().mode == "i"]], "not in insert mode")
    keys("<C-Space>")
    menu_first("<C-Space> opened no menu")
    -- Past the first item, <Up> highlights none, and the next <Up> the last one.
    lua([[vim.api.nvim_input("<Up>")]])
    wait(
      2000,
      [[return vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected == -1]],
      "<Up> did not move"
    )
    lua([[vim.api.nvim_input("<Up>")]])
    wait(2000, [[return vim.fn.complete_info({ "selected" }).selected > 0]], "<Up> did not go to the last item")
    local line = lua([[return vim.api.nvim_get_current_line()]])
    assert.are.same("matchpar", line, "<Up> went to a past prompt while the menu was open")
    hide_menu()
    lua([[
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my draft" })
      vim.api.nvim_input("<Up>")
    ]])
    wait(2000, [[return vim.api.nvim_get_current_line() == "second past matchpar"]], "<Up> did not go back")
    -- A past prompt is no typing, so it opens no menu, though it ends in a
    -- word that the code window completes.
    assert.are.same(0, lua([[return vim.fn.pumvisible()]]), "the past prompt opened the menu")
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
    -- A typed <Esc> in the code window unpins, also through anvim's <Esc> map.
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    vim.wait(200)
    assert.are.same({ 5, 6, "char" }, probe().sel, "going back to the code window dropped the pin")
    assert.are.same("Clear the search highlight", lua([[return vim.fn.maparg("<Esc>", "n", false, true).desc]]))
    keys("<Esc>")
    wait(2000, [[return require("anvim.context").selection() == nil]], "<Esc> kept the pin")
    lua([[require("anvim.layout").focus_input({ insert = false })]])
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
      hide_menu()
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
    wait_footer({ "⏸ ", "pin_other.lua:1 +1" }, "the footer with a pin")
    local sent = ask()
    assert.are.same({ 10, 11 }, { sent.context.selection.start_line, sent.context.selection.end_line })
    wait(
      2000,
      ([[return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)) == %q]]):format(
        other
      ),
      "follow mode did not catch up after the prompt"
    )
    wait_footer({ "◉ following" }, "the footer after the prompt")

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
    -- `c` starts the operator at once. which-key does not make it wait for
    -- more keys.
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
    local first = menu_first("the menu did not open")
    assert.are.same({ "matchparen.lua", "@matchparen.lua " }, { first.abbr, first.word })
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
      assert.are.same("matchparen.lua", menu_first("no menu after @").abbr, "matchparen.lua is not the first item")
      keys("<CR>")
      wait(2000, [[return vim.api.nvim_get_current_line() == "see @matchparen.lua "]], "Enter did not accept the file")
      keys("<Esc>ggO/compa")
      assert.are.same("/compact", menu_first("no menu after /compa").abbr, "/compact is not the first item")
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

  it("opens Claude's trail with <leader>ct, newest first, and <CR> goes there", function()
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
    keys("<leader>ct")
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

  it("goes to the explorer with <leader>e, which never closes it, and the explorer changes no files", function()
    start()
    lua([[
      require("anvim.layout").focus_input()
      vim.cmd.stopinsert()
    ]])
    for _, from in ipairs({ "the prompt", "the explorer" }) do
      keys("<leader>e")
      wait_where({ win = "snacks_picker_list", mode = "n" }, "<leader>e from " .. from)
      vim.wait(200)
      assert(lua([[return Snacks.picker.get({ source = "explorer" })[1] ~= nil]]), "<leader>e closed the explorer")
      -- The list is a float on the explorer's split, not on top of the prompt.
      assert.are.same("review", lua([[return require("anvim.follow").mode()]]), "the explorer from " .. from)
    end
    local maps = lua([[
      local maps = {}
      for _, key in ipairs({ "a", "d", "r", "c", "m", "p", "<C-c>" }) do
        maps[key] = vim.fn.maparg(key, "n")
      end
      return maps
    ]])
    assert.are.same({ a = "", d = "", r = "", c = "", m = "", p = "", ["<C-c>"] = "" }, maps)
    keys("<C-l>")
    wait_where({ win = "code", mode = "n" }, "<C-l> from the tree")
    lua([[require("anvim.layout").focus_input({ insert = false })]])
  end)

  it("names each which-key group under <leader>, with an icon", function()
    start()
    local out = lua([[
      local icons = require("which-key.icons")
      local groups = {}
      for _, m in ipairs(require("which-key.config").mappings) do
        if m.group and m.mode == "n" and m.lhs:find("^<leader>") then
          local icon = m.icon and icons.get(m.icon) or icons.get({ desc = m.desc })
          groups[m.lhs] = { m.desc, icon ~= nil }
        end
      end
      -- Each prefix of a <leader> key in the key view is a group.
      local keys, prefixes = require("anvim.keys"), {}
      for _, place in ipairs(keys.places) do
        for _, key in ipairs(place.keys) do
          for _, lhs in ipairs(keys.lhs(key)) do
            local rest, path = lhs:match("^<leader>(.+)"), "<leader>"
            local parts, i = {}, 1
            while rest and i <= #rest do
              parts[#parts + 1] = rest:match("^<[^>]+>", i) or rest:sub(i, i)
              i = i + #parts[#parts]
            end
            for p = 1, #parts - 1 do
              path = path .. parts[p]
              prefixes[path] = true
            end
          end
        end
      end
      return { groups = groups, prefixes = vim.tbl_keys(prefixes) }
    ]])
    assert.are.same({
      ["<leader>f"] = { "file/find", true },
      ["<leader>g"] = { "git", true },
      ["<leader>gh"] = { "hunks", true },
      ["<leader>c"] = { "claude", true },
      ["<leader>s"] = { "search", true },
      ["<leader>u"] = { "ui", true },
    }, out.groups)
    local names = vim.tbl_keys(out.groups)
    table.sort(names)
    table.sort(out.prefixes)
    assert.are.same(names, out.prefixes)
  end)

  it("lists each key that anvim maps in the key view, and no key that does not exist", function()
    start()
    -- Neovim's own global maps, as a clean Neovim has them.
    local script = helpers.tmp .. "/neovim_maps.lua"
    vim.fn.writefile({
      "local ret = {}",
      'for _, mode in ipairs({ "n", "x", "o", "i" }) do',
      "  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do",
      "    ret[#ret + 1] = { mode, m.lhs }",
      "  end",
      "end",
      "io.stdout:write(vim.json.encode(ret))",
    }, script)
    local clean = vim.json.decode(vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script }):wait().stdout)
    -- Each snapshot holds every live map of one buffer, or the global ones.
    lua([[
      local snaps = {}
      package.loaded["anvim_test_snaps"] = snaps
      package.loaded["anvim_test_snap"] = function(name, ctx, buf)
        local maps = {}
        for _, mode in ipairs({ "n", "x", "o", "i" }) do
          for _, m in ipairs(buf and vim.api.nvim_buf_get_keymap(buf, mode) or vim.api.nvim_get_keymap(mode)) do
            if not m.lhs:find("^<Plug>") and not m.lhs:find("^<SNR>") then
              local src = m.callback and debug.getinfo(m.callback, "S").source or ""
              maps[#maps + 1] = { mode = mode, lhs = m.lhs, desc = m.desc or "", src = src }
            end
          end
        end
        snaps[name] = { ctx = ctx, maps = maps }
      end
    ]])
    local function snap(name, ctx, buf_code)
      lua(([[package.loaded["anvim_test_snap"](%q, %q, %s)]]):format(name, ctx, buf_code or "nil"))
    end
    wait(5000, [[return #vim.lsp.get_clients({ name = "lua_ls" }) > 0]], "lua_ls did not start")
    snap("lsp", "file", [[next(vim.lsp.get_clients({ name = "lua_ls" })[1].attached_buffers)]])
    -- The hunk keys exist for files that git tracks.
    local repo = helpers.tmp .. "/keys-repo"
    vim.fn.mkdir(repo, "p")
    vim.fn.writefile({ "one" }, repo .. "/notes.txt")
    vim.fn.system({ "git", "-C", repo, "init", "-q" })
    vim.fn.system({ "git", "-C", repo, "add", "notes.txt" })
    lua(
      [[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
      vim.cmd.edit(...)
    ]],
      repo .. "/notes.txt"
    )
    wait(5000, [[return vim.fn.maparg("]h", "n", false, true).buffer == 1]], "gitsigns did not attach")
    snap("git", "file", "vim.api.nvim_get_current_buf()")
    lua([[vim.cmd.help("help")]])
    wait(3000, [[return vim.bo.buftype == "help" and vim.fn.maparg("q", "n", false, true).buffer == 1]], "no q in help")
    snap("help", "other", "vim.api.nvim_get_current_buf()")
    lua([[
      vim.cmd.helpclose()
      vim.fn.setqflist({ { filename = "notes.txt", lnum = 1, text = "one" } })
      vim.cmd.copen()
    ]])
    wait(
      3000,
      [[return vim.bo.buftype == "quickfix" and vim.fn.maparg("q", "n", false, true).buffer == 1]],
      "no q in qf"
    )
    snap("qf", "other", "vim.api.nvim_get_current_buf()")
    lua([[
      vim.cmd.cclose()
      require("anvim.layout").focus_input({ insert = false })
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    wait_where({ win = "input", mode = "n" }, "the prompt")
    keys("<C-g>")
    wait_where({ win = "anvim_input", mode = "n" }, "<C-g> in the prompt")
    snap("compose", "compose", "vim.api.nvim_get_current_buf()")
    keys("<C-g>")
    wait_where({ win = "input", mode = "n" }, "<C-g> in the compose window")
    -- The Agent Overview's tabs, and an agent's log.
    lua([[
      require("anvim.sidecar").dispatch({
        type = "agent_start",
        agent_id = "keys_a1",
        tool_use_id = "tu_keys_a1",
        description = "Keys",
        subagent_type = "general-purpose",
        depth = 1,
        background = false,
      })
      require("anvim.overview").open()
    ]])
    wait(
      3000,
      [[local p = require("anvim.overview").get() return p ~= nil and p.list.win:win_valid()]],
      "the Overview did not open"
    )
    snap("overview", "overview", [[require("anvim.overview").get().list.win.buf]])
    snap("agentlog", "agentlog", [[require("anvim.agentlog").buf("keys_a1")]])
    lua([[
      require("anvim.overview").close()
      require("anvim.agents").clear()
    ]])
    wait_where({ win = "input", mode = "n" }, "closing the Overview")
    local problems = lua(
      [[
      local clean = ...
      local keys = require("anvim.keys")
      local layout = require("anvim.layout")
      local sidecar = require("anvim.sidecar")
      local snaps, snap = package.loaded["anvim_test_snaps"], package.loaded["anvim_test_snap"]
      local prompt = require("anvim.input").buf()
      snap("global", "global")
      snap("transcript", "transcript", require("anvim.transcript").buf())
      snap("explorer", "explorer", Snacks.picker.get({ source = "explorer" })[1].list.win.buf)
      require("anvim.keyview").open()
      snap("view", "view", vim.api.nvim_get_current_buf())
      require("anvim.keyview").close()
      -- The prompt has the choice keys while a request waits.
      local req = { command = "make keys" }
      sidecar.dispatch({ type = "tool_start", id = "keys1", name = "Bash" })
      sidecar.dispatch({ type = "tool_use", id = "keys1", name = "Bash", input = req })
      sidecar.dispatch({ type = "permission_request", req = 901, tool_use_id = "keys1", tool = "Bash", input = req })
      snap("prompt", "prompt", prompt)
      sidecar.dispatch({ type = "permission_cancel", req = 901 })
      sidecar.dispatch({ type = "tool_result", id = "keys1", is_error = true, text = "cancelled" })

      local function index(maps)
        local ret = {}
        for _, m in ipairs(maps) do
          ret[m.mode .. " " .. vim.keycode(m.lhs)] = m.desc
        end
        return ret
      end
      local found = {}
      for name, s in pairs(snaps) do
        found[name] = index(s.maps)
      end
      local problems = {}
      -- Each key of the view exists, and anvim's own maps have its description.
      for _, place in ipairs(keys.places) do
        for _, key in ipairs(place.keys) do
          local ctx = key.ctx or place.ctx
          local names = ({
            file = { key.when == "git" and "git" or "lsp" },
            other = { "help", "qf" },
          })[ctx] or { ctx }
          for _, lhs in ipairs(key.static and {} or keys.lhs(key)) do
            for _, mode in ipairs(keys.modes(key)) do
              local id, desc = mode .. " " .. vim.keycode(lhs), nil
              for _, name in ipairs(names) do
                desc = desc or found[name][id]
              end
              if desc == nil then
                problems[#problems + 1] = ("%s: no %s map %s"):format(place.id, mode, lhs)
              elseif not key.default and desc ~= key[2] then
                problems[#problems + 1] = ("%s: %s %s says %q"):format(place.id, mode, lhs, desc)
              end
            end
          end
        end
      end

      -- Each live map is in the view, in the place where it lives, or it is
      -- one of these.
      local neovim = {}
      for _, m in ipairs(clean) do
        neovim[m[1] .. " " .. vim.keycode(m[2])] = true
      end
      local snacks = require("lazy.core.config").plugins["snacks.nvim"]
      local explorer_keys = require("lazy.core.plugin").values(snacks, "opts", false).picker.sources.explorer.win.list.keys
      local ours = {}
      for lhs in pairs(explorer_keys) do
        ours[vim.keycode(lhs)] = true
      end
      local overview_keys = require("anvim.overview").keys
      local ours_overview = {}
      for lhs in pairs(overview_keys) do
        ours_overview[vim.keycode(lhs)] = true
      end
      local function listed(ctx, mode, lhs)
        for _, place in ipairs(keys.places) do
          for _, key in ipairs(place.keys) do
            if not key.static and (key.ctx or place.ctx) == ctx and vim.tbl_contains(keys.modes(key), mode) then
              for _, l in ipairs(keys.lhs(key)) do
                if vim.keycode(l) == vim.keycode(lhs) then
                  return true
                end
              end
            end
          end
        end
      end
      -- The compose window has the prompt's completion, and its map.
      local function shared(ctx, m)
        return ctx == "compose" and m.src:find("/lua/anvim/completion%.lua$") ~= nil and listed("prompt", m.mode, m.lhs)
      end
      local function allowed(ctx, m)
        local id = m.mode .. " " .. vim.keycode(m.lhs)
        if listed(ctx, m.mode, m.lhs) then
          return true
        elseif m.desc:find("^which%-key%-trigger") then
          return true
        elseif ctx == "global" and neovim[id] then
          return true
        elseif m.src:find("^@vim/") or m.src:find(vim.env.VIMRUNTIME, 1, true) then
          -- Neovim's own buffer maps, such as K from LSP and the help ftplugin's.
          return true
        elseif ctx == "explorer" and not ours[vim.keycode(m.lhs)] then
          -- The explorer's own keys, which its ? lists.
          return true
        elseif ctx == "overview" and not ours_overview[vim.keycode(m.lhs)] then
          -- snacks' own picker keys, which its ? lists.
          return true
        elseif shared(ctx, m) then
          return true
        end
        return false
      end
      for name, s in pairs(snaps) do
        for _, m in ipairs(s.maps) do
          if not allowed(s.ctx, m) then
            problems[#problems + 1] = ("%s has %s map %s (%s) that the view leaves out"):format(name, m.mode, m.lhs, m.desc)
          end
        end
      end

      -- Each map that anvim's code made is in the view, in the place where it lives.
      local seen = {}
      for _, m in ipairs(require("anvim_test_maps")) do
        seen[m.ctx] = true
        if not listed(m.ctx, m.mode, m.lhs) and not shared(m.ctx, m) then
          problems[#problems + 1] = ("%s map %s in %s from %s is not in the view"):format(m.mode, m.lhs, m.ctx, m.src)
        end
      end
      for _, ctx in ipairs({ "global", "file", "prompt", "transcript", "compose", "agentlog", "view", "other" }) do
        if not seen[ctx] then
          problems[#problems + 1] = "no map was recorded in " .. ctx
        end
      end
      -- snacks maps the explorer's keys from anvim's spec.
      for lhs, spec in pairs(explorer_keys) do
        local key = spec and keys.find("explorer", spec.mode or "n", lhs)
        if spec and not (key and key[2] == spec.desc) then
          problems[#problems + 1] = ("the explorer's %s is not in the view"):format(lhs)
        end
      end
      -- snacks maps the Overview's keys from overview.keys.
      for lhs, spec in pairs(overview_keys) do
        local key = spec and keys.find("overview", spec.mode or "n", lhs)
        if spec and not (key and key[2] == spec.desc) then
          problems[#problems + 1] = ("the Overview's %s is not in the view"):format(lhs)
        end
      end
      return problems
    ]],
      clean
    )
    assert.are.same({}, problems)
  end)

  it("opens the key view with <leader>? and ? in the prompt, and closing it gives the window and mode back", function()
    start()
    local function opened(what)
      wait(3000, [[return require("anvim.keyview").win() == vim.api.nvim_get_current_win()]], what .. " opened no view")
      assert.are.same("n", lua([[return vim.api.nvim_get_mode().mode]]), what .. " left the view in insert mode")
    end
    lua([[
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").wins.code)
    ]])
    keys("<leader>?")
    opened("<leader>? in the code window")
    keys("q")
    wait_where({ win = "code", mode = "n" }, "q in the key view")
    -- A file buffer maps c for references, and <leader>c still reaches Claude's keys.
    keys("<leader>cr")
    wait_where({ win = "transcript", mode = "n" }, "<leader>cr in a file buffer")
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from read mode")
    lua([[Snacks.picker.get({ source = "explorer" })[1]:focus("list")]])
    wait_where({ win = "snacks_picker_list", mode = "n" }, "the tree has the cursor")
    keys("<leader>?")
    opened("<leader>? in the explorer")
    keys("<Esc>")
    wait_where({ win = "snacks_picker_list", mode = "n" }, "<Esc> in the key view")
    lua([[
      require("anvim.layout").focus_input({ insert = false })
      vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })
    ]])
    wait_where({ win = "input", mode = "n" }, "the prompt")
    keys("?")
    opened("? in the prompt in normal mode")
    keys("q")
    wait_where({ win = "input", mode = "n" }, "q after ? in normal mode")
    keys("i")
    wait_where({ win = "input", mode = "i" }, "i in the prompt")
    keys("?")
    opened("? in the empty prompt in insert mode")
    keys("q")
    wait_where({ win = "input", mode = "i" }, "q after ? in insert mode")
    keys("why?")
    wait(2000, [[return vim.api.nvim_get_current_line() == "why?"]], "? in a prompt with text typed no ?")
    assert.are.same({ win = "input", mode = "i" }, where())
    assert(lua([[return require("anvim.keyview").win() == nil]]), "? in a prompt with text opened the view")
    keys("<Esc>")
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })]])
  end)

  it("gives back read mode, the compose window and <C-w>p after the key view, and insert mode after :q", function()
    start()
    local function opened(what)
      wait(3000, [[return require("anvim.keyview").win() == vim.api.nvim_get_current_win()]], what .. " opened no view")
    end
    local function view()
      return lua([[
        local v = vim.fn.winsaveview()
        return { lnum = v.lnum, topline = v.topline, read = vim.w.anvim_read == true }
      ]])
    end
    -- Read mode comes back with its cursor and its view. snacks.scroll would
    -- animate the moves.
    lua([[
      vim.cmd.stopinsert()
      local transcript = require("anvim.transcript")
      vim.b[transcript.buf()].snacks_scroll = false
      for i = 1, 60 do
        transcript.notice("info", "a line to scroll " .. i)
      end
      require("anvim.layout").focus_input({ insert = false })
    ]])
    keys("<leader>cr")
    wait_where({ win = "transcript", mode = "n" }, "<leader>cr")
    lua([[vim.fn.winrestview({ lnum = 12, topline = 9 })]])
    local reading = view()
    assert.are.same({ lnum = 12, topline = 9, read = true }, reading)
    keys("<leader>?")
    opened("<leader>? in read mode")
    keys("q")
    wait_where({ win = "transcript", mode = "n" }, "q after <leader>? in read mode")
    assert.are.same(reading, view())
    keys("q")
    wait_where({ win = "input", mode = "n" }, "q in read mode")
    -- New output keeps the transcript at its end only when it is there.
    lua([[
      local transcript = require("anvim.transcript")
      vim.api.nvim_win_call(require("anvim.layout").wins.transcript, function()
        vim.cmd("normal! G")
      end)
      vim.b[transcript.buf()].snacks_scroll = nil
    ]])

    -- The compose window stays open under the view, with its text.
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "a draft" })]])
    keys("<C-g>")
    wait_where({ win = "anvim_input", mode = "n" }, "<C-g> in the prompt")
    keys("<leader>?")
    opened("<leader>? in the compose window")
    -- Leaving the compose window would close it from the event loop.
    vim.wait(200)
    local compose = lua([[
      local win = require("anvim.compose").win()
      return win and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false) or false
    ]])
    assert.are.same({ "a draft" }, compose, "the compose window closed under the view")
    keys("q")
    wait(
      3000,
      [[return require("anvim.compose").win() == vim.api.nvim_get_current_win()]],
      "q did not go back to the compose window"
    )
    keys("<C-g>")
    wait_where({ win = "input", mode = "n" }, "<C-g> in the compose window")
    lua([[vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "" })]])

    -- <C-w>p goes to the window from before the view.
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    keys("<C-l>")
    wait_where({ win = "input", mode = "n" }, "<C-l> from the code window")
    keys("?")
    opened("? in the prompt")
    keys("q")
    wait_where({ win = "input", mode = "n" }, "q in the key view")
    keys("<C-w>p")
    wait_where({ win = "code", mode = "n" }, "<C-w>p after the key view")

    -- :q closes the view too, and gives back insert mode.
    lua([[require("anvim.layout").focus_input({ insert = false })]])
    wait_where({ win = "input", mode = "n" }, "the prompt")
    keys("i")
    wait_where({ win = "input", mode = "i" }, "i in the prompt")
    keys("?")
    opened("? in the empty prompt")
    keys(":q<CR>")
    wait_where({ win = "input", mode = "i" }, ":q in the key view")
    keys("<Esc>")
    wait_where({ win = "input", mode = "n" }, "<Esc> in the prompt")
  end)

  it("deletes Neovim's keys that only change text, keeps the ones that read, and maps <leader>cR", function()
    start()
    local out = lua([[
      local function has(mode, lhs)
        return vim.fn.maparg(lhs, mode) ~= ""
      end
      local ret = { gone = {}, kept = {} }
      for _, k in ipairs({ "n gc", "x gc", "n gcc", "n [<Space>", "n ]<Space>", "n &" }) do
        ret.gone[k] = has(k:sub(1, 1), k:sub(3))
      end
      for _, k in ipairs({ "o gc", "n ]d", "n [d", "n gO", "n gx", "n Y", "i <C-S>", "n <C-W>d" }) do
        ret.kept[k] = has(k:sub(1, 1), k:sub(3))
      end
      ret.restart = vim.fn.maparg("<leader>cR", "n", false, true).desc
      return ret
    ]])
    assert.are.same({
      ["n gc"] = false,
      ["x gc"] = false,
      ["n gcc"] = false,
      ["n [<Space>"] = false,
      ["n ]<Space>"] = false,
      ["n &"] = false,
    }, out.gone)
    assert.are.same({
      ["o gc"] = true,
      ["n ]d"] = true,
      ["n [d"] = true,
      ["n gO"] = true,
      ["n gx"] = true,
      ["n Y"] = true,
      ["i <C-S>"] = true,
      ["n <C-W>d"] = true,
    }, out.kept)
    assert.are.same("Restart Claude", out.restart)
  end)

  it("maps the LSP keys in buffers with a server only, gr without a wait, and no LSP key that edits", function()
    start()
    local text = helpers.tmp .. "/plain.txt"
    vim.fn.writefile({ "No language server reads this." }, text)
    wait(5000, [[return #vim.lsp.get_clients({ name = "lua_ls" }) > 0]], "lua_ls did not start")
    local out = lua(
      [[
      local function maps(buf)
        return vim.api.nvim_buf_call(buf, function()
          local ret = { x = vim.fn.maparg("gra", "x") }
          for _, key in ipairs({ "grn", "gra", "grx", "grr", "gri", "grt" }) do
            ret[key] = vim.fn.maparg(key, "n")
          end
          for _, key in ipairs({ "gd", "gr", "gD" }) do
            local map = vim.fn.maparg(key, "n", false, true)
            ret[key] = map.buffer == 1 and { map.desc, map.nowait } or false
          end
          return ret
        end)
      end
      local with = next(vim.lsp.get_clients({ name = "lua_ls" })[1].attached_buffers)
      local without = vim.fn.bufadd(...)
      vim.fn.bufload(without)
      local ret = { with = maps(with), without = maps(without), clients = #vim.lsp.get_clients({ bufnr = without }) }
      vim.api.nvim_buf_delete(without, { force = true })
      return ret
    ]],
      text
    )
    local none = { grn = "", gra = "", grx = "", grr = "", gri = "", grt = "", x = "" }
    assert.are.same(0, out.clients, "a server attached to the text file")
    assert.are.same(
      vim.tbl_extend("force", none, {
        gd = { "Go to the definition", 0 },
        gr = { "Find the references", 1 },
        gD = { "Go to the declaration", 0 },
      }),
      out.with
    )
    assert.are.same(vim.tbl_extend("force", none, { gd = false, gr = false, gD = false }), out.without)
  end)

  it("keeps the git pickers read-only: Enter checks nothing out, and no key restores", function()
    start()
    local out = lua([[
      local get = Snacks.picker.config.get
      local ret = {}
      for _, source in ipairs({ "git_log", "git_log_file", "git_log_line" }) do
        ret[source] = get({ source = source }).confirm
      end
      for _, source in ipairs({ "git_status", "git_diff" }) do
        local keys = get({ source = source }).win.input.keys
        -- snacks writes the keys in this form.
        ret[source] = { restore = keys["<C-R>"], stage = keys["<Tab>"] and keys["<Tab>"][1] }
      end
      return ret
    ]])
    assert.are.same({
      git_log = "focus_preview",
      git_log_file = "focus_preview",
      git_log_line = "focus_preview",
      git_status = { restore = false, stage = "git_stage" },
      git_diff = { restore = false, stage = "git_stage" },
    }, out)
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

  it("folds splits from window keys, commands and pickers back into the code window", function()
    start()
    local file = helpers.tmp .. "/matchparen.lua"
    -- Keys fed from an RPC request can run after the next request, so a check
    -- could see the one code window from before the split. Each check first
    -- waits for a new window.
    lua([[
      _G.anvim_wins_made = 0
      vim.api.nvim_create_autocmd("WinNew", {
        group = vim.api.nvim_create_augroup("anvim.test.wins_made", { clear = true }),
        callback = function()
          _G.anvim_wins_made = _G.anvim_wins_made + 1
        end,
      })
    ]])
    local function made()
      return lua([[return _G.anvim_wins_made]])
    end
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
    local function assert_folded(what, wins_made, line)
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
            made = _G.anvim_wins_made,
            count = count,
            current = vim.api.nvim_get_current_win() == code,
            name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code)),
            line = vim.api.nvim_win_get_cursor(code)[1],
          }
        ]])
        return out.made > wins_made and out.count == 1 and out.current and out.name == file
      end, 20)
      assert(ok, what .. ": " .. vim.inspect(out))
      if line then
        assert.are.same(line, out.line, what)
      end
    end
    for _, key in ipairs({ "<C-w>v", "<C-w>s", ":vsplit<CR>", ":split<CR>" }) do
      in_code(file)
      local wins_made = made()
      keys(key)
      assert_folded(key, wins_made, 20)
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
    local wins_made = made()
    keys("<C-v>")
    assert_folded("the picker's vsplit", wins_made)
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

  it("enters and leaves read mode, with keys under <leader>c only", function()
    start()
    lua([[
      require("anvim.layout").focus_input()
      vim.cmd.stopinsert()
    ]])
    for _, key in ipairs({ "q", "<Esc>", "i", "A", "o" }) do
      keys("<leader>cr")
      wait_where({ win = "transcript", mode = "n" }, "<leader>cr")
      keys(key)
      local typing = key ~= "q" and key ~= "<Esc>"
      wait_where({ win = "input", mode = typing and "i" or "n" }, key .. " in read mode")
      keys("<Esc>")
      wait_where({ win = "input", mode = "n" }, "<Esc> in the prompt")
    end
    keys("<C-h><C-l><Esc><leader>cr")
    wait_where({ win = "transcript", mode = "n" }, "<leader>cr")
    keys("q<Esc><C-w>p")
    wait_where({ win = "code", mode = "n" }, "<C-w>p after read mode goes to the window before the prompt")
    keys("<leader>cr")
    wait_where({ win = "transcript", mode = "n" }, "<leader>cr")
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from read mode")
    keys("gg<C-l>")
    wait_where({ win = "input", mode = "n" }, "leaving the transcript ended read mode")
    keys("<Esc>")
    local out = lua([[
      local maps, old = {}, {}
      for _, mode in ipairs({ "n", "x" }) do
        for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
          if map.lhs:sub(1, 2) == vim.g.mapleader .. "c" then
            maps[mode .. " " .. map.lhs:sub(2)] = map.desc
          elseif map.lhs:sub(1, 2) == vim.g.mapleader .. "k" then
            old[#old + 1] = map.lhs
          end
        end
      end
      local groups = {}
      for _, m in ipairs(require("which-key.config").mappings) do
        if m.lhs == "<leader>c" then
          groups[#groups + 1] = { desc = m.desc, group = m.group }
        end
      end
      return { maps = maps, old = old, groups = groups }
    ]])
    assert.are.same({
      ["n c0"] = "Go to the prompt and follow Claude",
      ["n c1"] = "Go to the prompt and follow agent 1",
      ["n c2"] = "Go to the prompt and follow agent 2",
      ["n c3"] = "Go to the prompt and follow agent 3",
      ["n c4"] = "Go to the prompt and follow agent 4",
      ["n ca"] = "Open the Agent Overview",
      ["n cj"] = "Jump to where Claude or the focused agent is",
      ["n cm"] = "Choose the model",
      ["n cr"] = "Read the transcript",
      ["n cs"] = "Resume a session",
      ["n ct"] = "Pick a place from Claude's trail",
      ["n cy"] = "Yank Claude's last reply",
      ["n cR"] = "Restart Claude",
    }, out.maps)
    assert.are.same({}, out.old, "a key under <leader>k is left")
    assert.are.same({ { desc = "claude", group = true } }, out.groups)
  end)

  it("reopens a closed code window between the tree and the Claude column", function()
    start()
    for _, key in ipairs({ ":close<CR>", "<C-w>c" }) do
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

  it("shows a permission request in the statusline and the winbar, and answers it from the prompt", function()
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
    hide_menu()
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
    hide_menu()
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

  it("quits cleanly while the Agent Overview shows an agent's log", function()
    start()
    -- In a child of its own, because this one quits.
    local shared, errors, dir = chan, {}, helpers.tmp .. "/xdg-overview"
    local id = spawn(dir, nil, errors)
    local ok, err = pcall(function()
      lua([[
        local sidecar = require("anvim.sidecar")
        sidecar.dispatch({
          type = "agent_start",
          agent_id = "quit_a1",
          tool_use_id = "tu_quit_a1",
          description = "Quit",
          subagent_type = "Explore",
          depth = 1,
          background = false,
        })
        sidecar.dispatch({
          type = "tool_use",
          id = "quit_t1",
          name = "Bash",
          input = { command = "echo 1" },
          parent_id = "tu_quit_a1",
          agent_id = "quit_a1",
        })
        require("anvim.follow").set_focus("quit_a1")
        require("anvim.overview").open()
      ]])
      wait(
        3000,
        [[local p = require("anvim.overview").get() return p ~= nil and p.list.win:win_valid()]],
        "the Overview did not open"
      )
      keys("1")
      wait(
        3000,
        [[local p = require("anvim.overview").get()
          return vim.api.nvim_win_get_buf(p.preview.win.win) == require("anvim.agentlog").buf("quit_a1")]],
        "the preview showed no log"
      )
      -- Typed, because a :qa in an API call or a scheduled callback prints no
      -- errors from exit-time autocmds.
      keys(":qa<CR>")
      chan = nil
      local code = vim.fn.jobwait({ id }, 5000)
      assert.are.same({ 0 }, code, ":qa with the Overview open did not quit")
    end)
    if vim.fn.jobwait({ id }, 0)[1] == -1 then
      vim.fn.jobstop(id)
    end
    chan = shared
    assert(ok, err)
    local path = dir .. "/state/anvim/anvim.log"
    local log = vim.uv.fs_stat(path) and vim.fn.readfile(path) or {}
    for _, line in ipairs(log) do
      assert(not line:find("failed", 1, true), table.concat(log, "\n"))
    end
    -- The typed command echoes on stderr, and its chunks can split a line.
    assert.are.same(":qa", table.concat(errors))
  end)

  it(":q in the prompt quits with two tabs, cleanly, and leaves the install dirs untouched", function()
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
    for _, dir in ipairs({ "lazy", "mason", "site" }) do
      assert(not vim.uv.fs_stat(xdg .. "/data/anvim/" .. dir), "anvim installed into the data dir: " .. dir)
    end
  end)
end)
