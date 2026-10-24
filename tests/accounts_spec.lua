---@module "luassert"

-- Accounts in a fake home: ~/.claude (work), ~/.claude-personal, which
-- links the sessions of ~/.claude, ~/.claude-other with its own sessions, and
-- ~/.claude-worktrees, which is no config dir.
local accounts = require("anvim.accounts")
local helpers = require("helpers")
local sessions = require("anvim.sessions")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local home = helpers.tmp .. "/accounts-home"

local function login_file(path, email, org)
  vim.fn.writefile({ vim.json.encode({ oauthAccount = { emailAddress = email, organizationName = org } }) }, path)
end

vim.fn.mkdir(home .. "/.claude/projects", "p")
vim.fn.mkdir(home .. "/.claude/skills", "p")
vim.fn.writefile({ "{}" }, home .. "/.claude/settings.json")
login_file(home .. "/.claude.json", "me@work.com", "Work")
vim.fn.mkdir(home .. "/.claude-personal", "p")
login_file(home .. "/.claude-personal/.claude.json", "me@home.com", "me@home.com's Organization")
vim.uv.fs_symlink(home .. "/.claude/projects", home .. "/.claude-personal/projects")
vim.fn.mkdir(home .. "/.claude-other/projects", "p")
login_file(home .. "/.claude-other/.claude.json", "other@x.com", "X")
vim.fn.mkdir(home .. "/.claude-worktrees", "p")

local function names(list)
  return vim.tbl_map(function(a)
    return a.name
  end, list)
end

describe("accounts", function()
  local old_home, old_env
  before_each(function()
    helpers.start()
    old_home, old_env = accounts.home, vim.env.CLAUDE_CONFIG_DIR
    accounts.home = home
    vim.env.CLAUDE_CONFIG_DIR = nil
  end)
  after_each(function()
    accounts.home, vim.env.CLAUDE_CONFIG_DIR = old_home, old_env
  end)

  it("finds the default account and each ~/.claude-<name> with a login", function()
    local list = accounts.list()
    assert.are.same({ "default", "other", "personal" }, names(list))
    assert.are.same({ "me@home.com", home .. "/.claude-personal" }, { list[3].email, list[3].dir })
  end)

  it("picks the account at start by the first rule that applies", function()
    local list = accounts.list()
    local only_personal = vim.tbl_map(function(a)
      return vim.tbl_extend("force", a, { login = a.name == "personal" })
    end, list)
    local cases = {
      { { flag = "personal", env = home .. "/.claude-other" }, "personal" },
      { { flag = "default", env = home .. "/.claude-other" }, "default" },
      { { flag = "nope", ui = true, remembered = "other" }, nil },
      { { flag = "nope", remembered = "other" }, "other" },
      { { flag = "nope" }, "default" },
      { { env = home .. "/.claude-other", remembered = "personal" }, "other" },
      { { env = "/elsewhere/claude" }, "/elsewhere/claude" },
      { { remembered = "personal", ui = true }, "personal" },
      { { remembered = "gone", ui = true }, nil },
      { { ui = true }, nil },
      { {}, "default" },
      { { ui = true, accounts = only_personal }, "personal" },
    }
    for i, case in ipairs(cases) do
      local d = accounts.decide(vim.tbl_extend("force", { accounts = list, ui = false }, case[1]))
      assert.are.same(case[2], d.name, ("case %d: %s"):format(i, vim.inspect(case[1])))
      assert.are.same(case[1].flag == "nope", d.warning ~= nil, ("case %d warns"):format(i))
    end
  end)

  it("switches: the env follows, a shared sessions dir resumes, and another starts a new session", function()
    local restarts, restart = {}, sidecar.restart
    sidecar.restart = function(start)
      restarts[#restarts + 1] = start
    end
    local ok, err = pcall(function()
      state.session_id, state.turns = "s1", 1
      accounts.switch("personal")
      assert.are.same(home .. "/.claude-personal", vim.env.CLAUDE_CONFIG_DIR)
      assert.are.same("s1", restarts[1].resume)
      assert.are.same("personal", require("anvim.prefs").get("accounts")[state.cwd])
      accounts.switch("other")
      assert.are.same(home .. "/.claude-other", vim.env.CLAUDE_CONFIG_DIR)
      assert.is_nil(restarts[2].resume)
      helpers.contains(helpers.buf_lines(transcript.buf()), "keeps its sessions apart from personal")
      accounts.switch("default")
      assert.is_nil(vim.env.CLAUDE_CONFIG_DIR)
      assert.are.same(3, #restarts)
    end)
    sidecar.restart = restart
    sessions.reset()
    assert(ok, err)
  end)

  it("starts no Claude while the start waits for an account, also on a restart", function()
    local config = require("anvim.config")
    local replay, list_uis, select, restart =
      config.options.replay, vim.api.nvim_list_uis, vim.ui.select, sidecar.restart
    local restarts, asked, started = 0, false, nil
    config.options.replay = nil
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    vim.ui.select = function(_, _, on_choice)
      asked = true
      on_choice(nil)
    end
    sidecar.restart = function()
      restarts = restarts + 1
    end
    require("anvim.prefs").set("accounts", {})
    local ok, err = pcall(function()
      accounts.start(function()
        started = vim.env.CLAUDE_CONFIG_DIR or "default"
      end)
      vim.wait(1000, function()
        return asked
      end)
      assert(accounts.waiting(), "the start does not wait for an account")
      -- <leader>cR, which the notice does not name, must not start Claude with no account chosen.
      sessions.restart()
      assert.are.same(0, restarts)
    end)
    accounts.switch("personal")
    config.options.replay, vim.api.nvim_list_uis, vim.ui.select, sidecar.restart = replay, list_uis, select, restart
    assert(ok, err)
    assert.are.same(home .. "/.claude-personal", started)
  end)

  it("links what ~/.claude shares, and never over what the new dir has", function()
    local dir = home .. "/.claude-new"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "own" }, dir .. "/settings.json")
    assert.are.same({ "skills", "projects" }, accounts.link(dir))
    assert.are.same({ "own" }, vim.fn.readfile(dir .. "/settings.json"))
    assert.are.same(home .. "/.claude/projects", vim.uv.fs_readlink(dir .. "/projects"))
  end)
end)
