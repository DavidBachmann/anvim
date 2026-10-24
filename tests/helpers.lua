-- Shared setup for the specs. mini.test runs every spec file in one Neovim,
-- so anvim and its replay sidecar start once, on first use.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- A temp project with the fixture file, and a recording rewritten to point at it.
-- Neovim deletes its temp dir on exit. VimLeavePre is no place for cleanup:
-- under `nvim -l` it fires when the script ends, before the cases run.
M.tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(M.tmp, "p")
local fixtures = M.root .. "/tests/fixtures"
vim.fn.writefile(vim.fn.readfile(fixtures .. "/matchparen.lua"), M.tmp .. "/matchparen.lua")
local recording = M.tmp .. "/session.jsonl"
M.recording = recording
local frames = vim.fn.readfile(fixtures .. "/edit-session.jsonl")
for i, frame in ipairs(frames) do
  frames[i] = frame:gsub("/ANVIM_FIXTURE", M.tmp)
end
vim.fn.writefile(frames, recording)
-- No spec reads the user's own Claude Code logins.
require("anvim.accounts").home = M.tmp .. "/home"
vim.fn.mkdir(M.tmp .. "/home", "p")

---@type string? The layout role of the window that had focus after start.
local start_role

-- Starts anvim in the temp project with the replay sidecar, once. A spec can
-- close a window that anvim then opens again, so the role stays true and a
-- window id may not.
---@return string role The layout role of the window that had focus after start, such as "input".
function M.start()
  if start_role then
    return start_role
  end
  vim.cmd.cd(M.tmp)
  -- As in anvim's options. Without a UI, the mode message would go to the test output.
  vim.o.showmode = false
  vim.o.number, vim.o.relativenumber, vim.o.signcolumn = true, true, "yes"
  require("anvim.history").dir = M.tmp .. "/history"
  -- The choices of <leader>u start from none, and no spec keeps them for the next run.
  -- The tool pane starts off, so the tool calls show in the chat. Its own specs turn it on.
  local prefs = require("anvim.prefs")
  prefs.path = vim.fn.tempname() .. "/prefs.json"
  prefs.set("tool_pane", false)
  -- The steps through a Bash call's files go faster than a user's eye needs.
  require("anvim.follow").step_ms = 100
  local anvim = require("anvim")
  anvim.setup({
    permission_mode = "bypassPermissions",
    replay = recording,
    replay_speed = 50,
  })
  anvim.start()
  -- Under nvim -l the explorer's finder never finishes, and snacks shows its
  -- picker anyway once 5 s have passed: at a random point in a later spec.
  -- The specs do not use the tree.
  for _, picker in ipairs(Snacks.picker.get({ source = "explorer", tab = false })) do
    picker:close()
  end
  vim.wait(100)
  local win = vim.api.nvim_get_current_win()
  start_role = "other"
  for role, w in pairs(require("anvim.layout").wins) do
    if w == win then
      start_role = role
    end
  end
  assert(
    vim.wait(5000, function()
      return require("anvim.state").process == "ready"
    end),
    "sidecar not ready"
  )
  return start_role
end

-- Starts anvim once, then clears what earlier specs left: the agents, the session and the transcript.
function M.fresh()
  M.start()
  require("anvim.sidecar").dispatch({ type = "reset" })
  require("anvim.transcript").clear()
end

-- The events of a fixture, with the paths in the temp project. The events
-- that need a real sidecar or change the statusline of other specs stay out.
---@param name string The fixture's name, such as agents-session.
function M.events(name)
  local skip = { commands = true, init = true, status = true, context = true, await_preview = true, effort = true }
  local events = {}
  for _, frame in ipairs(vim.fn.readfile(("%s/tests/fixtures/%s.jsonl"):format(M.root, name))) do
    local json = frame:match("^%d+ (.*)$"):gsub("/ANVIM_FIXTURE", M.tmp)
    local ev = vim.json.decode(json, { luanil = { object = true, array = true } })
    if not skip[ev.type] then
      events[#events + 1] = ev
    end
  end
  return events
end

function M.buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function M.contains(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern) then
      return true
    end
  end
  error(("no line matches %q in:\n%s"):format(pattern, table.concat(lines, "\n")), 2)
end

function M.field(id, name, key, phase, x)
  require("anvim.sidecar").dispatch({
    type = "tool_field",
    id = id,
    name = name,
    key = key,
    phase = phase,
    text = phase == "delta" and x or nil,
    value = phase == "end" and x or nil,
  })
end

function M.hl_groups(buf, ns_name)
  local groups = {}
  local ns = vim.api.nvim_get_namespaces()[ns_name]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local group = mark[4].hl_group or mark[4].line_hl_group
    if group then
      groups[group] = (groups[group] or 0) + 1
    end
  end
  return groups
end

local next_req = 1000

-- Sends an editor request the way the sidecar does, and waits for the answer.
---@return { result: string?, error: string? }
function M.ask(method, params)
  next_req = next_req + 1
  local req, reply = next_req, nil
  M.capture_sends(function(sent)
    require("anvim.sidecar").dispatch({ type = "editor_request", req = req, method = method, params = params })
    assert(
      vim.wait(15000, function()
        for _, msg in ipairs(sent) do
          if msg.type == "editor_response" and msg.req == req then
            reply = msg
            return true
          end
        end
        return false
      end),
      method .. " got no answer"
    )
  end)
  return reply
end

-- Captures what the plugin sends to the sidecar while fn runs.
function M.capture_sends(fn)
  local sidecar = require("anvim.sidecar")
  local sent, send = {}, sidecar.send
  sidecar.send = function(msg)
    sent[#sent + 1] = msg
  end
  local ok, err = pcall(fn, sent)
  sidecar.send = send
  if not ok then
    error(err, 0)
  end
end

return M
