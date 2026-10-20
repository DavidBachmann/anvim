---@module "luassert"

-- bin/anvim's flags and its install check, with a fake nvim on PATH that
-- prints what it gets. The real scripts/install runs, with a fake bun, and
-- the fake nvim stands in for its headless Neovim too.
local helpers = require("helpers")

local bin = helpers.tmp .. "/fakebin"
local project = helpers.tmp .. "/launcher project"
vim.fn.mkdir(bin, "p")
vim.fn.mkdir(project, "p")
vim.fn.writefile({
  "#!/bin/sh",
  [[case "$1" in]],
  [[  --version) echo "NVIM v0.12.5"; exit 0 ;;]],
  [[  --headless) echo "fake install" >&2; exit "${FAKE_INSTALL_EXIT:-0}" ;;]],
  "esac",
  [[printf '%s|%s|%s|%s|%s|%s|%s\n' "$ANVIM_MODEL" "$ANVIM_RESUME" "$ANVIM_CONTINUE" "$(pwd)" "$*" "$ANVIM_INSTALL_DIR" "$ANVIM_INSTALL_FAILED"]],
}, bin .. "/nvim")
vim.fn.writefile({ "#!/bin/sh", [[[ "$1" = --version ] && echo 1.0.0]], "exit 0" }, bin .. "/bun")
for _, name in ipairs({ "nvim", "bun" }) do
  vim.fn.setfperm(bin .. "/" .. name, "rwxr-xr-x")
end

local id = "9b0fe4b4-4c79-44ac-be0c-7ccce0301a50"

---@class anvim.LauncherOut
---@field model string
---@field resume string
---@field continue string
---@field dir string
---@field args string
---@field install string
---@field failed string ANVIM_INSTALL_FAILED

---@param env? table<string, string|false> false unsets the variable.
---@return anvim.LauncherOut? out What nvim got, or nil when bin/anvim did not start it.
---@return integer code
---@return string stderr
local function run(args, env, cwd)
  local full = vim.fn.environ()
  local defaults = {
    PATH = bin .. ":" .. vim.env.PATH,
    ANVIM_MODEL = "",
    ANVIM_MODE = "",
    ANVIM_NO_INSTALL = "1",
    ANVIM_INSTALL_DIR = helpers.tmp .. "/launcher install",
  }
  for key, value in pairs(vim.tbl_extend("force", defaults, env or {})) do
    full[key] = value or nil
  end
  local res = vim
    .system(vim.list_extend({ helpers.root .. "/bin/anvim" }, args), {
      cwd = cwd or helpers.tmp,
      text = true,
      env = full,
      clear_env = true,
    })
    :wait()
  local model, resume, continue, dir, rest, install, failed = (res.stdout or ""):match(
    "^(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)\n$"
  )
  local out = model
      and {
        model = model,
        resume = resume,
        continue = continue,
        dir = dir,
        args = rest,
        install = install,
        failed = failed,
      }
    or nil
  return out, res.code, res.stderr or ""
end

-- What an install applies, as scripts/install keeps it in the stamp.
local applied = table.concat(vim.tbl_map(function(path)
  return table.concat(vim.fn.readfile(helpers.root .. "/" .. path, "b"), "\n")
end, { "lazy-lock.json", "sidecar/bun.lock", "lua/anvim/base/install.lua", "lua/anvim/base/plugins/treesitter.lua" }))

local function read(path)
  return vim.uv.fs_stat(path) and table.concat(vim.fn.readfile(path, "b"), "\n") or nil
end

describe("bin/anvim", function()
  it("takes -c, --resume with and without an id, and passes the rest on to nvim", function()
    local out = assert(run({ "-c", project }))
    assert.are.same({ "1", "", vim.fn.resolve(project) }, { out.continue, out.resume, vim.fn.resolve(out.dir) })
    out = assert(run({ "--resume", project }))
    assert.are.same({ "pick", vim.fn.resolve(project) }, { out.resume, vim.fn.resolve(out.dir) })
    out = assert(run({ "-r", id, "--model", "haiku", project, "+10" }))
    assert.are.same({ id, "haiku" }, { out.resume, out.model })
    assert(vim.endswith(out.args, "/init.lua +10"), out.args)
    out = assert(run({ "--resume=abc" }))
    assert.are.same("abc", out.resume)
  end)

  it("never resumes from a value that another anvim left in the environment", function()
    local out = assert(run({}, { ANVIM_RESUME = "leak", ANVIM_CONTINUE = "1" }))
    assert.are.same({ "", "" }, { out.resume, out.continue })
  end)

  it("refuses a flag without its value, and --continue with --resume", function()
    local out, code, err = run({ project, "--model" })
    assert.is_nil(out)
    assert.are.same(2, code)
    assert(err:find("needs a value"), err)
    out, code, err = run({ "-c", "--resume", id })
    assert.is_nil(out)
    assert.are.same(2, code)
    assert(err:find("not both"), err)
  end)
end)

