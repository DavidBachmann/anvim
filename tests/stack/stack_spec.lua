---@module "luassert"

-- Boots the real init.lua in a child Neovim, as bin/anvim does. Its state,
-- cache, config and data dirs are temporary. Its plugins and mason packages
-- come from .tests/anvim, which scripts/test-deps fills, and must stay
-- unchanged. So must the main Neovim's dirs.
local helpers = require("helpers")

local home = assert(vim.env.HOME)
local xdg_user = vim.g.anvim_user_xdg or {}
local function xdg_dir(value, default)
  return (value and value ~= "" and value or home .. default) .. "/nvim"
end
local nvim_config = xdg_dir(xdg_user.config, "/.config")
local nvim_data = xdg_dir(xdg_user.data, "/.local/share")
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
    -- runs in anvim's start mode, with the default effort and the sandbox. A
    -- debug anvim passes ANVIM_DEBUG to Claude's shell, which runs the tests.
    if
      key:match("^XDG_")
      or key:match("^LAZY_")
      or key:match("^NVIM")
      or key:match("^CMUX_")
      or key == "ANVIM_MODE"
      or key == "ANVIM_EFFORT"
      or key == "ANVIM_SANDBOX"
      or key == "ANVIM_DEBUG"
    then
      env[key] = nil
    end
  end
  env.NVIM_APPNAME = "anvim"
  for _, name in ipairs({ "config", "data", "state", "cache" }) do
    env[("XDG_%s_HOME"):format(name:upper())] = dir .. "/" .. name
  end
  -- The tool pane starts off, so the tool calls show in the chat.
  local prefs = dir .. "/state/anvim/prefs.json"
  if vim.fn.filereadable(prefs) == 0 then
    vim.fn.mkdir(vim.fs.dirname(prefs), "p")
    vim.fn.writefile({ vim.json.encode({ tool_pane = false }) }, prefs)
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
  -- snacks.image places images as in Ghostty. Without a UI, the escapes go nowhere.
  env.SNACKS_GHOSTTY = "1"
  -- RPC over stdio, not a socket, which Claude's sandbox does not allow.
  local id = vim.fn.jobstart({
    vim.v.progpath,
    "--headless",
    "--embed",
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
    rpc = true,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          errors[#errors + 1] = line
        end
      end
    end,
  })
  assert(id > 0, "child did not start")
  chan = id
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

-- Types keys in the child. Its main loop runs them after this call returns,
-- through which-key and anvim's maps, as for a user.
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
  assert.are.same(4, out.input.height, what .. ": the prompt fits its text")
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

  it("starts in bypass mode with the sandbox on without ANVIM_MODE, so Claude runs tools without asking", function()
    start()
    local out = lua([[
      local options = require("anvim.config").options
      return { mode = options.permission_mode, sandbox = options.sandbox }
    ]])
    assert.are.same({ mode = "bypassPermissions", sandbox = true }, out)
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

  it("picks a colorscheme with <leader>uC and remembers it", function()
    start()
    lua([[require("anvim.layout").focus_input({ insert = false })]])
    keys("<leader>uC")
    wait(3000, [[return Snacks.picker.get({ source = "colorschemes" })[1] ~= nil]], "<leader>uC opened no picker")
    keys("habamax")
    wait(
      3000,
      [[
        local item = Snacks.picker.get({ source = "colorschemes" })[1]:current()
        return item and item.text == "habamax"
      ]],
      "the picker did not find habamax"
    )
    keys("<CR>")
    wait(3000, [[return require("anvim.prefs").get("colorscheme") == "habamax"]], "Enter did not remember habamax")
    wait(3000, [[return vim.g.colors_name == "habamax"]], "Enter did not load habamax")
    lua([[
      require("anvim.prefs").set("colorscheme", nil)
      vim.cmd.colorscheme("tokyonight")
      require("anvim.layout").focus_input({ insert = false })
    ]])
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

  it("shows a PNG or JPG that Claude reads as an image, also without ImageMagick, and keeps it read-only", function()
    start()
    local images = {
      ["pixel.png"] = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
      ["pixel.jpg"] = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD57ooor+kTxz//2Q==",
    }
    for name, data in pairs(images) do
      local file = helpers.tmp .. "/" .. name
      local f = assert(io.open(file, "wb"))
      f:write(vim.base64.decode(data))
      f:close()
      local out = lua(
        [[
        local file = ...
        local api = vim.api
        local layout = require("anvim.layout")
        local code = layout.code_win()
        local before = api.nvim_win_get_buf(code)
        layout.focus_input({ insert = false })
        local sidecar = require("anvim.sidecar")
        sidecar.dispatch({ type = "tool_use", id = "img1", name = "Read", input = { file_path = file } })
        local buf = vim.fn.bufnr(file)
        -- snacks converts a JPG to a PNG first. A failed image writes its error into the buffer.
        local img = Snacks.image.image.new(api.nvim_buf_get_name(buf))
        vim.wait(3000, function()
          return img:ready() or img:failed()
        end, 20)
        local out = {
          ft = vim.bo[buf].filetype,
          shown = api.nvim_win_get_buf(code) == buf,
          ready = img:ready(),
          lines = api.nvim_buf_get_lines(buf, 0, -1, false),
          modifiable = vim.bo[buf].modifiable,
        }
        sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })
        -- The next cases expect the file that the code window showed.
        api.nvim_win_set_buf(code, before)
        api.nvim_buf_delete(buf, { force = true })
        return out
      ]],
        file
      )
      assert.are.same({ ft = "image", shown = true, ready = true, lines = { "" }, modifiable = false }, out, name)
    end
  end)

  it("toggles the explorer with <leader>e, and the explorer changes no files", function()
    start()
    local function closed(what)
      wait(3000, [[return Snacks.picker.get({ source = "explorer" })[1] == nil]], what .. " left the explorer open")
      wait_where({ win = "code", mode = "n" }, what)
      assert_layout(what)
    end
    lua([[
      require("anvim.layout").focus_input()
      vim.cmd.stopinsert()
    ]])
    keys("<C-h>")
    wait_where({ win = "code", mode = "n" }, "<C-h> from the prompt")
    keys("<leader>e")
    closed("<leader>e in the code window")

    lua([[require("anvim.layout").focus_input({ insert = false })]])
    wait_where({ win = "input", mode = "n" }, "the prompt")
    keys("<leader>e")
    wait_where({ win = "snacks_picker_list", mode = "n" }, "<leader>e in the prompt")
    -- The list is a float on the explorer's split, not on top of the prompt.
    assert.are.same("review", lua([[return require("anvim.follow").mode()]]))
    assert_layout("<leader>e in the prompt")
    local maps = lua([[
      local maps = {}
      for _, key in ipairs({ "a", "d", "r", "c", "m", "p", "<C-c>" }) do
        maps[key] = vim.fn.maparg(key, "n")
      end
      return maps
    ]])
    assert.are.same({ a = "", d = "", r = "", c = "", m = "", p = "", ["<C-c>"] = "" }, maps)
    keys("<leader>e")
    closed("<leader>e in the explorer")

    -- snacks' q closes the explorer too. The explorer opened from the prompt,
    -- and the cursor still goes to the code window.
    lua([[require("anvim.layout").focus_input({ insert = false })]])
    keys("<leader>e")
    wait_where({ win = "snacks_picker_list", mode = "n" }, "<leader>e in the prompt")
    keys("q")
    closed("q in the explorer")

    keys("<leader>e")
    wait_where({ win = "snacks_picker_list", mode = "n" }, "<leader>e in the code window")
    assert_layout("<leader>e in the code window")
    keys("<C-l>")
    wait_where({ win = "code", mode = "n" }, "<C-l> from the tree")
    lua([[require("anvim.layout").focus_input({ insert = false })]])
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
    -- The list of Claude's files.
    lua(
      [[
      local sidecar = require("anvim.sidecar")
      sidecar.dispatch({ type = "tool_use", id = "keys_read", name = "Read", input = { file_path = ... } })
      sidecar.dispatch({ type = "tool_result", id = "keys_read", is_error = false, text = "" })
      require("anvim.files").pick()
    ]],
      repo .. "/notes.txt"
    )
    wait(
      3000,
      [[local p = Snacks.picker.get({ source = "anvim_files" })[1] return p ~= nil and p.list.win:win_valid()]],
      "Claude's files did not open"
    )
    snap("files", "files", [[Snacks.picker.get({ source = "anvim_files" })[1].list.win.buf]])
    lua([[
      Snacks.picker.get({ source = "anvim_files" })[1]:close()
      require("anvim.files").clear()
      vim.schedule(function()
        require("anvim.layout").focus_input({ insert = false })
      end)
    ]])
    wait_where({ win = "input", mode = "n" }, "closing Claude's files")
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
      require("anvim.settings").open("status")
      snap("settings", "settings", vim.api.nvim_get_current_buf())
      require("anvim.settings").close()
      local login = require("anvim.accounts").login("keys", vim.fn.tempname(), { "sh", "-c", "read x" })
      snap("login", "login", login.buf)
      login:close()
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
      local files_keys = require("anvim.files").keys
      local ours_files = {}
      for lhs in pairs(files_keys) do
        ours_files[vim.keycode(lhs)] = true
      end
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
        elseif ctx == "files" and not ours_files[vim.keycode(m.lhs)] then
          -- snacks' own picker keys.
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
      for lhs, spec in pairs(files_keys) do
        local key = spec and keys.find("files", spec.mode or "n", lhs)
        if spec and not (key and key[2] == spec.desc) then
          problems[#problems + 1] = ("the file list's %s is not in the view"):format(lhs)
        end
      end
      return problems
    ]],
      clean
    )
    assert.are.same({}, problems)
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

  it("logs in a new account in a terminal float that opens in normal mode, and q stops a login", function()
    start()
    local dir = helpers.tmp .. "/login-dir"
    vim.fn.mkdir(dir, "p")
    local stub = helpers.tmp .. "/fake-login"
    vim.fn.writefile({
      "#!/bin/sh",
      [[printf 'Paste code here if prompted > ']],
      "read code",
      [[printf '{"oauthAccount":{"emailAddress":"new@x.com"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"]],
    }, stub)
    vim.fn.setfperm(stub, "rwxr-xr-x")
    lua([[require("anvim.layout").focus_input()]])
    wait_where({ win = "input", mode = "i" }, "the prompt")
    lua([[require("anvim.accounts").login("new", ...)]], dir, { stub })
    wait(
      5000,
      [[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Paste code") ~= nil]],
      "the login did not ask for a code"
    )
    wait_where({ win = "anvim_login", mode = "nt" }, "the login float")
    keys("i")
    wait_where({ win = "anvim_login", mode = "t" }, "i in the login float")
    keys("abc<CR>")
    wait(5000, [[return vim.bo.filetype ~= "anvim_login"]], "the float stayed after the login")
    local lines = lua([[return vim.api.nvim_buf_get_lines(require("anvim.transcript").buf(), 0, -1, false)]])
    helpers.contains(lines, "The account new logged in as new@x%.com")

    local id = lua(
      [[
      local win = require("anvim.accounts").login("new", ..., { "sh", "-c", "sleep 30" })
      return vim.b[win.buf].terminal_job_id
    ]],
      dir
    )
    wait_where({ win = "anvim_login", mode = "nt" }, "the second login float")
    keys("q")
    wait(3000, [[return vim.bo.filetype ~= "anvim_login"]], "q did not close the float")
    wait(3000, ("return vim.fn.jobwait({ %d }, 0)[1] ~= -1"):format(id), "q did not stop the login")
    lua([[require("anvim.layout").focus_input({ insert = false })]])
    wait_where({ win = "input", mode = "n" }, "the prompt after the login")
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
