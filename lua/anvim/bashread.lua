-- The files that a simple Bash command reads, and the hits that a grep in it
-- prints. This Claude Code build has no Grep or Glob tool, so Claude searches
-- with Bash, and often reads files there too. Follow mode shows these reads
-- as it shows a Read. A command that is not simple gives nothing, because a
-- wrong jump is worse than none.
local state = require("anvim.state")

local M = {}

---@class anvim.Read
---@field path string absolute
---@field first integer? 1-based. nil is line 1.
---@field last integer? Inclusive. nil is the rest of the file.

---@class anvim.Word
---@field text string
---@field expands boolean? The shell would expand it: $VAR, a glob, braces or ~user.

---@class anvim.Command
---@field name string? nil for a command of assignments only.
---@field args anvim.Word[]
---@field out boolean? Its output goes elsewhere, as with > file.

---@class anvim.Pipeline
---@field conn string? The operator before it: ";", "&", "&&" or "||".
---@field cmds anvim.Command[]
---@field background boolean? It ends in &, so it runs in a subshell of its own.

---@class anvim.Grep
---@field cwd string|false
---@field file string? The one file that it searches, whose hits have no path.
---@field context boolean? It prints context lines and "--" between groups.
---@field after { text: string, count: integer }? Its output starts after this line of an echo.

---@class anvim.Hit
---@field path string absolute
---@field line integer

-- A tail needs the file's line count. The parser counts no larger files, so
-- their tail is no read.
local MAX_COUNT_BYTES = 10 * 1024 * 1024