describe("bin/anvim's install check", function()
  local n = 0
  -- A new install dir for each case.
  local function fresh()
    n = n + 1
    return helpers.tmp .. "/install " .. n
  end

  it("installs when there is no stamp, and skips the install once the stamp matches", function()
    local dir = fresh()
    local out, code, err = run({ project }, { ANVIM_NO_INSTALL = "", ANVIM_INSTALL_DIR = dir })
    assert.are.same(0, code, err)
    out = assert(out, "nvim did not start: " .. err)
    -- With --embed, stdout is the RPC channel, so the install writes none of it.
    assert.are.same("", out.model, "the install wrote to stdout")
    assert(err:find("fake install", 1, true), err)
    assert.are.same(applied, read(dir .. "/stamp"))
    -- Another anvim's value of the variable does not reach this one.
    out, code, err = run({ project }, { ANVIM_NO_INSTALL = "", ANVIM_INSTALL_DIR = dir, ANVIM_INSTALL_FAILED = "1" })
    out = assert(out, "nvim did not start: " .. err)
    assert.are.same("", err, "a matching stamp ran the install")
    assert.are.same("", out.failed)
  end)

  it("installs when the stamp differs, and starts anyway when that install fails", function()
    local dir = fresh()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "an older lockfile" }, dir .. "/stamp")
    local env = { ANVIM_NO_INSTALL = "", ANVIM_INSTALL_DIR = dir, FAKE_INSTALL_EXIT = "1" }
    local out, code, err = run({ project }, env)
    assert(err:find("fake install", 1, true), err)
    assert(err:find("starts with the earlier install", 1, true), err)
    assert.are.same(0, code, err)
    out = assert(out, "nvim did not start: " .. err)
    assert.are.same("1", out.failed, "anvim gets no word of the failed install")
    assert.are.same("an older lockfile\n", read(dir .. "/stamp"), "a failed install wrote the stamp")
    env.FAKE_INSTALL_EXIT = "0"
    out, code, err = run({ project }, env)
    assert(err:find("fake install", 1, true), "the next start did not try again: " .. err)
    assert.are.same(applied, read(dir .. "/stamp"))
  end)

  it("exits with 1 when the first install fails", function()
    local dir = fresh()
    local out, code, err = run({ project }, { ANVIM_NO_INSTALL = "", ANVIM_INSTALL_DIR = dir, FAKE_INSTALL_EXIT = "1" })
    assert.is_nil(out, "nvim started without an install")
    assert.are.same(1, code)
    assert(err:find("the install failed", 1, true), err)
    assert.is_nil(read(dir .. "/stamp"))
  end)

  it("skips the check with ANVIM_NO_INSTALL=1", function()
    local dir = fresh()
    local out, _, err = run({ project }, { ANVIM_INSTALL_DIR = dir, FAKE_INSTALL_EXIT = "1" })
    assert(out, "nvim did not start: " .. err)
    assert.are.same("", err)
    assert.is_nil(vim.uv.fs_stat(dir))
  end)

  it("installs into the dir that anvim's Neovim names, and passes it on as an absolute path", function()
    local home = helpers.tmp .. "/launcher home"
    local cases = {
      { ANVIM_INSTALL_DIR = helpers.tmp .. "/named" },
      { ANVIM_INSTALL_DIR = "", XDG_DATA_HOME = helpers.tmp .. "/xdg data" },
      { ANVIM_INSTALL_DIR = false, XDG_DATA_HOME = false, HOME = home },
    }
    for _, env in ipairs(cases) do
      env.ANVIM_NO_INSTALL = ""
      local out, _, err = run({ project }, env)
      out = assert(out, "nvim did not start: " .. err)
      assert(read(out.install .. "/stamp"), "no stamp in " .. out.install)
      -- What lua/anvim/base names, in a Neovim with the same environment.
      local script = helpers.tmp .. "/install_dir.lua"
      vim.fn.writefile({
        ("vim.opt.rtp:prepend(%q)"):format(helpers.root),
        [[io.write(require("anvim.base").dir)]],
      }, script)
      local full = vim.fn.environ()
      full.NVIM_APPNAME = "anvim"
      for key, value in pairs(env) do
        full[key] = value or nil
      end
      local res = vim.system({ vim.v.progpath, "--clean", "-l", script }, { env = full, clear_env = true }):wait()
      assert.are.same(res.stdout, out.install, vim.inspect(env))
    end
    -- A relative dir names the same dir after bin/anvim changes to the project,
    -- also without the install check.
    local out, _, err = run({ project }, { ANVIM_NO_INSTALL = "", ANVIM_INSTALL_DIR = "relative/dir" })
    out = assert(out, "nvim did not start: " .. err)
    assert.are.same(helpers.tmp .. "/relative/dir", out.install)
    assert(read(helpers.tmp .. "/relative/dir/stamp"), "no stamp in the relative dir")
    out, _, err = run({ project }, { ANVIM_INSTALL_DIR = "other/dir" })
    out = assert(out, "nvim did not start: " .. err)
    assert.are.same(helpers.tmp .. "/other/dir", out.install)
  end)
end)
