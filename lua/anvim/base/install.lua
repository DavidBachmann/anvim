-- Installs into the install dir what anvim needs: the plugins at the repo's
-- pins, mason's packages and the treesitter parsers. scripts/install,
-- scripts/test-deps and scripts/update-plugins run it in a headless Neovim
-- after init.lua, with ANVIM_NO_INSTALL=1, so that the specs install nothing
-- on their own.
local base = require("anvim.base")

local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

---@type anvim.Lock? The repo's pins, once read.
M.repo = nil

-- The mason packages that anvim's specs use, and the tool that mason needs
-- to install each one, when it is not mason's own.
M.packages = {
  { name = "tree-sitter-cli" },
  { name = "lua-language-server" },
  { name = "vtsls", needs = "npm" },
  { name = "json-lsp", needs = "npm" },
}

---@alias anvim.Lock table<string, { branch: string, commit: string }>

-- The repo's pins win. The other entries, such as the plugins of personal
-- specs, stay.
---@param repo anvim.Lock
---@param install? anvim.Lock The install dir's lockfile, if it has one.
---@return anvim.Lock
function M.merge(repo, install)
  return vim.tbl_extend("force", install or {}, repo)
end

-- In lazy.nvim's own format, so that its rewrites change only the lines of
-- plugins that moved.
---@param lock anvim.Lock
function M.encode(lock)
  local names = vim.tbl_keys(lock)
  table.sort(names)
  local lines = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = ([[  %q: { "branch": %q, "commit": %q }]]):format(name, lock[name].branch, lock[name].commit)
  end
  return "{\n" .. table.concat(lines, ",\n") .. "\n}\n"
end

---@return string?
local function read(path)
  local f = io.open(path, "r")
  if f then
    local text = f:read("*a")
    f:close()
    return text
  end
end

---@return anvim.Lock?
local function decode(text)
  local ok, lock = pcall(vim.json.decode, text or "")
  return ok and type(lock) == "table" and lock or nil
end

-- A message, as mason and nvim-treesitter print theirs. A headless Neovim
-- starts a new line before a message only when it knows that the last one
-- left the line open, and a vim.wait() can make it forget. So each line ends
-- itself.
local function say(text)
  vim.api.nvim_echo({ { text .. "\n" } }, false, {})
end

---@return string?
local function head(dir)
  -- Without a .git of its own, git would name the commit of a repo above it.
  if not vim.uv.fs_stat(dir .. "/.git") then
    return nil
  end
  local out = vim.system({ "git", "-C", dir, "rev-parse", "HEAD" }, { text = true }):wait()
  return out.code == 0 and vim.trim(out.stdout) or nil
end

-- The plugins that lazy.nvim clones, without anvim's own dir.
local function plugins()
  return vim.tbl_filter(function(plugin)
    return not plugin._.is_local
  end, require("lazy").plugins())
end

-- The repo's pins, read once. When ANVIM_LOCKFILE names the repo's file, as
-- for scripts/update-plugins, lazy.nvim rewrites it from the plugins' commits
-- after its install at start.
---@return anvim.Lock
local function repo()
  M.repo = M.repo
    or decode(read(M.root .. "/lazy-lock.json"))
    or error("The repo's lazy-lock.json is not valid JSON", 0)
  return M.repo
end

