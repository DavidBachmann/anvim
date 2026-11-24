-- Accounts: the Claude Code config dirs that hold a login of their own, such
-- as a work login and a personal one. CLAUDE_CONFIG_DIR picks the dir, and
-- unset, it is ~/.claude with the login in ~/.claude.json. anvim picks the
-- account at start, remembers it for each directory, switches it, adds one
-- and signs in again.
local config = require("anvim.config")
local prefs = require("anvim.prefs")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api

-- Specs replace it with a fake home.
M.home = vim.uv.os_homedir()

-- What Claude Code shares between the accounts when an account shares them:
-- settings, instructions, plugins, memory and sessions.
M.shared = {
  "settings.json",
  "CLAUDE.md",
  "keybindings.json",
  "statusline-command.sh",
  "agents",
  "skills",
  "commands",
  "rules",
  "workflows",
  "output-styles",
  "hooks",
  "plugins",
  "agent-memory",
  "projects",
  "file-history",
  "tasks",
  "todos",
  "history.jsonl",
}

---@class anvim.Account
---@field name string
---@field dir string? Nil for the default account, which leaves CLAUDE_CONFIG_DIR unset.
---@field email string?
---@field organization string?
---@field login boolean Whether its .claude.json has a login.

---@type string? CLAUDE_CONFIG_DIR as anvim found it at start.
M.env_dir = nil
---@type { name: string, why: string }? The account of this start, and why, for :checkhealth.
M.reason = nil
---@type fun()? The sidecar start that waits for an account.
local pending

---@param name string
---@return boolean
function M.valid_name(name)
  return name:match("^[%w_-]+$") ~= nil and name ~= "default"
end

---@return table? oauthAccount
local function read_login(file)
  local f = io.open(file, "r")
  if not f then
    return
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
  f:close()
  return ok and type(data) == "table" and type(data.oauthAccount) == "table" and data.oauthAccount or nil
end

---@param name string
---@param dir string?
---@return anvim.Account
local function account(name, dir)
  local info = read_login(dir and (dir .. "/.claude.json") or (M.home .. "/.claude.json"))
  return {
    name = name,
    dir = dir,
    email = info and info.emailAddress,
    organization = info and info.organizationName,
    login = info ~= nil,
  }
end

-- ~/.claude-personal is "personal". Any other dir is named by its ~ path.
---@param dir string
---@return string
function M.name_of(dir)
  dir = vim.fs.normalize(dir)
  local name = vim.fs.basename(dir):match("^%.claude%-(.+)$")
  if name and vim.fs.dirname(dir) == vim.fs.normalize(M.home) and M.valid_name(name) then
    return name
  end
  return (dir:gsub("^" .. vim.pesc(vim.fs.normalize(M.home)) .. "/", "~/"))
end

