---@module "luassert"

-- The merge of the repo's lockfile into the install dir's, and the sync.
local helpers = require("helpers")
local install = require("anvim.base.install")

local function pin(commit, branch)
  return { branch = branch or "main", commit = commit }
end

describe("install", function()
  local repo = { ["lazy.nvim"] = pin("lazy2"), ["snacks.nvim"] = pin("snacks2") }

  it("merges the repo's pins over the install dir's lockfile, and keeps the plugins of personal specs", function()
    local own = { ["lazy.nvim"] = pin("lazy1", "stable"), ["snacks.nvim"] = pin("snacks1"), ["rose-pine"] = pin("rp1") }
    local merged = install.merge(repo, own)
    assert.are.same(
      { ["lazy.nvim"] = pin("lazy2"), ["snacks.nvim"] = pin("snacks2"), ["rose-pine"] = pin("rp1") },
      merged
    )
    assert.are.same(pin("snacks1"), own["snacks.nvim"], "the install dir's lockfile changed")
  end)

  it("takes the repo's pins when the install dir has no lockfile", function()
    assert.are.same(repo, install.merge(repo, nil))
  end)

  it("writes a lockfile as lazy.nvim does, so a sync that changes nothing writes nothing", function()
    local text = table.concat(vim.fn.readfile(helpers.root .. "/lazy-lock.json"), "\n") .. "\n"
    assert.are.same(text, install.encode(vim.json.decode(text)))
    assert.are.same("{\n\n}\n", install.encode({}))
  end)
end)

-- The sync in a child Neovim with anvim's init.lua, in copies of the repo's
-- Lua and of the plugins in .tests/anvim, so it needs no network. Personal
-- specs add plugins from local git repos.
describe("the sync", function()
  local dir = helpers.tmp .. "/sync"
  local root, inst, src = dir .. "/repo", dir .. "/install", dir .. "/src"
  local lockfile = root .. "/lazy-lock.json"
  -- The user's git config may sign commits or rewrite URLs.
  local git_env = {
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_NOSYSTEM = "1",
    GIT_AUTHOR_NAME = "anvim",
    GIT_AUTHOR_EMAIL = "anvim@example.invalid",
    GIT_COMMITTER_NAME = "anvim",
    GIT_COMMITTER_EMAIL = "anvim@example.invalid",
  }

  local function sh(cmd, cwd)
    local res = vim.system(cmd, { cwd = cwd, text = true, env = git_env }):wait()
    assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
    return vim.trim(res.stdout or "")
  end

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local function read(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end

  -- A plugin in a local git repo, with one commit per text.
  ---@return string url, string[] commits
  local function plugin_repo(name, texts)
    local path = src .. "/" .. name
    vim.fn.mkdir(path, "p")
    sh({ "git", "init", "-q", "-b", "main" }, path)
    local commits = {}
    for _, text in ipairs(texts) do
      write(path .. "/README.md", text .. "\n")
      sh({ "git", "add", "README.md" }, path)
      sh({ "git", "commit", "-q", "-m", text }, path)
      commits[#commits + 1] = sh({ "git", "rev-parse", "HEAD" }, path)
    end
    return "file://" .. path, commits
  end

  local function personal(specs)
    local lines = { "return {" }
    for _, spec in ipairs(specs) do
      lines[#lines + 1] = ("  { url = %q, name = %q, lazy = true },"):format(spec[1], spec[2])
    end
    lines[#lines + 1] = "}"
    write(dir .. "/config/anvim/lua/plugins/local.lua", table.concat(lines, "\n") .. "\n")
  end

  ---@return integer code, string output
  local function sync(env)
    local full = vim.fn.environ()
    for key in pairs(full) do
      if key:match("^XDG_") or key:match("^NVIM") or key:match("^LAZY_") or key:match("^ANVIM_") then
        full[key] = nil
      end
    end
    full = vim.tbl_extend("force", full, git_env, {
      NVIM_APPNAME = "anvim",
      ANVIM_INSTALL_DIR = inst,
      ANVIM_NO_INSTALL = "1",
      XDG_CONFIG_HOME = dir .. "/config",
      XDG_DATA_HOME = dir .. "/data",
      XDG_STATE_HOME = dir .. "/state",
      XDG_CACHE_HOME = dir .. "/cache",
    }, env or {})
    local res = vim
      .system({
        vim.v.progpath,
        "--headless",
        "-i",
        "NONE",
        "--cmd",
        "let g:anvim_sync = 1",
        "-u",
        root .. "/init.lua",
        "-c",
        [[lua local i = require("anvim.base.install") i.run(i.sync)]],
        "-c",
        "qa",
      }, { env = full, clear_env = true, text = true })
      :wait(60000)
    return res.code, (res.stdout or "") .. (res.stderr or "")
  end

  local demo_url, demo = plugin_repo("demo", { "one", "two" })
  local demo2_url, demo2 = plugin_repo("demo2", { "only" })
  local pins = vim.json.decode(read(helpers.root .. "/lazy-lock.json"))
  pins.demo = { branch = "main", commit = demo[1] }
  pins.demo2 = { branch = "main", commit = demo2[1] }
  local text = install.encode(pins)
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(inst, "p")
  sh({ "cp", "-R", helpers.root .. "/init.lua", helpers.root .. "/lua", root })
  sh({ "cp", "-R", helpers.root .. "/.tests/anvim/lazy", inst })

  it("keeps the repo's pins when lazy.nvim rewrites that lockfile at start, as for scripts/update-plugins", function()
    write(lockfile, text)
    personal({ { demo_url, "demo" }, { demo2_url, "demo2" } })
    -- demo is at a newer commit than its pin, and demo2 is missing, so
    -- lazy.nvim installs demo2 at start and writes demo's newer commit.
    sh({ "git", "clone", "-q", demo_url, inst .. "/lazy/demo" })
    local code, out = sync({ ANVIM_LOCKFILE = lockfile })
    assert.are.same(0, code, out)
    assert.are.same(demo[1], sh({ "git", "rev-parse", "HEAD" }, inst .. "/lazy/demo"), out)
    assert.are.same(demo2[1], sh({ "git", "rev-parse", "HEAD" }, inst .. "/lazy/demo2"), out)
    assert.are.same(text, read(lockfile), "the sync changed the repo's pins")
  end)

  it("only warns when a plugin that the repo does not pin fails to install", function()
    write(lockfile, text)
    personal({ { demo_url, "demo" }, { demo2_url, "demo2" }, { "file://" .. src .. "/missing", "broken" } })
    local code, out = sync()
    assert.are.same(0, code, out)
    assert(out:find("Warning: broken", 1, true), out)
  end)

  it("fails when a plugin that the repo pins is not at its pin", function()
    local bad = vim.deepcopy(pins)
    bad.demo.commit = ("0"):rep(40)
    write(lockfile, install.encode(bad))
    personal({ { demo_url, "demo" }, { demo2_url, "demo2" } })
    local code, out = sync()
    assert.are.same(1, code, out)
    assert(out:find("demo is at " .. demo[1], 1, true), out)
  end)
end)