-- A problem with a plugin that the repo pins is an error. Other plugins, such
-- as those of personal specs, only get a warning, so that one broken spec
-- does not make every start install again.
---@param errors string[]
local function problem(errors, name, text)
  if repo()[name] then
    errors[#errors + 1] = text
  else
    say("Warning: " .. text)
  end
end

-- Raises the errors, and those of lazy.nvim's tasks. lazy.nvim prints
-- nothing in a headless Neovim (init.lua).
---@param errors string[]
local function raise(errors)
  for _, plugin in ipairs(plugins()) do
    for _, task in ipairs(plugin._.tasks or {}) do
      if task:has_errors() then
        problem(errors, plugin.name, ("%s: %s"):format(plugin.name, vim.trim(task:output(vim.log.levels.ERROR))))
      end
    end
  end
  if #errors > 0 then
    error(table.concat(errors, "\n"), 0)
  end
end

-- Puts mason's bin dir on PATH. The parsers and nvim-treesitter's build step
-- need the tree-sitter CLI from there.
local function mason_path()
  local bin = base.dir .. "/mason/bin"
  if not vim.tbl_contains(vim.split(vim.env.PATH, ":", { plain = true }), bin) then
    vim.env.PATH = bin .. ":" .. vim.env.PATH
  end
end

---@param lock anvim.Lock
local function save(lock)
  local text = M.encode(lock)
  if read(base.lockfile) ~= text then
    vim.fn.mkdir(vim.fs.dirname(base.lockfile), "p")
    local f = assert(io.open(base.lockfile, "wb"))
    f:write(text)
    f:close()
  end
end

-- Writes the repo's pins into lazy.nvim's lockfile, over the entries that it
-- has. init.lua runs it before lazy.nvim reads the lockfile, when an install
-- script asks for it.
---@return anvim.Lock lock The pins that the lockfile has now.
function M.write_pins()
  local lock = M.merge(repo(), decode(read(base.lockfile)))
  save(lock)
  return lock
end

-- Brings the plugins to the repo's pins: it merges the repo's lockfile into
-- lazy.nvim's, installs the missing plugins, and restores the plugins whose
-- pin changed. Nothing runs when the plugins match already.
function M.sync()
  mason_path()
  local lazy = require("lazy")
  local lock = M.write_pins()
  -- lazy.nvim keeps its lockfile in memory once it read it. After an install
  -- or a restore, it rewrites the file from the commits that the plugins
  -- have, and drops the pins of plugins that are not installed. So each step
  -- starts from the merged pins again.
  local function reload()
    save(lock)
    require("lazy.manage.lock")._loaded = false
  end

  reload()
  local missing = vim.tbl_filter(function(plugin)
    return not vim.uv.fs_stat(plugin.dir)
  end, plugins())
  if #missing > 0 then
    say(("Installing %d plugins"):format(#missing))
    lazy.install({ wait = true, lockfile = true, show = false })
    reload()
  end
  local stale = {}
  for _, plugin in ipairs(plugins()) do
    local pin = lock[plugin.name]
    if pin and vim.uv.fs_stat(plugin.dir) and head(plugin.dir) ~= pin.commit then
      stale[#stale + 1] = plugin.name
    end
  end
  if #stale > 0 then
    say("Moving to the repo's pins: " .. table.concat(stale, ", "))
    lazy.restore({ wait = true, show = false, plugins = stale })
  end

  local errors = {}
  for _, plugin in ipairs(plugins()) do
    local commit, pin = head(plugin.dir), lock[plugin.name]
    if not commit then
      problem(errors, plugin.name, plugin.name .. " is not installed")
    elseif pin and commit ~= pin.commit then
      problem(errors, plugin.name, ("%s is at %s, and the lockfile has %s"):format(plugin.name, commit, pin.commit))
    end
  end
  raise(errors)
  say("The plugins are at the repo's pins")
end

-- Updates the plugins, all or the named ones, to their newest commits.
-- lazy.nvim writes the new pins to its lockfile.
---@param names string[]
function M.update(names)
  for _, name in ipairs(names) do
    if not require("lazy.core.config").plugins[name] then
      error("anvim's spec has no plugin named " .. name, 0)
    end
  end
  say("Updating " .. (#names > 0 and table.concat(names, ", ") or "every plugin"))
  require("lazy").update({ wait = true, show = false, plugins = #names > 0 and names or nil })
  raise({})
  say("The new pins are in " .. base.lockfile)
end

-- Waits for the callback of mason's async call, which gets a success flag
-- and an error.
---@param start fun(callback: fun(ok: boolean, err: any))
---@return boolean ok, any err
local function wait(start)
  local result
  start(function(ok, err)
    result = { ok, err }
  end)
  vim.wait(10 * 60 * 1000, function()
    return result ~= nil
  end, 50)
  return result and result[1] or false, result and result[2] or "timed out"
end

-- Installs the mason packages that are missing. :MasonInstall would
-- reinstall the others, and in a headless Neovim it quits before its errors
-- show.
function M.mason()
  require("lazy").load({ plugins = { "mason.nvim" } })
  local registry = require("mason-registry")
  local names, skipped = {}, false
  for _, pkg in ipairs(M.packages) do
    if not registry.is_installed(pkg.name) then
      if pkg.needs and vim.fn.executable(pkg.needs) == 0 then
        say(("Skipping %s, which needs %s"):format(pkg.name, pkg.needs))
        skipped = true
      else
        names[#names + 1] = pkg.name
      end
    end
  end
  if #names > 0 then
    say("Installing mason packages: " .. table.concat(names, ", "))
    -- With ANVIM_NO_INSTALL=1, mason refreshes no registry, and an install
    -- needs one.
    local ok, err = wait(registry.update)
    if not ok then
      error("mason could not update its registry: " .. tostring(err), 0)
    end
    local results = {}
    for _, name in ipairs(names) do
      registry.get_package(name):install({}, function(success, reason)
        results[name] = { success, reason }
      end)
    end
    vim.wait(10 * 60 * 1000, function()
      return vim.tbl_count(results) == #names
    end, 50)
    local errors = {}
    for _, name in ipairs(names) do
      local result = results[name] or { false, "timed out" }
      if not result[1] then
        errors[#errors + 1] = ("mason could not install %s: %s"):format(name, tostring(result[2]))
      end
    end
    if #errors > 0 then
      error(table.concat(errors, "\n"), 0)
    end
  end
  say(skipped and "The other mason packages are installed" or "The mason packages are installed")
end

-- Installs the parsers that the treesitter spec names, and updates those
-- that a new nvim-treesitter changed.
function M.parsers()
  if vim.fn.executable("cc") == 0 and not vim.env.CC then
    say("Skipping the treesitter parsers, which need a C compiler")
    return
  end
  mason_path()
  if vim.fn.executable("tree-sitter") == 0 then
    error("The tree-sitter CLI is missing. Mason installs it as tree-sitter-cli.", 0)
  end
  local plugin = require("lazy.core.config").plugins["nvim-treesitter"]
  local langs = require("lazy.core.plugin").values(plugin, "opts", false).ensure_installed
  require("lazy").load({ plugins = { "nvim-treesitter" } })
  local ts = require("nvim-treesitter")
  local installed = ts.get_installed("parsers")
  local missing = vim.tbl_filter(function(lang)
    return not vim.list_contains(installed, lang)
  end, langs)
  if #missing > 0 then
    say(("Installing %d treesitter parsers"):format(#missing))
  end
  local ok = ts.install(missing):wait(10 * 60 * 1000) and ts.update(langs):wait(10 * 60 * 1000)
  if not ok then
    error("Some treesitter parsers failed to install. :TSLog in anvim shows why.", 0)
  end
  say("The treesitter parsers are installed")
end

-- Runs the steps, and quits Neovim with 1 on the first error.
---@param fn fun()
function M.run(fn)
  local ok, err = pcall(fn)
  if not ok then
    vim.api.nvim_echo({ { tostring(err) .. "\n", "ErrorMsg" } }, true, {})
    vim.cmd("1cquit")
  end
end

return M