local keywords = {}
for _, word in ipairs({ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac" }) do
  keywords[word] = true
end
for _, word in ipairs({ "function", "select", "time", "coproc", "{", "}", "[[", "]]", "!" }) do
  keywords[word] = true
end

-- Commands that move the shell, or may.
local movers = { cd = true, pushd = true, popd = true, source = true, ["."] = true, eval = true }

-- Splits a command line into words and operators, with the shell's quoting.
-- nil when the line holds what the parser does not follow: command and
-- process substitution, subshells, heredocs and open quotes.
---@return table[]?
local function tokenize(line)
  local list = {}
  local buf, expands, started, tilde = {}, false, false, false
  local function push()
    if started then
      local text = table.concat(buf)
      if tilde and (text == "~" or text:sub(1, 2) == "~/") then
        text = vim.uv.os_homedir() .. text:sub(2)
      elseif tilde then
        expands = true
      end
      list[#list + 1] = { text = text, expands = expands }
    end
    buf, expands, started, tilde = {}, false, false, false
  end
  local function add(s)
    buf[#buf + 1] = s
    started = true
  end
  -- A $ before a name or a brace expands. $( ends the parse, and so do
  -- $'...' and $"..." outside double quotes.
  local function dollar(i, quoted)
    local nx = line:sub(i + 1, i + 1)
    if nx == "(" or (not quoted and (nx == "'" or nx == '"')) then
      return false
    end
    if nx:match("[%w_{@*#?!$-]") then
      expands = true
    end
    return true
  end
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == " " or c == "\t" then
      push()
      i = i + 1
    elseif c == "\n" then
      push()
      list[#list + 1] = { op = ";" }
      i = i + 1
    elseif c == "#" and not started then
      i = line:find("\n", i, true) or n + 1
    elseif c == "\\" then
      local nx = line:sub(i + 1, i + 1)
      if nx == "" then
        return nil
      elseif nx ~= "\n" then
        add(nx)
      end
      i = i + 2
    elseif c == "'" then
      local close = line:find("'", i + 1, true)
      if not close then
        return nil
      end
      add(line:sub(i + 1, close - 1))
      i = close + 1
    elseif c == '"' then
      started = true
      i = i + 1
      while true do
        local d = line:sub(i, i)
        if d == "" or d == "`" then
          return nil
        elseif d == '"' then
          i = i + 1
          break
        elseif d == "\\" and line:sub(i + 1, i + 1):match('[$`"\\\n]') then
          local e = line:sub(i + 1, i + 1)
          if e ~= "\n" then
            add(e)
          end
          i = i + 2
        elseif d == "$" and not dollar(i, true) then
          return nil
        else
          add(d)
          i = i + 1
        end
      end
    elseif c == "`" or c == "(" or c == ")" then
      return nil
    elseif c == "$" then
      if not dollar(i) then
        return nil
      end
      add(c)
      i = i + 1
    elseif c == ";" or c == "&" or c == "|" then
      push()
      local two = line:sub(i, i + 1)
      if two == ";;" then
        return nil
      elseif two == "&>" then
        local op = line:sub(i, i + 2) == "&>>" and "&>>" or "&>"
        list[#list + 1] = { redir = op }
        i = i + #op
      elseif two == "&&" or two == "||" then
        list[#list + 1] = { op = two }
        i = i + 2
      elseif two == "|&" then
        list[#list + 1] = { op = "|" }
        i = i + 2
      else
        list[#list + 1] = { op = c }
        i = i + 1
      end
    elseif c == ">" or c == "<" then
      local fd
      if started and not tilde and not expands and table.concat(buf):match("^%d+$") then
        fd = table.concat(buf)
        buf, started = {}, false
      else
        push()
      end
      local two = line:sub(i, i + 1)
      if two == "<<" or two == "<(" or two == ">(" then
        return nil
      end
      local op = (two == ">>" or two == ">|" or two == ">&" or two == "<&" or two == "<>") and two or c
      list[#list + 1] = { redir = op, fd = fd }
      i = i + #op
    else
      if c == "~" and not started then
        tilde = true
      elseif c == "*" or c == "?" or c == "[" or c == "{" or c == "}" then
        expands = true
      end
      add(c)
      i = i + 1
    end
  end
  push()
  return list
end

-- Whether a redirection sends the command's output where Claude does not see
-- it. Claude sees stderr too.
local function redirects_out(redir, target)
  local op = redir.redir
  if op:sub(1, 2) == "&>" then
    return true
  elseif redir.fd and redir.fd ~= "1" then
    return false
  elseif op == ">&" then
    return target ~= "1" and target ~= "2"
  end
  return op == ">" or op == ">>" or op == ">|"
end

-- The pipelines of a command line, each with the operator before it.
---@return anvim.Pipeline[]?
function M.split(line)
  local tokens = tokenize(line)
  if not tokens then
    return nil
  end
  local pipelines, pipeline, conn = {}, { cmds = {} }, nil
  local words, out, redir = {}, false, nil
  local function end_command()
    local k = 1
    while words[k] and words[k].text:match("^[%a_][%w_]*=") do
      k = k + 1
    end
    -- builtin cd and command cd run cd. command -v cd only looks it up.
    if words[k] and (words[k].text == "builtin" or words[k].text == "command") then
      k = words[k + 1] and words[k + 1].text:sub(1, 1) ~= "-" and k + 1 or k
    end
    local name = words[k]
    if name and (name.expands or keywords[name.text]) then
      return false
    end
    if #words > 0 or out then
      pipeline.cmds[#pipeline.cmds + 1] = {
        name = name and name.text:match("[^/]+$"),
        args = vim.list_slice(words, k + 1),
        out = out or nil,
      }
    elseif #pipeline.cmds > 0 then
      -- An empty command in a pipeline is a syntax error.
      return false
    end
    words, out = {}, false
    return true
  end
  for _, token in ipairs(tokens) do
    if redir then
      if not token.text then
        return nil
      end
      out = out or redirects_out(redir, token.text)
      redir = nil
    elseif token.redir then
      redir = token
    elseif token.op then
      if not end_command() then
        return nil
      end
      if token.op ~= "|" then
        if #pipeline.cmds > 0 then
          pipeline.conn, pipeline.background = conn, token.op == "&" or nil
          pipelines[#pipelines + 1] = pipeline
        end
        pipeline, conn = { cmds = {} }, token.op
      end
    else
      words[#words + 1] = token
    end
  end
  if redir or not end_command() then
    return nil
  end
  if #pipeline.cmds > 0 then
    pipeline.conn = conn
    pipelines[#pipelines + 1] = pipeline
  end
  return pipelines
end

---@param dir string|false
---@return string?
local function resolve(text, dir)
  if text:sub(1, 1) == "/" then
    return vim.fs.normalize(text)
  end
  return dir and vim.fs.normalize(vim.fs.joinpath(dir, text)) or nil
end

-- The absolute path of a word that names a regular file.
---@param word anvim.Word
---@param dir string|false
---@return string?
local function regular(word, dir)
  local path = not word.expands and word.text ~= "-" and resolve(word.text, dir)
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file" and path or nil
end

-- Splits a command's arguments into options and operands. `short` and
-- `long` name the options that take a value, which can be the next word. A
-- number option such as -20 is "#". nil when a value is missing. `seen`
-- counts each option, since opts keeps only the last value.
---@param args anvim.Word[]
---@return table<string, anvim.Word|true>? opts
---@return anvim.Word[] operands
---@return table<string, integer> seen
local function getopt(args, short, long)
  local opts, operands, seen, i, only = {}, {}, {}, 1, false
  local function put(key, value)
    opts[key], seen[key] = value, (seen[key] or 0) + 1
  end
  while i <= #args do
    local w = args[i]
    local t = w.text
    if only or t == "-" or t:sub(1, 1) ~= "-" then
      operands[#operands + 1] = w
    elseif t == "--" then
      only = true
    elseif t:match("^%-%d+$") then
      put("#", { text = t:sub(2), expands = w.expands })
    elseif t:sub(1, 2) == "--" then
      local name, value = t:match("^%-%-([^=]+)=(.*)$")
      if name then
        put(name, { text = value, expands = w.expands })
      elseif long[t:sub(3)] then
        i = i + 1
        if not args[i] then
          return nil, {}, {}
        end
        put(t:sub(3), args[i])
      else
        put(t:sub(3), true)
      end
    else
      for k = 2, #t do
        local c = t:sub(k, k)
        if short[c] then
          local value = t:sub(k + 1)
          if value == "" then
            i = i + 1
            if not args[i] then
              return nil, {}, {}
            end
            put(c, args[i])
          else
            put(c, { text = value, expands = w.expands })
          end
          break
        end
        put(c, true)
      end
    end
    i = i + 1
  end
  return opts, operands, seen
end

-- Whether every option is one of `allowed`.
local function only(opts, allowed)
  for key in pairs(opts) do
    if not allowed[key] then
      return false
    end
  end
  return true
end

local function set(list)
  local s = {}
  for _, key in ipairs(list) do
    s[key] = true
  end
  return s
end

local function names(text)
  return set(vim.split(text, " ", { trimempty = true }))
end

-- Several handlers parse each call, so the counts stay until the file changes.
---@type table<string, { sec: integer, nsec: integer, size: integer, n: integer }>
local counts = {}

---@return integer?
local function count_lines(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > MAX_COUNT_BYTES then
    return nil
  end
  local known = counts[path]
  if known and known.sec == stat.mtime.sec and known.nsec == stat.mtime.nsec and known.size == stat.size then
    return known.n
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a") or ""
  f:close()
  local n = select(2, data:gsub("\n", ""))
  if #data > 0 and data:sub(-1) ~= "\n" then
    n = n + 1
  end
  counts[path] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, size = stat.size, n = n }
  return n
end

-- The -n value of head and tail, as text. nil when it is not a plain value.
local function lines_value(opts)
  local v = opts.n or opts.lines or opts["#"]
  if v == nil then
    return "10"
  end
  return v ~= true and not v.expands and v.text or nil
end

local lines_opts = { n = true, c = true }
local lines_long = { lines = true, bytes = true }
local lines_allowed = set({ "n", "lines", "#", "q", "v", "quiet", "silent", "verbose" })

---@type table<string, fun(args: anvim.Word[], dir: string|false): anvim.Read[]>
local readers = {}

function readers.cat(args, dir)
  local opts, files = getopt(args, {}, {})
  local reads = {}
  for _, w in ipairs(opts and files or {}) do
    local path = regular(w, dir)
    if path then
      reads[#reads + 1] = { path = path }
    end
  end
  return reads
end

local nl_short = set({ "b", "d", "f", "h", "i", "l", "n", "s", "v", "w" })
local nl_long = names(
  "body-numbering section-delimiter footer-numbering header-numbering line-increment join-blank-lines "
    .. "number-format number-separator starting-line-number number-width"
)

function readers.nl(args, dir)
  local opts, files = getopt(args, nl_short, nl_long)
  return opts and readers.cat(files, dir) or {}
end

function readers.head(args, dir)
  local opts, files = getopt(args, lines_opts, lines_long)
  local n = opts and only(opts, lines_allowed) and tonumber((lines_value(opts) or ""):match("^%d+$"))
  local reads = {}
  for _, w in ipairs(n and n > 0 and files or {}) do
    local path = regular(w, dir)
    if path then
      reads[#reads + 1] = { path = path, first = 1, last = n }
    end
  end
  return reads
end

function readers.tail(args, dir)
  local opts, files = getopt(args, lines_opts, lines_long)
  local value = opts and only(opts, lines_allowed) and lines_value(opts) or ""
  local from, n = tonumber(value:match("^%+(%d+)$")), tonumber(value:match("^%d+$"))
  local reads = {}
  for _, w in ipairs((from or (n and n > 0)) and files or {}) do
    -- tail +40 file is an old form that the parser does not follow.
    if w.text:sub(1, 1) == "+" then
      return {}
    end
    local path = regular(w, dir)
    local count = path and not from and count_lines(path)
    if path and from then
      reads[#reads + 1] = { path = path, first = math.max(from, 1) }
    elseif count and count > 0 then
      reads[#reads + 1] = { path = path, first = math.max(count - n + 1, 1), last = count }
    end
  end
  return reads
end

local sed_allowed = set({ "n", "quiet", "silent", "e", "expression", "E", "r", "regexp-extended", "u", "unbuffered" })

-- The range that sed -n 'Ap', 'A,Bp' or 'A,$p' prints, and its operands. b
-- is nil for $.
---@return integer? a, integer? b, anvim.Word[] operands
local function sed_range(args)
  local opts, rest, seen = getopt(args, set({ "e", "f", "l" }), set({ "expression", "file", "line-length" }))
  if not (opts and (opts.n or opts.quiet or opts.silent) and only(opts, sed_allowed)) then
    return nil, nil, {}
  end
  -- Each -e adds a script, and the parser follows only one.
  local script = opts.e or opts.expression
  if script == true or (seen.e or 0) + (seen.expression or 0) > 1 then
    return nil, nil, {}
  end
  script = script or table.remove(rest, 1)
  if not script or script.expands then
    return nil, nil, {}
  end
  local s = vim.trim(script.text)
  local a, b = s:match("^(%d+),(%d+)p$")
  a = tonumber(a or s:match("^(%d+)p$") or s:match("^(%d+),%$p$"))
  if not a or a < 1 then
    return nil, nil, {}
  elseif s:match(",%$p$") then
    return a, nil, rest
  end
  -- A range that ends before it starts prints its first line.
  return a, math.max(tonumber(b) or a, a), rest
end

-- sed -n 'Ap', 'A,Bp' and 'A,$p' of one file.
function readers.sed(args, dir)
  local a, b, files = sed_range(args)
  local path = a and #files == 1 and regular(files[1], dir)
  return path and { { path = path, first = a, last = b } } or {}
end

-- The part of a read that a filter after it lets through: `head`, `tail`
-- and `sed -n` with a range count from the read's first line. nil for any
-- other filter.
---@param read anvim.Read
---@param cmd anvim.Command
---@return anvim.Read?
local function narrow(read, cmd)
  local first = read.first or 1
  if cmd.name == "head" or cmd.name == "tail" then
    local opts, files = getopt(cmd.args, lines_opts, lines_long)
    local value = opts and #files == 0 and only(opts, lines_allowed) and lines_value(opts) or ""
    local from, n = tonumber(value:match("^%+(%d+)$")), tonumber(value:match("^%d+$"))
    if cmd.name == "head" and n and n > 0 then
      return { path = read.path, first = first, last = math.min(read.last or math.huge, first + n - 1) }
    elseif cmd.name == "tail" and from then
      return { path = read.path, first = first + math.max(from, 1) - 1, last = read.last }
    end
    local last = cmd.name == "tail" and n and n > 0 and (read.last or count_lines(read.path))
    return last and last > 0 and { path = read.path, first = math.max(first, last - n + 1), last = last } or nil
  elseif cmd.name == "sed" then
    local a, b, files = sed_range(cmd.args)
    if not a or #files > 0 or (read.last and first + a - 1 > read.last) then
      return nil
    end
    local last = b and first + b - 1
    if read.last and (not last or last > read.last) then
      last = read.last
    end
    return { path = read.path, first = first + a - 1, last = last }
  end
end

-- The reads that the filters of a pipeline let through. A filter sees
-- several files as one stream, so only `head` keeps the first of them.
---@param list anvim.Read[]
---@param p anvim.Pipeline
---@return anvim.Read[]
local function through(list, p)
  for k = 2, #p.cmds do
    if #list > 1 and p.cmds[k].name ~= "head" then
      return {}
    end
    local read = list[1] and narrow(list[1], p.cmds[k])
    list = read and { read } or {}
  end
  return list
end

-- The working directory after `cd`, or false when the parser cannot tell.
---@param dir string|false
---@param conn string?
---@return string|false
local function cd(dir, args, conn)
  local words = vim.tbl_filter(function(w)
    return w.text ~= "-P" and w.text ~= "-L" and w.text ~= "--"
  end, args)
  -- After ||, cd runs only when the command before it failed.
  if #words > 1 or conn == "||" or (words[1] and (words[1].expands or words[1].text == "-")) then
    return false
  end
  local path = words[1] and resolve(words[1].text, dir) or vim.uv.os_homedir()
  local stat = path and vim.uv.fs_stat(path)
  -- The shell keeps the physical path, as pwd -P prints it.
  return stat and stat.type == "directory" and (vim.uv.fs_realpath(path) or path) or false
end

-- Steps the working directory through a pipeline, and tells whether it ran
-- a command that moves the shell.
---@param p anvim.Pipeline
---@param dir string|false
---@return string|false dir, boolean moved
local function move(p, dir)
  local moves = false
  for _, cmd in ipairs(p.cmds) do
    moves = moves or movers[cmd.name] ~= nil
  end
  if not moves then
    return dir, false
  elseif p.background then
    -- A pipeline that ends in & runs in a subshell, which moves nothing.
    return dir, true
  elseif #p.cmds == 1 and p.cmds[1].name == "cd" then
    return cd(dir, p.cmds[1].args, p.conn), true
  end
  return false, true
end

-- The command line without quoted text, subshells, comments and heredoc
-- bodies. None of them can move the shell: a cd in ( ), $( ) or backticks
-- runs in a subshell. nil when the quotes or parentheses do not close.
---@return string?
local function toplevel(line)
  local out, stack, heredocs = {}, {}, {}
  local i, n = 1, #line
  local function emit(s)
    if #stack == 0 then
      out[#out + 1] = s
    end
  end
  while i <= n do
    local c, ctx = line:sub(i, i), stack[#stack]
    if ctx == '"' or ctx == "`" then
      if c == "\\" then
        i = i + 1
      elseif c == ctx then
        stack[#stack] = nil
        emit("q")
      elseif c == "`" or (ctx == '"' and line:sub(i, i + 1) == "$(") then
        stack[#stack + 1] = c == "`" and "`" or "("
        i = i + (c == "`" and 0 or 1)
      end
      i = i + 1
    elseif c == "\\" then
      local nx = line:sub(i + 1, i + 1)
      emit(nx == "\n" and "" or nx:match("[;&|<>(){}%s]") and "q" or nx)
      i = i + 2
    elseif c == "'" then
      local close = line:find("'", i + 1, true)
      if not close then
        return nil
      end
      emit("q")
      i = close + 1
    elseif c == '"' or c == "`" then
      stack[#stack + 1] = c
      i = i + 1
    elseif c == "(" then
      emit(" q ")
      stack[#stack + 1] = "("
      i = i + 1
    elseif c == ")" then
      if ctx ~= "(" then
        return nil
      end
      stack[#stack] = nil
      i = i + 1
    elseif c == "#" and (i == 1 or line:sub(i - 1, i - 1):match("[%s;&|(]")) then
      i = line:find("\n", i, true) or n + 1
    elseif line:sub(i, i + 1) == "<<" and line:sub(i + 2, i + 2) ~= "<" then
      local strip, j = line:match("^<<(%-?)[ \t]*()", i)
      local q = line:sub(j, j)
      local word, after
      if q == "'" or q == '"' then
        local close = line:find(q, j + 1, true)
        if not close then
          return nil
        end
        word, after = line:sub(j + 1, close - 1), close + 1
      else
        word, after = line:match("^([^%s;&|<>()]+)()", j)
        if not word then
          return nil
        end
        word = word:gsub("[\\'\"]", "")
      end
      heredocs[#heredocs + 1] = { word = word, strip = strip == "-" }
      emit(" q ")
      i = after
    elseif c == "\n" and #heredocs > 0 then
      -- The bodies start after the line that names them.
      i = i + 1
      for _, doc in ipairs(heredocs) do
        while i <= n do
          local nl = line:find("\n", i, true) or n + 1
          local body = line:sub(i, nl - 1)
          i = nl + 1
          if (doc.strip and body:gsub("^\t+", "") or body) == doc.word then
            break
          end
        end
      end
      heredocs = {}
      emit("\n")
    else
      emit(c)
      i = i + 1
    end
  end
  return #stack == 0 and table.concat(out) or nil
end

-- Words that a command can follow at the start of a command.
local prefixes = set({ "then", "do", "else", "elif", "if", "while", "until", "!", "time", "builtin", "command" })

-- Whether a command line that the parser does not follow may move the
-- shell: it runs a mover where a command starts, outside quotes, subshells
-- and heredocs.
local function may_move(line)
  local top = toplevel(line)
  if not top then
    return true
  end
  for segment in top:gmatch("[^;&|{}\n]+") do
    local words = vim.split(vim.trim(segment), "%s+")
    local k = 1
    while words[k] and (prefixes[words[k]] or words[k]:match("^[%a_][%w_]*=")) do
      k = k + 1
    end
    -- A command name from a variable can be cd too.
    if words[k] and (movers[words[k]] or words[k]:sub(1, 1) == "$") then
      return true
    end
  end
  return false
end

-- Whether a pipeline's output goes to a file, as in a copy.
---@param p anvim.Pipeline
local function redirected(p)
  for _, cmd in ipairs(p.cmds) do
    if cmd.out then
      return true
    end
  end
  return false
end

-- The files that a command line reads, in order, and the working directory
-- after it. In a pipeline, only the first command reads files.
---@param line string
---@param cwd string|false The shell's working directory, or false when it is not known.
---@return anvim.Read[] reads
---@return string|false cwd
function M.parse(line, cwd)
  local pipelines = M.split(line)
  if not pipelines then
    if may_move(line) then
      return {}, false
    end
    return {}, cwd
  end
  local reads, dir = {}, cwd
  for _, p in ipairs(pipelines) do
    local moved
    dir, moved = move(p, dir)
    -- After ||, a command runs only when the one before it failed.
    local reader = not moved and p.conn ~= "||" and not redirected(p) and readers[p.cmds[1].name]
    if reader then
      vim.list_extend(reads, through(reader(p.cmds[1].args, dir), p))
    end
  end
  return reads, dir
end

local grep_short = set({ "A", "B", "C", "D", "d", "e", "f", "m" })
local grep_long = names(
  "after-context before-context context devices directories regexp file max-count include exclude "
    .. "exclude-dir exclude-from label"
)
local rg_short = set({ "A", "B", "C", "d", "E", "e", "f", "g", "j", "M", "m", "r", "T", "t" })
local rg_long = names(
  "after-context before-context context regexp file glob iglob type type-not type-add type-clear "
    .. "max-count max-columns max-depth max-filesize threads encoding replace ignore-file sort sortr color "
    .. "colors context-separator field-match-separator field-context-separator path-separator"
)
-- Options that print something other than lines with their numbers. rg
-- has no number option but -0, which getopt names "#".
local grep_refuse = names("l L c q Z z files-with-matches files-without-match count quiet silent null null-data")
local rg_refuse = names(
  "l c q p # files files-with-matches files-without-match count count-matches quiet json heading pretty "
    .. "null null-data passthru"
)

local filter_allowed = set({ "v", "i", "E", "F", "G", "w", "x", "e", "s", "invert-match", "ignore-case", "regexp" })

-- Whether a command after a grep in its pipeline keeps the grep's lines as
-- they are, such as `| head -30` or `| grep -v test`.
---@param cmd anvim.Command
local function keeps_lines(cmd)
  if cmd.name == "sort" then
    return true
  elseif cmd.name == "head" or cmd.name == "tail" then
    local opts, files = getopt(cmd.args, lines_opts, lines_long)
    return opts ~= nil and #files == 0 and only(opts, lines_allowed)
  elseif cmd.name == "grep" then
    -- A file operand would make it read that file instead.
    local opts, operands = getopt(cmd.args, set({ "e" }), set({ "regexp" }))
    return opts ~= nil and only(opts, filter_allowed) and #operands <= ((opts.e or opts.regexp) and 0 or 1)
  end
  return false
end

-- A grep or rg that prints its hits with line numbers.
---@param p anvim.Pipeline
---@param dir string|false
---@return anvim.Grep?
local function grep_of(p, dir)
  local cmd = p.cmds[1]
  local rg = cmd.name == "rg"
  local opts, operands = getopt(cmd.args, rg and rg_short or grep_short, rg and rg_long or grep_long)
  if not opts then
    return nil
  end
  for key in pairs(opts) do
    if (rg and rg_refuse or grep_refuse)[key] then
      return nil
    end
  end
  local numbers = opts.n or opts["line-number"] or (rg and opts.vimgrep)
  if not numbers or opts.N or opts["no-line-number"] then
    return nil
  end
  if redirected(p) or p.background then
    return nil
  end
  for k = 2, #p.cmds do
    if not keeps_lines(p.cmds[k]) then
      return nil
    end
  end
  if not (opts.e or opts.regexp or opts.f or opts.file) then
    table.remove(operands, 1)
  end
  local spec = { cwd = dir }
  spec.context = (
    opts.A
    or opts.B
    or opts.C
    or opts["#"]
    or opts["after-context"]
    or opts["before-context"]
    or opts.context
  )
      and true
    or nil
  if #operands == 1 then
    spec.file = regular(operands[1], dir)
  end
  return spec
end

-- Commands that print nothing.
local quiet = set({ "cd", "export", "set", "unset", "true", ":" })

-- The line that a plain echo prints. nil for any other command.
---@param p anvim.Pipeline
---@return string?
local function echoed(p)
  local cmd = p.cmds[1]
  if #p.cmds ~= 1 or cmd.name ~= "echo" then
    return nil
  end
  local words = {}
  for _, w in ipairs(cmd.args) do
    -- -n, -e and -E change what echo prints.
    if w.expands or w.text:match("^%-[neE]+$") then
      return nil
    end
    words[#words + 1] = w.text
  end
  return table.concat(words, " ")
end

-- Whether no later output can pass for a hit without a path: the next
-- command that prints is an echo that always runs, or there is none.
---@param pipelines anvim.Pipeline[]
---@param from integer
local function fenced(pipelines, from)
  for j = from + 1, #pipelines do
    local p = pipelines[j]
    if not (quiet[p.cmds[1].name or "true"] or redirected(p)) then
      local echo = echoed(p)
      return echo ~= nil and p.conn == ";" and not echo:match("^%d+[:-]")
    end
  end
  return true
end

-- The first grep in a command line that prints hits with line numbers, as
-- long as its output comes first, or right after the line of an echo.
---@param line string
---@param cwd string|false
---@return anvim.Grep?
function M.grep(line, cwd)
  local pipelines = M.split(line)
  if not pipelines then
    return nil
  end
  local dir, printed, echoes = cwd, nil, {}
  for i, p in ipairs(pipelines) do
    local first = p.cmds[1]
    local moved
    dir, moved = move(p, dir)
    if not moved and (first.name == "grep" or first.name == "rg") then
      local spec = grep_of(p, dir)
      if spec and printed and printed.echo then
        spec.after = { text = printed.echo, count = echoes[printed.echo] }
      end
      if spec and (not printed or spec.after) then
        -- A later grep of one file prints hits that look the same.
        return (not spec.file or fenced(pipelines, i)) and spec or nil
      end
    end
    if not (moved or quiet[first.name or "true"] or redirected(p)) then
      printed = { echo = echoed(p) }
      if printed.echo then
        echoes[printed.echo] = (echoes[printed.echo] or 0) + 1
      end
    end
  end
end

-- The text of a call that failed starts with its exit code, then the errors.
local function failure(line)
  return line:match("^Exit code %d+$") or line:match("^u?grep: ") or line:match("^rg: ")
end

-- The hits that a grep printed, in order. The parse stops at the first line
-- that is not a hit, such as an echo's separator.
---@param spec anvim.Grep
---@param text string
---@return anvim.Hit[]
function M.hits(spec, text)
  local lines = vim.split(text, "\n", { plain = true })
  local start = 1
  while lines[start] and failure(lines[start]) do
    start = start + 1
  end
  if spec.after then
    local seen = 0
    start = nil
    for i, l in ipairs(lines) do
      seen = seen + (l == spec.after.text and 1 or 0)
      if seen == spec.after.count then
        start = i + 1
        break
      end
    end
  end
  local files = {}
  local function file(path)
    if files[path] == nil then
      files[path] = regular({ text = path }, spec.cwd) or false
    end
    return files[path]
  end
  -- A context line, or the line between groups.
  local function context(l)
    return spec.context and (l == "--" or (spec.file and l:match("^%d+%-")) or file(l:match("^(.-)%-%d+%-") or ""))
  end
  local hits = {}
  for i = start or #lines + 1, #lines do
    local l = lines[i]
    local n = spec.file and l:match("^(%d+):")
    local path, m = l:match("^(.-):(%d+):")
    if n then
      hits[#hits + 1] = { path = spec.file, line = tonumber(n) }
    elseif path and path ~= "" and file(path) then
      hits[#hits + 1] = { path = file(path), line = tonumber(m) }
    elseif not (context(l) or (l == "" and i == #lines)) then
      break
    end
  end
  return hits
end

-- Claude Code's Bash keeps its working directory from call to call. nil is
-- the session's cwd, and false a directory that the parser could not follow.
---@type string|false|nil
local shell_cwd
-- The directory that each Bash call leaves the shell in, when it moves it.
---@type table<string, string|false>
local moves = {}
-- The ids of Bash calls that wait for their result.
---@type table<string, true>
local calls = {}

---@return string|false
function M.cwd()
  if shell_cwd == nil then
    return state.cwd or vim.fn.getcwd()
  end
  return shell_cwd
end

-- The reads of a tool call: a Read's range, or the files that a Bash
-- command reads.
---@return anvim.Read[]
function M.reads(ev)
  local input = type(ev.input) == "table" and ev.input or {}
  if ev.name == "Read" and type(input.file_path) == "string" then
    local first, limit = tonumber(input.offset), tonumber(input.limit)
    return { { path = input.file_path, first = first, last = limit and (first or 1) + limit - 1 } }
  elseif ev.name == "Bash" and type(input.command) == "string" then
    return (M.parse(input.command, M.cwd()))
  end
  return {}
end

-- A Bash call's grep, when the call reads no files.
---@return anvim.Grep?
function M.grep_of(ev)
  local command = type(ev.input) == "table" and ev.input.command
  if ev.name == "Bash" and type(command) == "string" and #M.parse(command, M.cwd()) == 0 then
    return M.grep(command, M.cwd())
  end
end

-- Symlinks resolve first, as in /tmp and /private/tmp.
local function under(path, dir)
  path, dir = vim.uv.fs_realpath(path), vim.uv.fs_realpath(dir)
  return path ~= nil and dir ~= nil and (path == dir or vim.startswith(path, dir .. "/"))
end

-- The directory that Claude Code moved the shell back to, as its result says.
local function reset_dir(text)
  return type(text) == "string"
    and (text:match("\nShell cwd was reset to ([^\n]+)%s*$") or text:match("^Shell cwd was reset to ([^\n]+)%s*$"))
end

-- With this set, Claude Code puts the shell back after every call.
local function pinned()
  local value = vim.env.CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR
  return value ~= nil and vim.tbl_contains({ "1", "true", "yes", "on" }, vim.trim(value):lower())
end

-- Only a call of the main agent in the foreground moves the shell. Claude
-- Code keeps a subagent's shell where it is, and a call in the background
-- runs in a shell of its own.
local function on_tool_use(ev)
  local input = type(ev.input) == "table" and ev.input or {}
  if ev.name ~= "Bash" or type(input.command) ~= "string" then
    return
  end
  calls[ev.id] = true
  if ev.agent_id or ev.parent_id or input.run_in_background == true or pinned() then
    return
  end
  local start = M.cwd()
  local _, dir = M.parse(input.command, start)
  if dir ~= start then
    moves[ev.id] = dir
  end
end

-- Claude Code says when it moved the shell back into the project. Without
-- that, the shell is where the cd went, but only after a call whose exit code
-- is 0, since Claude Code reads the shell's pwd only then. A grep with no
-- match exits 1 without is_error, and its result interprets the code. A call
-- that went to the background, also later, has a backgroundTaskId.
local function on_tool_result(ev)
  if not calls[ev.id] then
    return
  end
  calls[ev.id] = nil
  local dir = moves[ev.id]
  moves[ev.id] = nil
  local result = type(ev.result) == "table" and ev.result or {}
  local said = reset_dir(result.stderr) or reset_dir(result.stdout) or reset_dir(ev.text)
  if said then
    shell_cwd = vim.trim(said)
  elseif dir ~= nil and not (ev.is_error or result.returnCodeInterpretation or result.backgroundTaskId) then
    shell_cwd = dir and under(dir, state.cwd or vim.fn.getcwd()) and dir or false
  end
end

-- A new sidecar starts a new shell.
function M.forget()
  shell_cwd, moves, calls = nil, {}, {}
end

function M.attach(sidecar)
  sidecar.on("tool_use", on_tool_use)
  sidecar.on("tool_result", on_tool_result)
  sidecar.on("history", M.forget)
  sidecar.on("exit", M.forget)
  -- /clear may keep the shell where it is.
  sidecar.on("reset", function()
    if shell_cwd ~= nil then
      shell_cwd = false
    end
  end)
end

return M