-- The default account, each ~/.claude-<name> with a login, and the
-- CLAUDE_CONFIG_DIR of the start.
---@return anvim.Account[]
function M.list()
  local list = { account("default") }
  local found = {}
  for entry, kind in vim.fs.dir(M.home) do
    local name = entry:match("^%.claude%-(.+)$")
    if name and M.valid_name(name) and (kind == "directory" or kind == "link") then
      local a = account(name, M.home .. "/" .. entry)
      if a.login then
        found[#found + 1] = a
      end
    end
  end
  table.sort(found, function(a, b)
    return a.name < b.name
  end)
  vim.list_extend(list, found)
  if M.env_dir and not M.find(list, M.name_of(M.env_dir)) then
    list[#list + 1] = account(M.name_of(M.env_dir), M.env_dir)
  end
  return list
end

---@param list anvim.Account[]
---@return anvim.Account?
function M.find(list, name)
  for _, a in ipairs(list) do
    if a.name == name then
      return a
    end
  end
end

---@return string
function M.current()
  local dir = vim.env.CLAUDE_CONFIG_DIR
  return (dir and dir ~= "") and M.name_of(dir) or "default"
end

-- The accounts that a picker offers: those with a login, and the current one.
---@param list anvim.Account[]
---@return anvim.Account[]
local function offered(list)
  local current = M.current()
  return vim.tbl_filter(function(a)
    return a.login or a.name == current
  end, list)
end

---@param list anvim.Account[]
local function names(list)
  return table.concat(
    vim.tbl_map(function(a)
      return a.name
    end, list),
    ", "
  )
end

---@class anvim.AccountStart
---@field flag string? --account or ANVIM_ACCOUNT
---@field env string? CLAUDE_CONFIG_DIR at start
---@field remembered string? The account that anvim remembers for this directory.
---@field accounts anvim.Account[]
---@field ui boolean Whether a UI shows this Neovim, so that a picker can ask.

-- The first rule that applies picks the account. Without a name, a picker asks.
---@param s anvim.AccountStart
---@return { name: string?, why: string?, warning: string? }
function M.decide(s)
  local logins = vim.tbl_filter(function(a)
    return a.login
  end, s.accounts)
  local warning
  if s.flag then
    local a = M.find(s.accounts, s.flag)
    if a and (a.name == "default" or a.login) then
      return { name = s.flag, why = "anvim started with --account" }
    end
    warning = ("anvim: the account %s is unknown. The accounts are %s."):format(s.flag, names(offered(s.accounts)))
  elseif s.env then
    return { name = M.name_of(s.env), why = "CLAUDE_CONFIG_DIR was set at start" }
  end
  local remembered = s.remembered and M.find(s.accounts, s.remembered)
  if s.ui and warning then
    return { warning = warning }
  elseif remembered and remembered.login then
    return { name = remembered.name, why = "anvim remembers it for this directory", warning = warning }
  elseif #logins >= 2 then
    return s.ui and {} or { name = "default", why = "no UI can ask for one", warning = warning }
  elseif #logins == 1 then
    return { name = logins[1].name, why = "it is the only account with a login", warning = warning }
  end
  return { name = "default", why = "no other account has a login", warning = warning }
end

local function remembered_all()
  return prefs.get("accounts") or {}
end

local function remember(name)
  prefs.update("accounts", function(all)
    all = type(all) == "table" and all or {}
    all[state.cwd] = name
    return all
  end)
end

-- Remembers the email of the account's login.
---@param a anvim.Account
---@return string? before The email that anvim remembered until now.
local function remember_login(a)
  local before
  prefs.update("logins", function(all)
    all = type(all) == "table" and all or {}
    before = all[a.name]
    all[a.name] = a.email
    return all
  end)
  return before
end

-- Sets CLAUDE_CONFIG_DIR for the account. The default account unsets it,
-- because Claude Code reads another login for ~/.claude when it is set.
---@param a anvim.Account
---@param why string
local function use(a, why)
  vim.env.CLAUDE_CONFIG_DIR = a.dir
  M.reason = { name = a.name, why = why }
  remember(a.name)
end

---@param a anvim.Account
local function label(a)
  local parts = { a.email }
  local org = a.organization
  if org and not (a.email and org == a.email .. "'s Organization") then
    parts[#parts + 1] = org
  end
  return table.concat(parts, " · ")
end

local function ask_name()
  vim.ui.input({ prompt = "Name of the new account: " }, function(name)
    if name and vim.trim(name) ~= "" then
      M.add(vim.trim(name))
    end
  end)
end

local function ask_login()
  vim.ui.select(offered(M.list()), {
    prompt = "Sign in again to",
    format_item = function(a)
      return ("%-12s %s"):format(a.name, label(a))
    end,
  }, function(a)
    if a then
      M.sign_in(a.name)
    end
  end)
end

---@param prompt string
---@param mark string? The account that gets the ⏺.
---@param on_choice fun(a: anvim.Account?, action: fun()?) The action of a row that is no account.
function M.show_picker(prompt, mark, on_choice)
  ---@type table[]
  local items = offered(M.list())
  if #items > 0 then
    items[#items + 1] = { title = "Sign in again", action = ask_login }
  end
  items[#items + 1] = { title = "Add an account", action = ask_name }
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(a)
      if a.action then
        return "  " .. a.title
      end
      return ("%s%-12s %s"):format(a.name == mark and "⏺ " or "  ", a.name, label(a))
    end,
    -- At start, the explorer opens its split after the picker, and snacks
    -- closes a picker when a split outside it gets the cursor.
    snacks = pending and { auto_close = false } or nil,
  }, function(a)
    if a and a.action then
      on_choice(nil, a.action)
    else
      on_choice(a)
    end
  end)
end

function M.stopped()
  transcript.notice("info", "Claude has not started, because no account was chosen. /account starts it.")
end

-- Starts Claude with the account that the start rules pick, or asks first.
---@param go fun() Starts the sidecar.
function M.start(go)
  local flag = config.options.account
  vim.env.ANVIM_ACCOUNT = nil
  if config.options.replay then
    M.reason = { name = M.current(), why = "anvim plays a recording, which uses no account" }
    return go()
  end
  M.env_dir = vim.env.CLAUDE_CONFIG_DIR ~= "" and vim.env.CLAUDE_CONFIG_DIR or nil
  local list = M.list()
  local d = M.decide({
    flag = flag ~= "" and flag or nil,
    env = M.env_dir,
    remembered = remembered_all()[state.cwd],
    accounts = list,
    ui = #api.nvim_list_uis() > 0,
  })
  if d.warning then
    vim.notify(d.warning, vim.log.levels.WARN)
  end
  if d.name then
    use(assert(M.find(list, d.name)), d.why)
    return go()
  end
  pending = go
  vim.schedule(function()
    M.show_picker("Claude starts with the account", nil, function(a, action)
      if a then
        M.switch(a.name)
      else
        M.stopped()
        if action then
          action()
        end
      end
    end)
  end)
end

-- Both accounts read the same sessions, as when one links the other's
-- projects dir.
---@param a anvim.Account
---@param b anvim.Account
local function same_sessions(a, b)
  local function dir(x)
    local p = (x.dir or (M.home .. "/.claude")) .. "/projects"
    return vim.uv.fs_realpath(p) or vim.fs.normalize(p)
  end
  return dir(a) == dir(b)
end

-- The account of this name, which has a login or is the default one. An
-- unknown name gets a notice.
---@param name string
---@param list anvim.Account[]
---@return anvim.Account?
local function known(name, list)
  local a = M.find(list, name)
  if a and (a.login or a.name == "default") then
    return a
  end
  transcript.notice("info", ("The account %s is unknown. The accounts are %s."):format(name, names(offered(list))))
end

---@param name string
function M.switch(name)
  local list = M.list()
  local a = known(name, list)
  if not a then
    return
  end
  if pending then
    local go = pending
    pending = nil
    use(a, "you chose it")
    go()
    return
  end
  local from = M.find(list, M.current()) or account(M.current(), vim.env.CLAUDE_CONFIG_DIR)
  if a.name == from.name then
    return
  elseif state.busy or #require("anvim.agents").running() > 0 then
    transcript.notice("info", "Claude is working. Switch the account once the turn ends, or stop Claude first.")
    return
  end
  local sessions = require("anvim.sessions")
  local resume = same_sessions(from, a) and (state.turns or 0) > 0
  use(a, "you switched to it")
  state.email = nil
  require("anvim.statusline").refresh()
  if resume then
    sessions.restart("Switching to the account " .. a.name)
    return
  end
  local why = (state.turns or 0) > 0 and "it keeps its sessions apart from " .. from.name
    or "this session has no turns yet"
  sessions.reset()
  transcript.notice(
    "info",
    ("Switching to the account %s. Claude starts a new session, because %s."):format(a.name, why)
  )
  state.process = "starting"
  sidecar.restart(sessions.start_command())
end

function M.pick()
  M.show_picker("Account", not pending and M.current() or nil, function(a, action)
    if action then
      action()
    elseif a then
      M.switch(a.name)
    end
  end)
end

-- Links the shared names from ~/.claude into dir: only names that exist, and
-- never over a file or link that dir has.
---@param dir string
---@return string[] linked
function M.link(dir)
  local linked = {}
  for _, name in ipairs(M.shared) do
    local from, to = M.home .. "/.claude/" .. name, dir .. "/" .. name
    if vim.uv.fs_lstat(from) and not vim.uv.fs_lstat(to) and vim.uv.fs_symlink(from, to) then
      linked[#linked + 1] = name
    end
  end
  return linked
end

-- What the user hears after a login, and the restart that gives Claude the
-- new login of its account. The browser decides the login, so it can be
-- another one than the email that the user gave.
---@param a anvim.Account
---@param email string?
local function logged_in(a, email)
  local done = ("The account %s logged in%s"):format(a.name, a.email and (" as " .. a.email) or "")
  if email and a.email and email:lower() ~= a.email:lower() then
    local again = "Sign out of claude.ai in the browser, then run /account login %s %s."
    transcript.notice("warn", ("%s, not as %s. " .. again):format(done, email, a.name, email))
    return
  end
  remember_login(a)
  if pending or a.name ~= M.current() then
    transcript.notice("info", ("%s. /account %s switches to it."):format(done, a.name))
  elseif state.busy or #require("anvim.agents").running() > 0 then
    transcript.notice("info", done .. ". Once Claude is done, <leader>cR restarts it with this login.")
  else
    transcript.notice("info", done .. ".")
    state.email = nil
    require("anvim.statusline").refresh()
    require("anvim.sessions").restart("Restarting Claude with this login")
  end
end

-- Claude Code's auth login in a terminal float, for the account in dir. It
-- opens in normal mode, and i types.
---@param name string
---@param dir string? Nil for the default account.
---@param opts? { email: string?, cmd: string[]? } The email that the login page starts with, and the login command, the bundled binary's by default.
function M.login(name, dir, opts)
  opts = opts or {}
  local cmd = opts.cmd
  if not cmd then
    local claude = sidecar.claude()
    if not claude then
      vim.notify("anvim: the Agent SDK has no Claude Code binary. Run scripts/install.", vim.log.levels.ERROR)
      return
    end
    cmd = { claude, "auth", "login" }
    if opts.email then
      vim.list_extend(cmd, { "--email", opts.email })
    end
  end
  -- jobstart() cannot unset a variable.
  if not dir then
    cmd = vim.list_extend({ "env", "-u", "CLAUDE_CONFIG_DIR" }, cmd)
  end
  -- The prompt's <CR> sent /account from insert mode. In a terminal, it would go on to terminal mode.
  vim.cmd.stopinsert()
  local closed = false
  local win = Snacks.win({
    position = "float",
    border = "rounded",
    title = (" Log in to the account %s "):format(name),
    footer = { { " i type · q close and stop the login ", "FloatFooter" } },
    width = function()
      return math.min(100, vim.o.columns - 4)
    end,
    height = function()
      return math.min(20, vim.o.lines - 6)
    end,
    enter = true,
    backdrop = false,
    zindex = Snacks.win.zindex(20),
    wo = { winbar = "" },
    keys = { q = false },
  })
  local job
  local ok, err = pcall(api.nvim_win_call, win.win, function()
    job = vim.fn.jobstart(cmd, {
      term = true,
      env = dir and { CLAUDE_CONFIG_DIR = dir } or nil,
      on_exit = function(_, code)
        vim.schedule(function()
          local a = account(name, dir)
          -- A login that failed or wrote nothing keeps its output on screen.
          if closed or code ~= 0 or not a.login then
            return
          end
          closed = true
          win:close()
          logged_in(a, opts.email)
        end)
      end,
    })
  end)
  if not ok then
    win:close()
    vim.notify("anvim: the login did not start: " .. vim.split(tostring(err), "\n")[1], vim.log.levels.ERROR)
    return
  end
  vim.bo[win.buf].filetype = "anvim_login"
  require("anvim.keys").set("login", "n", "q", function()
    closed = true
    if job and job > 0 then
      pcall(vim.fn.jobstop, job)
    end
    win:close()
  end, { buffer = win.buf, nowait = true })
  return win
end

---@param name string
function M.add(name)
  if not M.valid_name(name) then
    transcript.notice("info", "An account's name has letters, digits, - and _, and it is not default.")
    return
  end
  local dir = M.home .. "/.claude-" .. name
  if account(name, dir).login then
    transcript.notice(
      "info",
      ("~/.claude-%s already has a login. /account %s switches to it, and /account login %s signs in again."):format(
        name,
        name,
        name
      )
    )
    return
  end
  local share = "Share settings, instructions, skills and sessions with ~/.claude (recommended)"
  vim.ui.select({ share, "Keep the account separate" }, { prompt = "The account " .. name }, function(choice)
    if not choice then
      return
    end
    vim.fn.mkdir(dir, "p")
    if choice == share then
      M.link(dir)
    end
    -- A picker ends insert mode two scheduled turns after it closes.
    vim.schedule(function()
      M.login(name, dir)
    end)
  end)
end

-- Signs in again to an account, such as when its login has expired or holds
-- another login than it should. The email asks the login page for that login.
---@param name string
---@param email string?
function M.sign_in(name, email)
  local a = known(name, M.list())
  if not a then
    return
  end
  if email then
    M.login(a.name, a.dir, { email = email })
    return
  end
  vim.ui.input({ prompt = ("Email for the account %s: "):format(a.name), default = a.email }, function(text)
    if not text then
      return
    end
    text = vim.trim(text)
    -- An input ends insert mode after it closes, as a picker does.
    vim.schedule(function()
      M.login(a.name, a.dir, { email = text ~= "" and text or nil })
    end)
  end)
end

-- Claude Code says that the login failed, and that `claude auth login` signs
-- in again. In a terminal, that command signs in the default account.
local function failed()
  local a = not config.options.replay and M.find(M.list(), M.current())
  if a and a.login then
    local email = a.email and (" (%s)"):format(a.email) or ""
    transcript.notice("info", ("This is the account %s%s. /account login signs in again."):format(a.name, email))
  end
end

-- Claude started. The login behind an account can change outside anvim, so a
-- work project could run with a personal login. The user hears of a change once.
local function started(ev)
  local a = ev.email and not config.options.replay and M.find(M.list(), M.current())
  if not (a and a.email) then
    return
  end
  local before = remember_login(a)
  if before and before:lower() ~= a.email:lower() then
    transcript.notice(
      "warn",
      ("The account %s was %s and is now %s. /account login %s %s signs in as before."):format(
        a.name,
        before,
        a.email,
        a.name,
        before
      )
    )
  end
end

function M.attach()
  sidecar.on("login_failed", failed)
  sidecar.on("account", started)
end

-- /account, /account <name>, /account add [name] and
-- /account login [name] [email].
---@param arg string
function M.command(arg)
  if config.options.replay then
    transcript.notice("info", "anvim plays a recording, which uses no account.")
    return
  end
  local name = arg:match("^add%s+(.+)$")
  if name then
    M.add(name)
  elseif arg == "add" then
    ask_name()
  elseif arg == "login" or arg:find("^login%s") then
    local words = vim.split(arg, "%s+", { trimempty = true })
    if words[2] or not pending then
      M.sign_in(words[2] or M.current(), words[3])
    else
      ask_login()
    end
  elseif arg ~= "" then
    M.switch(arg)
  else
    M.pick()
  end
end

-- Claude waits for an account, after the start's picker closed without one.
function M.waiting()
  return pending ~= nil
end

return M
