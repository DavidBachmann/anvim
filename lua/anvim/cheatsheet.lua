-- The cheatsheet (<leader>cc): the keys and slash commands that people use
-- most, grouped by task, in the key view's float. The key view stays the full
-- reference. The rows hold Vim notation, so a spec can check each key
-- against keys.lua, and the sheet shows the notation of docs/keys.md.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("anvim.cheatsheet")
-- Spaces between two columns of sections.
local GAP = 3
local MARGIN = 2

---@class anvim.Cheatsheet.Row
---@field [1] string|string[] The keys, in Vim notation. Several show as one chip each.
---@field [2] string The description.
---@field note? string
---@field label? string What the chip shows instead of the keys.

---@type { [1]: string, [2]: anvim.Cheatsheet.Row[] }[]
M.sections = {
  {
    "Talk to Claude",
    {
      { "i", "Write a prompt", note = "(in code too)" },
      { "<CR>", "Send" },
      { "<S-CR>", "New line" },
      { "<C-g>", "Write in a large window" },
      { "@", "Complete a file" },
      { "/", "Complete a slash command" },
      { "c{motion}", "Point at lines", note = "(cc: one line)" },
      { "c", "Point at a selection", note = "(visual)" },
      { "<leader>cb", "Point at the file" },
    },
  },
  {
    "While Claude works",
    {
      { { "<Esc>", "<Esc>" }, "Stop Claude", note = "(a pause between)" },
      { "<C-c>", "Stop Claude at once" },
      { "<Up>", "Take queued prompts back" },
      { "<C-b>", "Background agents and Bash" },
      { "<S-Tab>", "Cycle the permission mode" },
      { "<C-o>", "Toggle whole tool calls" },
      { "<leader>us", "Toggle the tool pane" },
      { "<leader>ut", "Toggle the todo window" },
    },
  },
  {
    "Follow and review",
    {
      { "<leader>j", "Jump to where Claude is" },
      { "<C-f>", "Follow the next agent" },
      {
        { "<leader>c0", "<leader>c1", "<leader>c2", "<leader>c3", "<leader>c4" },
        "Follow Claude or agent 1-4",
        label = "<leader>c0-4",
      },
      { "<leader>ca", "The Agent Overview" },
      { "<leader>cf", "Claude's last files" },
      { "<leader>ct", "Claude's trail" },
      { "<leader>cr", "Read the transcript" },
      { "<leader>cy", "Copy Claude's last reply" },
    },
  },
  {
    "Requests and away",
    {
      { "1-9", "Choose that option" },
      { "<CR>", "Choose the highlighted option" },
      { { "<Esc>", "<Esc>" }, "No", note = "(a pause between)" },
      { "/away", "Away mode: hold requests" },
      { "/held", "What anvim held for you" },
    },
  },
  {
    "Sessions",
    {
      { "<leader>cs", "Resume a session" },
      { "/clear", "New session, same todo list" },
      { "/reset", "New session and todo list" },
      { "/rewind", "Rewind to before a prompt" },
      { "<leader>cm", "Choose the model" },
      { "/effort", "Set the effort level" },
      { "/account", "Switch the Claude account" },
      { "<leader>cR", "Restart Claude" },
    },
  },
  {
    "Look around",
    {
      { "<leader><space>", "Find files" },
      { "<leader>/", "Grep the files" },
      { "<leader>e", "Toggle the explorer" },
      { "<leader>gs", "Git status" },
      { "/status", "Login, model and session" },
      { "/usage", "Plan limits" },
      { "/context", "What fills the context" },
      { "/mcp", "MCP servers" },
      { "<leader>cp", "The running processes" },
    },
  },
}

-- Text in backticks shows in the key color.
local TIPS = {
  "A reference looks like `@src/app.lua#L12-30`",
  "`anvim --amnesia` starts with fresh eyes",
}

local MODS = { C = "Ctrl", S = "Shift", M = "Alt", A = "Alt" }
local NAMES = { CR = "Enter" }

