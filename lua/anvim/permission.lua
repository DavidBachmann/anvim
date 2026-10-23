-- Permission prompts, questions and plan approval in the Claude column.
-- Claude Code asks before a tool runs (sidecar/src/permissions.ts). The
-- request appears as a block at the bottom of the transcript, and normal mode
-- in the prompt chooses until the user answers. Insert mode never answers, so
-- a user who is typing keeps typing. Requests that arrive meanwhile wait their
-- turn.
local agents = require("anvim.agents")
local input = require("anvim.input")
local layout = require("anvim.layout")
local paths = require("anvim.paths")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

local api = vim.api

-- A choice this soon after a request opens, or after the user's last typed
-- character in the prompt, does nothing. So a key meant for the prompt cannot
-- answer a request.
M.guard_ms = 400

---@class anvim.Choice
---@field label string
---@field desc string?
---@field yes boolean? It approves, so default_to_no blocks it as a single key.
---@field run fun(r: anvim.Request)

---@class anvim.Request
---@field ev table The permission_request event.
---@field kind 'tool'|'question'|'plan'
---@field cursor integer
---@field opened number? When it was first shown, in ms.
---@field block integer? The transcript block.
---@field q integer The question on screen.
---@field answers table<string, string[]>
---@field picked table<integer, boolean> Options picked in a multi-select question.
---@field other string? Typed answer to a multi-select question.

---@type anvim.Request[]
local queue = {}
-- The prompt holds the user's answer instead of a new prompt. Their draft
-- comes back afterwards.
---@type { r: anvim.Request, purpose: 'deny'|'other', draft: string[] }?
local typing
-- Where the user stopped typing in the prompt, before a typed answer moved
-- the cursor. It belongs to the first request in line.
---@type { at: [integer, integer]? }?
local before
-- When the user last typed a character in the prompt, in ms.
local typed = 0

-- The loop's cached time lags behind when other work runs in the same loop
-- iteration, which would shorten the guard.
local function now()
  return vim.uv.hrtime() / 1e6
end

-- Replace mode runs the prompt's insert maps too, <CR> among them.
local function inserting()
  return api.nvim_get_mode().mode:find("^[iR]") ~= nil
end

local titles = {
  Bash = "Bash command",
  Edit = "Edit file",
  MultiEdit = "Edit file",
  Write = "Write file",
  NotebookEdit = "Edit notebook",
  WebFetch = "Fetch",
  WebSearch = "Web search",
  -- A sandboxed command connects to a host that no rule allows yet.
  SandboxNetworkAccess = "Network access",
}

local function first_line(text)
  return (vim.trim(text or ""):gsub("\n.*", "..."))
end

local function in_prompt()
  return layout.wins.input ~= nil and api.nvim_get_current_win() == layout.wins.input
end

local function questions(r)
  return r.ev.input.questions or {}
end

local answer, start_typing, show

local function next_question(r)
  r.q, r.cursor, r.picked, r.other = r.q + 1, 1, {}, nil
  if r.q > #questions(r) then
    answer(r, { behavior = "allow", answers = r.answers })
  else
    show(r)
  end
end

