-- Answers the sidecar's editor requests (sidecar/src/tools.ts): the tools that
-- let Claude point at code and ask the language servers in this Neovim.
-- Handlers never block the main loop. They answer through `done`, once.
local follow = require("anvim.follow")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.tools")

-- The sidecar gives up on a request after 10 s. A request waits up to
-- attach_ms for a language server, and answers within budget_ms in all.
M.attach_ms = 5000
M.budget_ms = 9000
-- A wait ends early when a buffer has no language server at all, attached or
-- starting, for this long. LazyVim starts its servers a moment after a load.
local START_MS = 1000
local MAX_ITEMS = 50
local MAX_HOVER_LINES = 40
local MAX_TEXT = 120

local highlights = {
  AnvimShow = { link = "Visual" },
  AnvimNote = { link = "DiagnosticInfo" },
}

local function set_highlights()
  for name, spec in pairs(highlights) do
    api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

local function relpath(path)
  return require("anvim.transcript").relpath(path)
end

local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- One line of at most n characters.
local function clip(s, n)
  s = vim.trim((tostring(s or ""):gsub("%s+", " ")))
  if vim.fn.strchars(s) > n then
    s = vim.fn.strcharpart(s, 0, n - 3) .. "..."
  end
  return s
end

local function capped(header, lines)
  local out = { header }
  for i = 1, math.min(#lines, MAX_ITEMS) do
    out[#out + 1] = lines[i]
  end
  if #lines > MAX_ITEMS then
    out[#out + 1] = ("... %d more"):format(#lines - MAX_ITEMS)
  end
  return table.concat(out, "\n")
end

local function resolve(path)
  path = vim.fs.normalize(path)
  if vim.fn.isabsolutepath(path) == 0 then
    path = vim.fs.joinpath(state.cwd, path)
  end
  return vim.fs.normalize(path)
end

local function under(path, dir)
  return path == dir or vim.startswith(path, dir .. "/")
end

-- Symlinks resolve first, so a link in the cwd cannot point the tools outside
-- it. A missing file is judged by its path, so that answers do not tell which
-- files exist outside the cwd.
local function inside_cwd(path)
  local root = vim.uv.fs_realpath(state.cwd) or state.cwd
  local real = vim.uv.fs_realpath(path)
  if not real then
    return under(path, state.cwd) or under(path, root)
  end
  return under(real, root)
end

-- Answers can hold file text, and the tools run without a permission prompt.
-- So they read only files inside the cwd. show_user passes `anywhere`,
-- because its answer holds no file text.
local function existing(path, anywhere)
  if type(path) ~= "string" or path == "" then
    error("path is required", 0)
  end
  local given = path
  path = resolve(path)
  if not anywhere and not inside_cwd(path) then
    error(("%s is outside the working directory, so the editor tools do not read it."):format(given), 0)
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    error(("No such file: %s"):format(relpath(path)), 0)
  end
  return path
end

-- Wraps an async continuation, so that an error in it still answers.
local function guard(done, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      done(nil, tostring(err))
    end
  end
end

---@type table<integer, true> buffers with show_user marks
local shown = {}

function M.clear()
  for buf in pairs(shown) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  shown = {}
end

local function wrap(text, width)
  local lines = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      if line ~= "" and api.nvim_strwidth(line .. " " .. word) > width then
        lines[#lines + 1] = line
        line = word
      else
        line = line == "" and word or line .. " " .. word
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- The note sits above the range at the range's indent, wrapped to the code window.
local function note_lines(buf, row, note)
  local indent = (api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""):match("^%s*")
  local pad = (" "):rep(api.nvim_buf_call(buf, function()
    return vim.fn.strdisplaywidth(indent)
  end))
  local win = layout.wins.code
  local width = 80
  if win and api.nvim_win_is_valid(win) then
    width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
  end
  local lines = {}
  for i, text in ipairs(wrap(note, math.max(width - #pad - 3, 20))) do
    lines[i] = { { pad }, { i == 1 and "⏺ " or "  ", "AnvimClaude" }, { text, "AnvimNote" } }
  end
  return lines
end

-- Centers the range and its note, or puts the note at the top when the range
-- is taller than the window. Notes above line 1 need topfill to show.
local function reveal(win, first, last, fill)
  local free = api.nvim_win_get_height(win) - (last - first + 1) - fill
  local top = math.max(first - math.floor(math.max(free, 0) / 2), 1)
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = top, topfill = top == first and fill or 0, lnum = first, col = 0 })
  end)
end

local function show_user(params, done)
  local path = existing(params.path, true)
  local buf = follow.load(path)
  local count = api.nvim_buf_line_count(buf)
  local first = math.min(math.max(math.floor(tonumber(params.start_line) or 1), 1), count)
  local last = math.min(math.max(math.floor(tonumber(params.end_line) or first), first), count)
  for row = first - 1, last - 1 do
    api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "AnvimShow", priority = 100 })
  end
  shown[buf] = true
  -- Track first: when following, the code window then shows buf, and the
  -- note wraps to that window's text width.
  follow.track(path, first)
  local note = type(params.note) == "string" and vim.trim(params.note) or ""
  local virt = note ~= "" and note_lines(buf, first - 1, note) or {}
  if #virt > 0 then
    api.nvim_buf_set_extmark(buf, ns, first - 1, 0, { virt_lines = virt, virt_lines_above = true })
  end
  local where = ("%s#L%d%s"):format(relpath(path), first, last > first and ("-%d"):format(last) or "")
  if follow.enabled() then
    reveal(layout.code_win(), first, last, #virt)
    done(("Showed %s to the user."):format(where))
  else
    done(("Marked %s. The user is reading elsewhere, and the statusline points them to it."):format(where))
  end
end

-- Every client of a buffer, also those still starting. Only the package
-- field `_uninitialized` (0.12 and master) lists the starting ones.
local function attached(buf)
  return vim.lsp.get_clients({ bufnr = buf, _uninitialized = true })
end

local function closed(name)
  return ("%s was closed while the editor waited for its language server."):format(name)
end

-- Clients start on FileType, before they initialize. So once every attached
-- client has initialized and none supports the method, no answer will come.
local function with_clients(buf, method, done, cb)
  local start = vim.uv.now()
  local name = relpath(api.nvim_buf_get_name(buf))
  local function check()
    if not api.nvim_buf_is_loaded(buf) then
      return done(nil, closed(name))
    end
    local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
    if #clients > 0 then
      return cb(clients)
    end
    local all = attached(buf)
    local ready = #all > 0 and vim.iter(all):all(function(c)
      return c.initialized
    end)
    local waited = vim.uv.now() - start
    if not ready and waited < M.attach_ms and (#all > 0 or waited < START_MS) then
      return vim.defer_fn(guard(done, check), 50)
    end
    if #all == 0 then
      return cb(nil, ("No language server is attached to %s."):format(name))
    end
    local names = vim.tbl_map(function(c)
      return c.name
    end, all)
    cb(nil, ("No language server for %s supports %s (attached: %s)."):format(name, method, table.concat(names, ", ")))
  end
  check()
end

-- Sends the request to each client and collects the answers until the
-- deadline, so a slow server cannot hold up the reply.
---@param params table|fun(client: vim.lsp.Client): table
---@param deadline integer vim.uv.now() time
---@param cb fun(answers: { client: vim.lsp.Client, result: any }[], errors: string[])
local function request(clients, buf, method, params, deadline, cb)
  local answers, errors, waiting = {}, {}, {}
  local sending, finished = true, false
  local function finish()
    if finished then
      return
    end
    finished = true
    for _, name in pairs(waiting) do
      errors[#errors + 1] = ("%s did not answer in time."):format(name)
    end
    cb(answers, errors)
  end
  for _, client in ipairs(clients) do
    waiting[client.id] = client.name
    local ok = client:request(method, type(params) == "function" and params(client) or params, function(err, result)
      waiting[client.id] = nil
      if err then
        errors[#errors + 1] = ("%s: %s"):format(client.name, err.message or tostring(err))
      elseif result ~= nil then
        answers[#answers + 1] = { client = client, result = result }
      end
      if not sending and next(waiting) == nil then
        finish()
      end
    end, buf)
    if not ok then
      waiting[client.id] = nil
    end
  end
  sending = false
  if next(waiting) == nil then
    finish()
  else
    vim.defer_fn(finish, math.max(deadline - vim.uv.now(), 0))
  end
end

local function nothing(text, errors)
  return #errors > 0 and ("%s %s"):format(text, table.concat(errors, "; ")) or text
end

-- Claude names a symbol, not a column. A whole-word match comes first, so that
-- "take" does not land inside "take_all". The position goes on the last word
-- of the symbol, so "M.take" asks about take.
---@return integer buf, integer row, integer col 0-based
local function locate(params)
  local path = existing(params.path)
  local buf = follow.load(path)
  local lnum, count = tonumber(params.line), api.nvim_buf_line_count(buf)
  if not lnum or lnum < 1 or lnum > count then
    error(("Line %s is outside %s, which has %d lines."):format(tostring(params.line), relpath(path), count), 0)
  end
  local symbol = type(params.symbol) == "string" and vim.trim(params.symbol) or ""
  if symbol == "" then
    error("symbol is required", 0)
  end
  local text = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
  local col = text:find("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]") or text:find(symbol, 1, true)
  if not col then
    error(
      ("%s is not on line %d of %s. The line reads: %s"):format(symbol, lnum, relpath(path), clip(text, MAX_TEXT)),
      0
    )
  end
  local word = symbol:find("[%w_]+[^%w_]*$") or 1
  return buf, lnum - 1, col - 1 + word - 1
end

local function position_params(buf, row, col, extra)
  return function(client)
    local text = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    return vim.tbl_extend("force", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = row, character = vim.str_utfindex(text, client.offset_encoding, col, false) },
    }, extra or {})
  end
end

-- A server may point outside the cwd, into a library. Those lines carry no excerpt.
local function location_lines(answers)
  local lines, seen, inside = {}, {}, {}
  for _, answer in ipairs(answers) do
    local result = answer.result
    if result.uri or result.targetUri then
      result = { result }
    end
    for _, item in ipairs(vim.lsp.util.locations_to_items(result, answer.client.offset_encoding)) do
      local key = ("%s:%d:%d"):format(item.filename, item.lnum, item.col)
      if not seen[key] then
        seen[key] = true
        if inside[item.filename] == nil then
          inside[item.filename] = inside_cwd(item.filename)
        end
        local where = ("%s:%d"):format(relpath(item.filename), item.lnum)
        lines[#lines + 1] = inside[item.filename] and ("%s: %s"):format(where, clip(item.text, MAX_TEXT)) or where
      end
    end
  end
  return lines
end

local function line_range(range)
  local first, last = range.start.line + 1, range["end"].line + 1
  return last > first and ("L%d-%d"):format(first, last) or ("L%d"):format(first)
end

local function symbol_kind(kind)
  return vim.lsp.protocol.SymbolKind[kind] or "Symbol"
end

-- An outline, not every local: the children of functions are left out.
local leaf_kinds = { Function = true, Method = true, Constructor = true }

local function outline(symbols, depth, out)
  for _, s in ipairs(symbols) do
    local kind = symbol_kind(s.kind)
    local range = s.range or (s.location and s.location.range)
    local container = s.containerName and s.containerName ~= "" and (" in " .. s.containerName) or ""
    out[#out + 1] = ("%s%s %s%s  %s"):format(
      ("  "):rep(depth),
      kind,
      s.name,
      container,
      range and line_range(range) or ""
    )
    if s.children and not leaf_kinds[kind] then
      outline(s.children, depth + 1, out)
    end
  end
  return out
end

local function hover_lines(answers)
  local lines = {}
  for _, answer in ipairs(answers) do
    local md = vim.lsp.util.convert_input_to_markdown_lines(answer.result.contents or {})
    while md[#md] and vim.trim(md[#md]) == "" do
      md[#md] = nil
    end
    if #lines > 0 and #md > 0 then
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, md)
  end
  while lines[1] and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  if #lines > MAX_HOVER_LINES then
    local more = #lines - MAX_HOVER_LINES
    lines = vim.list_slice(lines, 1, MAX_HOVER_LINES)
    lines[#lines + 1] = ("... %d more lines"):format(more)
  end
  return lines
end

-- Waits for a client, sends the request, and answers with what format returns.
---@param format fun(answers: table[], errors: string[]): string
local function ask(buf, method, params, done, format)
  local deadline = vim.uv.now() + M.budget_ms
  with_clients(
    buf,
    method,
    done,
    guard(done, function(clients, missing)
      if not clients then
        return done(missing)
      end
      request(
        clients,
        buf,
        method,
        params,
        deadline,
        guard(done, function(answers, errors)
          done(format(answers, errors))
        end)
      )
    end)
  )
end

---@param format fun(answers: table[], params: table, errors: string[]): string
local function lsp_at(method, extra, format)
  return function(params, done)
    local buf, row, col = locate(params)
    ask(buf, method, position_params(buf, row, col, extra), done, function(answers, errors)
      return format(answers, params, errors)
    end)
  end
end

local lsp_definition = lsp_at("textDocument/definition", nil, function(answers, params, errors)
  local lines = location_lines(answers)
  if #lines == 0 then
    return nothing(("No definition found for %s."):format(params.symbol), errors)
  end
  return capped(#lines == 1 and "Defined at " .. lines[1]:match("^(.-:%d+)") or plural(#lines, "definition"), lines)
end)

local lsp_references = lsp_at(
  "textDocument/references",
  { context = { includeDeclaration = true } },
  function(answers, params, errors)
    local lines = location_lines(answers)
    if #lines == 0 then
      return nothing(("No references found for %s."):format(params.symbol), errors)
    end
    return capped(plural(#lines, "reference"), lines)
  end
)

local lsp_hover = lsp_at("textDocument/hover", nil, function(answers, params, errors)
  local lines = hover_lines(answers)
  if #lines == 0 then
    return nothing(("No hover information for %s."):format(params.symbol), errors)
  end
  return table.concat(lines, "\n")
end)

local function lsp_document_symbols(params, done)
  local path = existing(params.path)
  local buf = follow.load(path)
  local doc = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
  ask(buf, "textDocument/documentSymbol", doc, done, function(answers, errors)
    local lines = {}
    for _, answer in ipairs(answers) do
      outline(answer.result, 0, lines)
    end
    if #lines == 0 then
      return nothing(("No symbols found in %s."):format(relpath(path)), errors)
    end
    return capped(plural(#lines, "symbol"), lines)
  end)
end

-- Servers match loosely, so "take" also finds table.unpack. Names that equal
-- the query come first, then names that contain it. The loose matches stay
-- only when nothing better exists.
local function match_rank(name, query)
  name, query = name:lower(), query:lower()
  if name == query or vim.endswith(name, "." .. query) or vim.endswith(name, ":" .. query) then
    return 0
  end
  return name:find(query, 1, true) and 1 or 2
end

local function lsp_workspace_symbols(params, done)
  local query = type(params.query) == "string" and params.query or ""
  local method = "workspace/symbol"
  local clients = vim.lsp.get_clients({ method = method })
  if #clients == 0 then
    return done(
      "No running language server supports workspace symbols. Servers start when a file of their language opens."
    )
  end
  request(
    clients,
    nil,
    method,
    { query = query },
    vim.uv.now() + M.budget_ms,
    guard(done, function(answers, errors)
      local found, seen = {}, {}
      for _, answer in ipairs(answers) do
        for _, s in ipairs(answer.result) do
          local loc = s.location or {}
          local where = loc.uri and relpath(vim.uri_to_fname(loc.uri)) or ""
          if loc.range then
            where = ("%s:%d"):format(where, loc.range.start.line + 1)
          end
          local container = s.containerName and s.containerName ~= "" and (" in " .. s.containerName) or ""
          local line = ("%s %s%s  %s"):format(symbol_kind(s.kind), s.name, container, where)
          if not seen[line] then
            seen[line] = true
            found[#found + 1] = { line = line, rank = match_rank(s.name, query), i = #found }
          end
        end
      end
      table.sort(found, function(a, b)
        return a.rank < b.rank or (a.rank == b.rank and a.i < b.i)
      end)
      local lines = {}
      for _, f in ipairs(found) do
        if f.rank < 2 or found[1].rank == 2 then
          lines[#lines + 1] = f.line
        end
      end
      if #lines == 0 then
        return done(nothing(("No symbols match %q."):format(query), errors))
      end
      done(capped(plural(#lines, "symbol"), lines))
    end)
  )
end

local severities = { "error", "warning", "info", "hint" }

local function diagnostics_text(diags, path)
  local items, inside = {}, {}
  for _, d in ipairs(diags) do
    local name = api.nvim_buf_is_valid(d.bufnr) and vim.bo[d.bufnr].buftype == "" and api.nvim_buf_get_name(d.bufnr)
    if name and name ~= "" and inside[name] == nil then
      inside[name] = inside_cwd(name)
    end
    if name and inside[name] then
      items[#items + 1] = { path = relpath(name), d = d }
    end
  end
  table.sort(items, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.d.lnum < b.d.lnum or (a.d.lnum == b.d.lnum and a.d.col < b.d.col)
  end)
  if #items == 0 then
    return path and ("No diagnostics in %s."):format(relpath(path))
      or "No diagnostics in the open files of the working directory."
  end
  local lines, counts = {}, {}
  for _, item in ipairs(items) do
    local d = item.d
    local severity = severities[d.severity] or "info"
    counts[d.severity] = (counts[d.severity] or 0) + 1
    local source = d.source and (" [%s]"):format((d.source:gsub("%.$", ""))) or ""
    lines[#lines + 1] = ("%s:%d:%d %s: %s%s"):format(
      item.path,
      d.lnum + 1,
      d.col + 1,
      severity,
      clip(d.message, 300),
      source
    )
  end
  local parts = {}
  for severity, word in ipairs(severities) do
    if counts[severity] then
      parts[#parts + 1] = plural(counts[severity], word)
    end
  end
  return capped(("%s: %s"):format(plural(#items, "diagnostic"), table.concat(parts, ", ")), lines)
end

-- Buffers whose diagnostics have settled: a report came, or one full wait
-- passed. A loaded buffer has no diagnostics until its servers report.
---@type table<integer, true>
local settled = {}

local function diagnostics(params, done)
  if params.path == nil then
    return done(diagnostics_text(vim.diagnostic.get()))
  end
  local path = existing(params.path)
  local buf = follow.load(path)
  local name = relpath(path)
  local start = vim.uv.now()
  local function check()
    if not api.nvim_buf_is_loaded(buf) then
      return done(nil, closed(name))
    end
    local waited = vim.uv.now() - start
    if waited >= M.attach_ms then
      settled[buf] = true
    end
    if settled[buf] or (#attached(buf) == 0 and waited >= START_MS) then
      return done(diagnostics_text(vim.diagnostic.get(buf), path))
    end
    vim.defer_fn(guard(done, check), 50)
  end
  check()
end

local handlers = {
  show_user = show_user,
  diagnostics = diagnostics,
  lsp_definition = lsp_definition,
  lsp_references = lsp_references,
  lsp_hover = lsp_hover,
  lsp_document_symbols = lsp_document_symbols,
  lsp_workspace_symbols = lsp_workspace_symbols,
}

function M.handle(ev)
  local replied = false
  local function done(result, err)
    if not replied then
      replied = true
      sidecar.send({ type = "editor_response", req = ev.req, result = result, error = err })
    end
  end
  local handler = handlers[ev.method]
  if not handler then
    return done(nil, ("anvim has no editor tool named %s."):format(tostring(ev.method)))
  end
  guard(done, handler)(ev.params or {}, done)
end

-- The transcript label, such as show_user(a.lua#L12-30) or lsp_references(a.lua:42 take).
function M.label(name, input)
  if type(input) ~= "table" then
    return name
  end
  local path = type(input.path) == "string" and input.path ~= "" and relpath(resolve(input.path))
  local first, last = tonumber(input.start_line), tonumber(input.end_line)
  local arg
  if name == "show_user" and path and first then
    arg = ("%s#L%d%s"):format(path, first, last and last > first and ("-%d"):format(last) or "")
  elseif path and input.line and input.symbol then
    arg = ("%s:%s %s"):format(path, tostring(input.line), tostring(input.symbol))
  else
    arg = path or (type(input.query) == "string" and input.query or nil)
  end
  return arg and ("%s(%s)"):format(name, clip(arg, 80)) or name
end

-- The transcript's result line: the note for show_user, else the first line of the answer.
function M.summary(name, input, text)
  if name == "show_user" and type(input.note) == "string" and vim.trim(input.note) ~= "" then
    return clip(input.note, 1000)
  end
  for line in vim.gsplit(text or "", "\n", { plain = true }) do
    line = vim.trim(line)
    if line ~= "" and not vim.startswith(line, "```") then
      return line
    end
  end
  return "Done"
end

function M.attach()
  set_highlights()
  local group = api.nvim_create_augroup("anvim.tools", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(ev)
      settled[ev.buf] = true
    end,
  })
  api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(ev)
      settled[ev.buf] = nil
    end,
  })
  sidecar.on("editor_request", M.handle)
  -- Marks from show_user last until the user's next prompt starts a turn.
  sidecar.on("turn_start", M.clear)
end

return M