-- Vim notation as docs/keys.md writes it: <C-g> is Ctrl-G, <S-CR> is
-- Shift-Enter. <leader> and <space> stay.
---@param lhs string
local function notation(lhs)
  return (
    lhs:gsub("<([^<>]+)>", function(inner)
      if inner == "leader" or inner == "space" then
        return
      end
      local parts = {}
      while inner:match("^%a%-.") and MODS[inner:sub(1, 1):upper()] do
        parts[#parts + 1] = MODS[inner:sub(1, 1):upper()]
        inner = inner:sub(3)
      end
      parts[#parts + 1] = NAMES[inner] or (#parts > 0 and #inner == 1 and inner:upper()) or inner
      return table.concat(parts, "-")
    end)
  )
end

-- The chips of a row, in the sheet's notation.
---@param row anvim.Cheatsheet.Row
---@return string[]
local function chips(row)
  if row.label then
    return { notation(row.label) }
  end
  local keys = row[1]
  if type(keys) == "string" then
    keys = { keys }
  end
  return vim.tbl_map(notation, keys)
end

local w = api.nvim_strwidth

---@param list string[]
local function chips_width(list)
  local width = 0
  for _, chip in ipairs(list) do
    width = width + w(chip) + 2
  end
  return width + #list - 1
end

---@class anvim.Cheatsheet.Block
---@field name string
---@field rows { chips: string[], desc: string, note: string? }[]

---@return anvim.Cheatsheet.Block[]
local function blocks()
  return vim.tbl_map(function(section)
    local rows = vim.tbl_map(function(row)
      return { chips = chips(row), desc = row[2], note = row.note }
    end, section[2])
    return { name = section[1], rows = rows }
  end, M.sections)
end

-- The blocks in rows of `n`. The blocks of a column share its key width, so
-- their descriptions line up.
---@return { key: integer, width: integer }[] cols, integer width
local function grid(list, n)
  local cols = {}
  for i, block in ipairs(list) do
    local c = (i - 1) % n + 1
    cols[c] = cols[c] or { key = 0, desc = 0, head = 0 }
    local col = cols[c]
    col.head = math.max(col.head, w(block.name))
    for _, row in ipairs(block.rows) do
      col.key = math.max(col.key, chips_width(row.chips))
      col.desc = math.max(col.desc, 1 + w(row.desc) + (row.note and 1 + w(row.note) or 0))
    end
  end
  local total = 2 * MARGIN + GAP * (n - 1)
  for _, col in ipairs(cols) do
    col.width = math.max(col.head, col.key + col.desc)
    total = total + col.width
  end
  return cols, total
end

---@return string[] lines, { [1]: integer, [2]: integer, [3]: integer, [4]: string|string[] }[] marks
local function render(max_width)
  local list = blocks()
  local n = 3
  local cols, total = grid(list, n)
  while total > max_width and n > 1 do
    n = n - 1
    cols, total = grid(list, n)
  end
  local lines, marks = { "" }, {}
  local text, line ---@type string, integer
  local function start()
    text = (" "):rep(MARGIN)
    lines[#lines + 1] = text
    line = #lines
  end
  local function add(s, hl)
    if hl and s ~= "" then
      marks[#marks + 1] = { line - 1, #text, #text + #s, hl }
    end
    text = text .. s
    lines[line] = text
  end
  local key = { "AnvimSheetChip", "AnvimSheetKey" }
  for first = 1, #list, n do
    local height = 0
    for i = first, math.min(first + n - 1, #list) do
      height = math.max(height, #list[i].rows)
    end
    for r = -1, height do
      start()
      for i = first, math.min(first + n - 1, #list) do
        local block, c = list[i], i - first + 1
        local col = cols[c]
        if c > 1 then
          add((" "):rep(GAP))
        end
        local at = w(text)
        local row = block.rows[r]
        if r == -1 then
          add(block.name, { "AnvimClaude", "AnvimSheetHeading" })
        elseif r == 0 then
          add(("─"):rep(col.width), "AnvimRule")
        elseif row then
          add((" "):rep(col.key - chips_width(row.chips)))
          for k, chip in ipairs(row.chips) do
            add(k > 1 and " " or "")
            add(" " .. chip .. " ", key)
          end
          add(" " .. row.desc)
          if row.note then
            add(" ")
            add(row.note, "Comment")
          end
        end
        add((" "):rep(col.width - (w(text) - at)))
      end
      lines[line] = text:gsub("%s+$", "")
    end
    lines[#lines + 1] = ""
  end
  -- The tips share a line when they fit.
  local joined = table.concat(TIPS, " · ")
  local tips = w((joined:gsub("`", ""))) + 2 * MARGIN <= total and { joined } or TIPS
  for _, tip in ipairs(tips) do
    start()
    for i, part in ipairs(vim.split(tip, "`", { plain = true })) do
      add(part, i % 2 == 0 and "AnvimSheetKey" or "Comment")
    end
  end
  return lines, marks
end

---@type anvim.KeyView.Draw
local function draw(buf)
  local status = vim.o.laststatus > 0 and 1 or 0
  local bottom = vim.o.lines - vim.o.cmdheight - status
  local lines, marks = render(vim.o.columns - 2)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, w(l))
  end
  width = math.min(width + MARGIN, vim.o.columns - 2)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  local height = math.max(1, math.min(#lines, bottom - 2))
  local footer = { { " q", "WhichKey" }, { " close · ", "WhichKeySeparator" } }
  if height < #lines then
    vim.list_extend(footer, { { "j k", "WhichKey" }, { " scroll · ", "WhichKeySeparator" } })
  end
  vim.list_extend(footer, { { "<leader>?", "WhichKey" }, { " every key ", "WhichKeySeparator" } })
  return {
    relative = "editor",
    row = math.max(0, math.floor((bottom - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    border = "rounded",
    title = { { " anvim cheatsheet · <leader> is Space ", "WhichKeyTitle" } },
    title_pos = "left",
    footer = footer,
    footer_pos = "center",
    style = "minimal",
    zindex = 200,
  }
end

---@param opts? { insert: boolean? } The prompt was in insert mode.
function M.open(opts)
  require("anvim.keyview").show(draw, opts)
end

return M
