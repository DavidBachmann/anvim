-- Claude's trail: the files and ranges that Claude read, edited, wrote and
-- showed, and the user's own references, in a picker with the newest first.
local bashread = require("anvim.bashread")
local context = require("anvim.context")
local state = require("anvim.state")

local M = {}

local api = vim.api
local MAX = 500

---@class anvim.TrailEntry
---@field what 'Read'|'Edit'|'Write'|'Show'|'You'
---@field path string absolute
---@field first integer?
---@field last integer?
---@field note string?

---@type anvim.TrailEntry[] oldest first
local entries = {}
---@type table<string, anvim.TrailEntry> edits by tool id, which get their lines from the result
local edits = {}

local groups = {
  Read = "AnvimToolPending",
  Edit = "AnvimToolOk",
  Write = "AnvimToolOk",
  Show = "AnvimClaude",
  You = "AnvimPrompt",
}

local function resolve(path)
  path = vim.fs.normalize(path)
  if vim.fn.isabsolutepath(path) == 0 then
    path = vim.fs.joinpath(state.cwd, path)
  end
  return vim.fs.normalize(path)
end

---@return anvim.TrailEntry?
local function add(what, path, first, last, note)
  if type(path) ~= "string" or path == "" then
    return
  end
  first = tonumber(first)
  last = first and math.max(tonumber(last) or first, first)
  local entry = { what = what, path = resolve(path), first = first, last = last }
  if type(note) == "string" and vim.trim(note) ~= "" then
    entry.note = vim.trim(note):gsub("%s+", " ")
  end
  entries[#entries + 1] = entry
  if #entries > MAX then
    table.remove(entries, 1)
  end
  return entry
end

function M.tool_use(ev)
  local input = type(ev.input) == "table" and ev.input or {}
  if ev.name == "Read" or ev.name == "Bash" then
    for _, read in ipairs(bashread.reads(ev)) do
      add("Read", read.path, read.first, read.last)
    end
  elseif ev.name == "Edit" or ev.name == "Write" then
    edits[ev.id] = add(ev.name, input.file_path)
  elseif ev.name == "NotebookEdit" then
    add("Edit", input.notebook_path)
  elseif ev.name == "mcp__anvim__show_user" then
    add("Show", input.path, input.start_line, input.end_line, input.note)
  end
end

-- The changed lines of an edit's first hunk.
function M.tool_result(ev)
  local entry = edits[ev.id]
  edits[ev.id] = nil
  local patch = entry and type(ev.result) == "table" and ev.result.structuredPatch
  local hunk = type(patch) == "table" and patch[1]
  if type(hunk) ~= "table" or not tonumber(hunk.newStart) then
    return
  end
  local line, first, last = tonumber(hunk.newStart), nil, nil
  for _, text in ipairs(hunk.lines or {}) do
    local c = text:sub(1, 1)
    if c == "+" or c == "-" then
      first, last = first or line, line
    end
    if c ~= "-" then
      line = line + 1
    end
  end
  entry.first, entry.last = first, last and math.max(last, first)
end

-- The references in a prompt's text.
function M.prompt(text)
  for start, ref in text:gmatch("()@(%S+)") do
    if start == 1 or text:sub(start - 1, start - 1):match("%s") then
      local file, first, last = ref:match("^(.-)#L(%d+)%-?(%d*)")
      file = file or (ref:gsub("[%.,;:!?%)]+$", ""))
      local stat = vim.uv.fs_stat(resolve(file))
      if stat and stat.type == "file" then
        add("You", file, first, last ~= "" and last or first)
      end
    end
  end
end

local function line_length(path, lnum)
  local buf = vim.fn.bufnr(path)
  if buf > 0 and api.nvim_buf_is_loaded(buf) then
    return #(api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "")
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", lnum)
  return ok and #(lines[lnum] or "") or 0
end

-- Picker items, newest first, each place once.
function M.items()
  local items, seen = {}, {}
  local transcript = require("anvim.transcript")
  for i = #entries, 1, -1 do
    local e = entries[i]
    local key = table.concat({ e.what, e.path, e.first or 0, e.last or 0 }, ":")
    if not seen[key] and vim.uv.fs_stat(e.path) then
      seen[key] = true
      local where = transcript.relpath(e.path) .. (e.first and context.range(e.first, e.last) or "")
      items[#items + 1] = {
        text = table.concat({ e.what, where, e.note }, " "),
        file = e.path,
        pos = e.first and { e.first, 0 },
        end_pos = e.last and { e.last, line_length(e.path, e.last) },
        what = e.what,
        where = where,
        note = e.note,
      }
    end
  end
  return items
end

-- Opens a place in the code window and puts the cursor there.
function M.open(item)
  local follow = require("anvim.follow")
  local layout = require("anvim.layout")
  local buf = follow.load(item.file)
  local first = item.pos and item.pos[1] or 1
  follow.show(buf, first)
  local win = layout.code_win()
  api.nvim_set_current_win(win)
  if item.end_pos then
    local rows = {}
    for row = first - 1, item.end_pos[1] - 1 do
      rows[#rows + 1] = row
    end
    api.nvim_win_call(win, function()
      vim.cmd("normal! zz")
    end)
    follow.flash(buf, rows, "AnvimRead", 600)
  end
end

function M.pick()
  Snacks.picker.pick({
    source = "anvim_trail",
    title = "Claude's trail",
    items = M.items(),
    format = function(item)
      local ret = {
        { ("%-5s "):format(item.what), groups[item.what] },
        { item.where, "SnacksPickerFile" },
      }
      if item.note then
        ret[#ret + 1] = { "  " .. item.note, "Comment" }
      end
      return ret
    end,
    preview = "file",
    -- Without a query, the newest place stays on top.
    sort = { fields = { "score:desc", "idx" } },
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          M.open(item)
        end)
      end
    end,
  })
end

function M.attach(sidecar)
  sidecar.on("tool_use", M.tool_use)
  sidecar.on("tool_result", M.tool_result)
  require("anvim.keys").set("claude", "n", "<leader>ct", M.pick)
  api.nvim_create_user_command("AnvimTrail", M.pick, { desc = "Pick a place from Claude's trail" })
end

return M
