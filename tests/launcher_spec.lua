---@module "luassert"

-- bin/anvim's flags, with a fake nvim on PATH that prints what it gets.
local helpers = require("helpers")

local bin = helpers.tmp .. "/fakebin"
local project = helpers.tmp .. "/launcher project"
vim.fn.mkdir(bin, "p")
vim.fn.mkdir(project, "p")
vim.fn.writefile({
  "#!/bin/sh",
  [[printf '%s|%s|%s|%s|%s\n' "$ANVIM_MODEL" "$ANVIM_RESUME" "$ANVIM_CONTINUE" "$(pwd)" "$*"]],
}, bin .. "/nvim")
vim.fn.setfperm(bin .. "/nvim", "rwxr-xr-x")

local id = "9b0fe4b4-4c79-44ac-be0c-7ccce0301a50"

---@return { model: string, resume: string, continue: string, dir: string, args: string }?, integer code, string stderr
local function run(args, env)
  local res = vim
    .system(vim.list_extend({ helpers.root .. "/bin/anvim" }, args), {
      cwd = helpers.tmp,
      text = true,
      env = vim.tbl_extend(
        "force",
        { PATH = bin .. ":" .. vim.env.PATH, ANVIM_MODEL = "", ANVIM_MODE = "" },
        env or {}
      ),
    })
    :wait()
  local model, resume, continue, dir, rest = (res.stdout or ""):match("^(.-)|(.-)|(.-)|(.-)|(.-)\n$")
  local out = model and { model = model, resume = resume, continue = continue, dir = dir, args = rest } or nil
  return out, res.code, res.stderr or ""
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