---@return anvim.Choice[]
local function choices(r)
  if r.kind == "plan" then
    local approve = function(label, mode)
      return {
        label = label,
        yes = true,
        run = function()
          answer(r, { behavior = "allow", mode = mode })
        end,
      }
    end
    -- Claude Code's choices. Bypass takes the place of accept edits when the
    -- session started in bypass mode.
    local bypass = vim.tbl_contains(input.modes(), "bypassPermissions")
    return {
      bypass and approve("Yes, and switch to BYPASS PERMISSIONS for this session", "bypassPermissions")
        or approve("Yes, auto-accept edits", "acceptEdits"),
      approve("Yes, manually approve edits", "default"),
      {
        label = "No, keep planning",
        run = function()
          start_typing(r, "deny")
        end,
      },
    }
  elseif r.kind == "question" then
    local q = questions(r)[r.q]
    local list = {}
    for i, opt in ipairs(q.options or {}) do
      list[i] = {
        label = q.multiSelect and ((r.picked[i] and "[x] " or "[ ] ") .. opt.label) or opt.label,
        desc = opt.description,
        run = function()
          if q.multiSelect then
            r.picked[i] = not r.picked[i] or nil
            show(r)
          else
            r.answers[q.question] = { opt.label }
            next_question(r)
          end
        end,
      }
    end
    list[#list + 1] = {
      label = r.other and ("Other: " .. r.other) or "Other (type an answer)",
      run = function()
        start_typing(r, "other")
      end,
    }
    if q.multiSelect then
      list[#list + 1] = {
        label = "Submit",
        run = function()
          local parts = {}
          for i, opt in ipairs(q.options or {}) do
            if r.picked[i] then
              parts[#parts + 1] = opt.label
            end
          end
          parts[#parts + 1] = r.other
          r.answers[q.question] = parts
          next_question(r)
        end,
      }
    end
    return list
  end
  local list = {
    {
      label = "Yes",
      yes = true,
      run = function()
        answer(r, { behavior = "allow" })
      end,
    },
  }
  if r.ev.remember then
    list[2] = {
      label = r.ev.remember,
      yes = true,
      run = function()
        answer(r, { behavior = "allow", remember = true })
      end,
    }
  end
  list[#list + 1] = {
    label = "No, and tell Claude what to do differently (esc twice)",
    run = function()
      start_typing(r, "deny")
    end,
  }
  return list
end

-- Lines and highlights of a block. Each mark is { row, col, end_col, group }.
local function builder()
  local b = { lines = {}, marks = {} }
  function b.add(text, group, col)
    b.lines[#b.lines + 1] = text
    if group then
      b.marks[#b.marks + 1] = { #b.lines - 1, col or 0, #text, group }
    end
  end
  return b
end

local function plan_text(r)
  local plan = r.ev.input.plan
  if type(plan) ~= "string" and type(r.ev.input.planFilePath) == "string" then
    local ok, lines = pcall(vim.fn.readfile, r.ev.input.planFilePath)
    plan = ok and table.concat(lines, "\n") or nil
  end
  return type(plan) == "string" and plan or "(Claude sent no plan text.)"
end

-- Claude Code's plan, indented like the rest of the transcript. Two spaces keep
-- headings, lists and fences valid markdown.
local function add_plan(b, r)
  for _, line in ipairs(vim.split(vim.trim(plan_text(r)), "\n", { plain = true })) do
    b.add(line == "" and "" or "  " .. line)
  end
end

local function inside_cwd(path)
  path = vim.fs.normalize(path)
  for _, dir in ipairs({ state.cwd, vim.uv.fs_realpath(state.cwd) }) do
    dir = vim.fs.normalize(dir)
    if path == dir or vim.startswith(path, dir .. "/") then
      return true
    end
  end
  return false
end

-- The header's first line. A subagent's request names the agent, in its color.
local function add_title(b, title, ev)
  local agent = ev.agent_id and agents.get(ev.agent_id)
  if not agent then
    b.add("  " .. title .. (ev.agent_id and " (subagent)" or ""), "AnvimAsk", 2)
    return
  end
  local who = agents.name(agent) .. (agent.description ~= "" and (" (%s)"):format(agent.description) or "")
  local line = ("  %s · %s"):format(title, who)
  b.add(line)
  b.marks[#b.marks + 1] = { #b.lines - 1, 2, 2 + #title, "AnvimAsk" }
  b.marks[#b.marks + 1] = { #b.lines - 1, #line - #who, #line, agents.group(agent.slot) }
end

local function add_header(b, r)
  local ev = r.ev
  if r.kind == "plan" then
    add_title(b, "Ready to code?", ev)
    b.add("  Here is Claude's plan:")
    add_plan(b, r)
    b.add("  Would you like to proceed?")
    return
  elseif r.kind == "question" then
    local list = questions(r)
    for i = 1, r.q - 1 do
      local q = list[i]
      b.add(("  ✔ %s: %s"):format(q.header or q.question, table.concat(r.answers[q.question] or {}, ", ")), "Comment")
    end
    local q = list[r.q]
    local count = #list > 1 and (" (%d of %d)"):format(r.q, #list) or ""
    add_title(b, ("☐ %s%s"):format(q.header or "Question", count), ev)
    b.add("  " .. q.question)
    return
  end
  local tool, inp = ev.tool, ev.input
  local mcp_server, mcp_tool = tool:match("^mcp__(.-)__(.+)$")
  local title = titles[tool] or ev.title or (mcp_server and "Tool use" or tool)
  if tool == "Bash" and inp.dangerouslyDisableSandbox == true then
    title = "Bash command (unsandboxed)"
  end
  add_title(b, title, ev)
  local path = type(inp.file_path) == "string" and inp.file_path or inp.notebook_path
  -- Its description only asks about the host again, so the block leaves it out.
  if tool == "SandboxNetworkAccess" and type(inp.host) == "string" then
    b.add("    " .. inp.host)
    b.add("  Do you want to allow this connection?")
    return
  elseif tool == "Bash" and type(inp.command) == "string" then
    for _, line in ipairs(vim.split(inp.command, "\n", { plain = true })) do
      b.add("    " .. line)
    end
  elseif type(path) == "string" then
    b.add("    " .. paths.display(path))
  elseif mcp_server then
    b.add(("    %s - %s (MCP)"):format(mcp_server, transcript.label(mcp_tool, inp)))
  else
    b.add("    " .. transcript.label(tool, inp))
  end
  local desc = ev.description
  -- Claude Code describes an edit by the file's name, or by its ~ path outside the cwd.
  local names_path = type(path) == "string"
    and (vim.fs.basename(path) == desc or vim.fn.fnamemodify(path, ":~") == desc)
  if type(desc) == "string" and desc ~= "" and not names_path then
    b.add("    " .. first_line(desc), "Comment")
  end
  -- Claude Code also names paths inside the cwd, such as a directory that
  -- mkdir would create. Only a path outside it needs a warning. anvim's own
  -- guards say why they ask (sidecar/src/sandbox.ts).
  local blocked = ev.blocked_path
  if type(ev.reason) == "string" and ev.reason ~= "" then
    b.add("    " .. first_line(ev.reason), "WarningMsg")
  elseif type(blocked) == "string" and not inside_cwd(blocked) then
    b.add("    outside the working directory: " .. vim.fn.fnamemodify(blocked, ":~"), "WarningMsg")
  end
  local name = type(path) == "string" and vim.fs.basename(path)
  if name and (tool == "Edit" or tool == "MultiEdit") then
    b.add(("  Do you want to make this edit to %s?"):format(name))
  elseif name and tool == "Write" then
    b.add(("  Do you want to %s %s?"):format(vim.uv.fs_stat(path) and "overwrite" or "create", name))
  else
    b.add("  Do you want to proceed?")
  end
end

-- The choice that <Esc> stands for. A question has none, because <Esc>
-- declines all of its questions.
---@return integer?
local function esc_choice(r)
  if r.kind == "plan" then
    return 3
  elseif r.kind == "tool" then
    return #choices(r)
  end
end

local function esc_text(r)
  if r.kind == "plan" then
    return "esc again to keep planning"
  elseif r.kind == "question" then
    return "esc again to decline to answer"
  elseif r.ev.tool == "SandboxNetworkAccess" then
    return "esc again to refuse the connection"
  end
  return "esc again to answer No"
end

local function render(r)
  local b = builder()
  add_header(b, r)
  local armed = input.armed()
  local danger = armed and armed.id == r and esc_choice(r)
  for i, c in ipairs(choices(r)) do
    local text = ("%s%d. %s"):format(i == r.cursor and "  ❯ " or "    ", i, c.label)
    b.add(text, i == danger and "AnvimDanger" or i == r.cursor and "AnvimChoice" or nil, 2)
    if c.desc and c.desc ~= "" then
      b.add("       " .. first_line(c.desc), "Comment")
    end
  end
  return b.lines, b.marks
end

local function hint(r)
  if typing then
    local what = typing.purpose == "other" and "Type your answer"
      or r.kind == "plan" and "Type what to change"
      or "Type what to do instead"
    return what .. " · enter to send · esc twice to go back"
  end
  -- The keys answer only in normal mode in the prompt, so elsewhere the hint
  -- starts with the way there. Going to the prompt while a request waits
  -- leaves it in normal mode (input.resume()).
  local digits = not r.ev.default_to_no and ("1-%d"):format(#choices(r))
  local keys = digits and digits .. " or enter" or "j/k and enter"
  if not in_prompt() then
    return "To answer: go to the prompt, then " .. keys
  elseif inserting() then
    return "To answer: esc to leave insert mode, then " .. keys
  end
  return "To answer: " .. (digits and digits .. ", or j/k and enter" or "j/k and enter")
end

-- The hint for the request on screen, for the current window and mode. The
-- activity line reads it each time Neovim draws the prompt's winbar, which
-- Neovim does after a window change. A mode change marks it (ModeChanged).
---@return string?
function M.hint()
  return queue[1] and hint(queue[1]) or nil
end

local function guarded(r)
  return now() - math.max(r.opened, typed) < M.guard_ms
end

-- A key answers only a request that the user can see. Otherwise it draws the
-- block again and brings it into view, as after read mode or a rebuilt
-- transcript.
local function seen(r)
  if r.block and transcript.block_visible(r.block) then
    return true
  end
  show(r)
  return false
end

local function choose(r, i, by_key)
  local c = choices(r)[i]
  if not c or guarded(r) or not seen(r) then
    return
  end
  if by_key and c.yes and r.ev.default_to_no then
    return
  end
  c.run(r)
end

local function move(r, delta)
  local n = #choices(r)
  r.cursor = (r.cursor - 1 + delta) % n + 1
  show(r)
end

-- The prompt buffer that has the choice keys. Layout repair can make a new one.
---@type integer?
local mapped

local function clear_keys()
  if mapped and api.nvim_buf_is_valid(mapped) then
    for i = 1, 9 do
      pcall(vim.keymap.del, "n", tostring(i), { buffer = mapped })
    end
  end
  mapped = nil
end

local function set_keys()
  local buf = input.buf()
  if mapped == buf then
    return
  end
  clear_keys()
  mapped = buf
  local map = function(lhs, fn)
    require("anvim.keys").set("permission", "n", lhs, function()
      local r = queue[1]
      if r and not typing then
        fn(r)
      end
    end, { buffer = buf })
  end
  for i = 1, 9 do
    map(tostring(i), function(r)
      choose(r, i, true)
    end)
  end
end

-- j, k, <Down> and <Up> in normal mode in the prompt (input.move()). It is
-- false when no request waits, so the key does its usual work.
---@param delta integer
---@return boolean
function M.move(delta)
  local r = queue[1]
  if not r then
    return false
  end
  if not typing then
    move(r, delta)
  end
  return true
end

-- A transcript error must not stop the request: the keys still answer it.
local function safely(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    sidecar.log(("permission %s failed: %s"):format(what, err))
  end
end

-- Only a plan is markdown. The other blocks hold choices such as `[x] Label`.
---@param opts? { quiet: boolean? }
local function draw(r, opts)
  local lines, marks = render(r)
  if not (r.block and transcript.set_block(r.block, lines, marks, opts)) then
    r.block = transcript.block(lines, marks, { quiet = opts and opts.quiet, markdown = r.kind == "plan" })
  end
end

function show(r)
  -- The request changed, so a second <Esc> must not answer it.
  input.disarm()
  safely("block", draw, r)
  if not r.opened then
    r.opened = now()
    -- The screen shows the block once this batch of events is done.
    vim.schedule(function()
      r.opened = now()
    end)
    set_keys()
    input.deselect()
    if not in_prompt() then
      local what = r.kind == "question" and "a question"
        or r.kind == "plan" and "a plan"
        or r.ev.tool == "SandboxNetworkAccess" and "a network request"
        or r.ev.tool
      vim.notify(("Claude is waiting for your answer to %s, in the prompt"):format(what), vim.log.levels.INFO, {
        title = "anvim",
      })
    end
  end
  state.waiting = hint(r)
  input.redraw()
end

local function end_typing()
  if typing then
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, typing.draft)
    typing = nil
  end
end

-- After the last request, the prompt is in normal mode, also when the user
-- was typing before. A typed answer moved the cursor, so it goes back to
-- where the user stopped typing, and an insert command goes on there.
local function restore()
  local at = before and before.at
  before = nil
  if not in_prompt() then
    return
  end
  if inserting() then
    vim.cmd.stopinsert()
    -- The end of insert mode moves the cursor one left, so it goes back after that.
    if at then
      api.nvim_create_autocmd("InsertLeave", {
        buffer = input.buf(),
        once = true,
        callback = function()
          input.stop_at(at)
        end,
      })
    end
  elseif at then
    input.stop_at(at)
  end
end

function start_typing(r, purpose)
  if before and not before.at then
    -- Typing an answer moves the mark of where the user stopped typing.
    before.at = { input.insert_pos() }
  end
  typing = { r = r, purpose = purpose, draft = api.nvim_buf_get_lines(input.buf(), 0, -1, false) }
  api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  if layout.wins.input and api.nvim_win_is_valid(layout.wins.input) then
    api.nvim_set_current_win(layout.wins.input)
    vim.cmd.startinsert()
  end
  show(r)
end

-- Takes the request off the screen. The next one in line shows, if any.
-- After the last one, an answer puts the prompt back as the user had it.
local function close(r, answered)
  for i, other in ipairs(queue) do
    if other == r then
      table.remove(queue, i)
      break
    end
  end
  -- After the removal, so that the disarm draws no block that goes at once.
  input.disarm()
  local was_typing = typing ~= nil and typing.r == r
  if was_typing then
    safely("draft", end_typing)
  end
  -- Leave choice mode before the transcript work, which could fail.
  if not queue[1] then
    clear_keys()
    state.waiting = nil
  end
  if r.block then
    safely("block", transcript.remove_block, r.block)
    r.block = nil
  end
  if queue[1] then
    show(queue[1])
    return
  end
  if answered or was_typing then
    safely("restore", restore)
  end
  before = nil
  input.redraw()
end

local function outcome(r, res)
  local id = r.ev.tool_use_id
  if not id then
    return
  end
  if res.behavior == "deny" then
    transcript.outcome(id, res.message and ("Rejected: " .. first_line(res.message)) or "Rejected", "AnvimToolError")
  elseif r.kind == "question" then
    local parts = {}
    for _, q in ipairs(questions(r)) do
      local given = res.answers[q.question]
      if given and #given > 0 then
        parts[#parts + 1] = ("%s → %s"):format(q.header or q.question, table.concat(given, ", "))
      end
    end
    transcript.outcome(id, #parts > 0 and table.concat(parts, " · ") or "No answer")
  elseif r.kind == "plan" then
    local how = { acceptEdits = "auto-accept edits", bypassPermissions = "bypass permissions" }
    transcript.outcome(id, "Approved, " .. (how[res.mode] or "manually approve edits"))
  end
end

function answer(r, res)
  res.type, res.req = "permission_response", r.ev.req
  sidecar.send(res)
  outcome(r, res)
  -- An approved plan stays in the transcript.
  if r.kind == "plan" and res.behavior == "allow" and r.block then
    local b = builder()
    b.add("  Claude's plan:", "AnvimAsk", 2)
    add_plan(b, r)
    local block = r.block
    r.block = nil
    safely("plan", function()
      transcript.set_block(block, b.lines, b.marks)
      transcript.keep_block(block)
    end)
  end
  close(r, true)
end

-- Ends a typed answer: <CR> sends it, and <Esc> goes back to the choices.
---@param key '<CR>'|'<Esc>'
local function end_answer(r, key)
  local t = assert(typing)
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(input.buf(), 0, -1, false), "\n"))
  end_typing()
  if key == "<Esc>" or (t.purpose == "other" and text == "") then
    show(r)
  elseif t.purpose == "deny" then
    answer(r, { behavior = "deny", message = text ~= "" and text or nil })
  elseif questions(r)[r.q].multiSelect then
    r.other = text
    show(r)
  else
    r.answers[questions(r)[r.q].question] = { text }
    next_question(r)
  end
  -- Typing the answer started insert mode. Back at the choices, end it.
  if queue[1] == r and not typing and inserting() then
    vim.cmd.stopinsert()
  end
end

-- Handles the prompt's <CR> while a request waits. Returns false when there
-- is none, so the key does its usual work. In insert mode, <CR> keeps the
-- prompt as it is: it neither answers nor sends.
---@return boolean
function M.key()
  local r = queue[1]
  if not r then
    return false
  end
  if typing then
    end_answer(r, "<CR>")
  elseif not (inserting() or guarded(r)) then
    choose(r, r.cursor)
  end
  return true
end

-- What <Esc> in normal mode in the prompt does while a request waits
-- (input.escape()). It is false when none waits, and true when the press is
-- done: it left a typed answer, or it does nothing. Otherwise it is the
-- action of a second press, which answers No.
---@return boolean|anvim.EscAction
function M.escape()
  local r = queue[1]
  if not r then
    return false
  end
  if typing then
    end_answer(r, "<Esc>")
    return true
  end
  if inserting() or guarded(r) or not seen(r) then
    return true
  end
  return {
    id = r,
    text = esc_text(r),
    run = function()
      if queue[1] == r and not typing and seen(r) then
        answer(r, { behavior = "deny" })
      end
    end,
    changed = function()
      if queue[1] == r then
        safely("block", draw, r, { quiet = true })
      end
    end,
  }
end

---@return boolean
function M.waiting()
  return queue[1] ~= nil
end

function M.request(ev)
  local kind = ev.tool == "AskUserQuestion" and "question" or ev.tool == "ExitPlanMode" and "plan" or "tool"
  if kind == "question" and #(ev.input.questions or {}) == 0 then
    kind = "tool"
  end
  ---@type anvim.Request
  local r = { ev = ev, kind = kind, cursor = 1, q = 1, answers = {}, picked = {} }
  if ev.default_to_no then
    r.cursor = #choices(r)
  end
  queue[#queue + 1] = r
  if #queue == 1 then
    before = {}
    show(r)
  end
end

function M.cancel(req)
  for _, r in ipairs(queue) do
    if r.ev.req == req then
      close(r)
      return
    end
  end
end

-- Drops every request without an answer, when the turn ends or the sidecar
-- exits. A background agent works on after the turn, so with `turn`, its
-- requests stay.
---@param turn boolean?
function M.cancel_all(turn)
  for i = #queue, 1, -1 do
    local r = queue[i]
    local id = r.ev.agent_id
    local agent = id and agents.get(id)
    -- At a turn's end, an agent that runs on keeps its request, and so does
    -- one that /clear forgot. The others get a no, so no agent waits on a
    -- request that is gone. The sidecar ignores an answer that came too late.
    -- A network request names no agent, and a background agent can send it,
    -- so it stays too.
    local stays = id and (not agent or agent.status == "running") or r.ev.tool == "SandboxNetworkAccess"
    if not (turn and stays) then
      if turn then
        sidecar.send({ type = "permission_response", req = r.ev.req, behavior = "deny" })
      end
      close(r)
    end
  end
end

function M.attach()
  local group = api.nvim_create_augroup("anvim.permission", {})
  api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].anvim_input then
        typed = now()
      end
    end,
  })
  -- A prompt buffer that layout repair made again needs the choice keys, and
  -- a new transcript buffer needs the block.
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if queue[1] and vim.b[ev.buf].anvim_input then
        set_keys()
      elseif queue[1] and vim.b[ev.buf].anvim_transcript then
        vim.schedule(function()
          if queue[1] then
            show(queue[1])
          end
        end)
      end
    end,
  })
  -- Read mode keeps the transcript where the user reads. Leaving it ends read
  -- mode, so bring a waiting request back into view.
  api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if queue[1] and api.nvim_get_current_win() == layout.wins.transcript then
        safely("reveal", transcript.reveal, true)
      end
    end,
  })
  -- The hint names other keys in insert mode. A mode change can come from a
  -- window command, so this only marks the winbar for the next redraw.
  api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      local text = queue[1] and hint(queue[1])
      if text and text ~= state.waiting then
        state.waiting = text
        require("anvim.statusline").refresh()
      end
    end,
  })
  sidecar.on("permission_request", M.request)
  sidecar.on("permission_cancel", function(ev)
    M.cancel(ev.req)
  end)
  sidecar.on("turn_end", function()
    M.cancel_all(true)
  end)
  sidecar.on("exit", function()
    M.cancel_all()
  end)
end

return M
