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
  [[printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$ANVIM_MODEL" "$ANVIM_RESUME" "$ANVIM_CONTINUE" "$(pwd)" "$*" "$ANVIM_INSTALL_DIR" "$ANVIM_INSTALL_FAILED" "$ANVIM_EFFORT" "$ANVIM_SANDBOX" "$ANVIM_ACCOUNT" "$ANVIM_MODE"]],
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
---@field effort string
---@field sandbox string
---@field account string
---@field mode string

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
    ANVIM_EFFORT = "",
    ANVIM_SANDBOX = "",
    ANVIM_ACCOUNT = "",
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
  local model, resume, continue, dir, rest, install, failed, effort, sandbox, account, mode = (res.stdout or ""):match(
    "^(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)\n$"
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
        effort = effort,
        sandbox = sandbox,
        account = account,
        mode = mode,
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
  it("takes -c, --resume with and without an id and --account, and passes the rest on to nvim", function()
    local out = assert(run({ "-c", project }))
    assert.are.same({ "1", "", vim.fn.resolve(project) }, { out.continue, out.resume, vim.fn.resolve(out.dir) })
    out = assert(run({ "--resume", project }))
    assert.are.same({ "pick", vim.fn.resolve(project) }, { out.resume, vim.fn.resolve(out.dir) })
    out = assert(run({ "-r", id, "--model", "haiku", project, "+10" }))
    assert.are.same({ id, "haiku" }, { out.resume, out.model })
    assert(vim.endswith(out.args, "/init.lua +10"), out.args)
    out = assert(run({ "--resume=abc" }))
    assert.are.same("abc", out.resume)
    out = assert(run({ "--account", "personal", project, "--account=x" }))
    assert.are.same({ "x", vim.fn.resolve(project) }, { out.account, vim.fn.resolve(out.dir) })
  end)

  it("turns the sandbox off with --no-sandbox, and keeps ANVIM_SANDBOX from the environment", function()
    -- Unset, so that only bin/anvim's export can bring it to nvim.
    local out = assert(run({ "--no-sandbox", project, "+10" }, { ANVIM_SANDBOX = false }))
    assert.are.same({ "0", vim.fn.resolve(project) }, { out.sandbox, vim.fn.resolve(out.dir) })
    assert(vim.endswith(out.args, "/init.lua +10"), out.args)
    out = assert(run({ project }))
    assert.are.same("", out.sandbox)
    out = assert(run({ project }, { ANVIM_SANDBOX = "0" }))
    assert.are.same("0", out.sandbox)
  end)

  it("turns the sandbox off and starts in bypass mode with --dangerously-skip-permissions", function()
    local out =
      assert(run({ "--mode", "default", "--dangerously-skip-permissions", project }, { ANVIM_SANDBOX = false }))
    assert.are.same({ "0", "bypassPermissions" }, { out.sandbox, out.mode })
  end)

  it("never resumes from a value that another anvim left in the environment", function()
    local out = assert(run({}, { ANVIM_RESUME = "leak", ANVIM_CONTINUE = "1" }))
    assert.are.same({ "", "" }, { out.resume, out.continue })
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
end)
