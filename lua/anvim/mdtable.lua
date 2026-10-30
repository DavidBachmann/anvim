-- Markdown tables drawn as boxes that fit a width, as Claude Code draws them
-- in a terminal. Text wraps inside each cell.
local M = {}

local strwidth = vim.api.nvim_strwidth

-- The cells of a table row, untrimmed. Only `\|` keeps a pipe in a cell, as
-- in GFM, also inside a code span.
---@param line string
---@return string[]
function M.cells(line)
  line = vim.trim(line):gsub("^|", "")
  local cells, start, i = {}, 1, 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "|" then
      cells[#cells + 1] = line:sub(start, i - 1)
      start = i + 1
    end
    i = i + 1
  end
  -- A row without its closing pipe still has its last cell.
  if start <= #line then
    cells[#cells + 1] = line:sub(start)
  end
  return cells
end

function M.is_row(line)
  return line:find("^%s*|") ~= nil
end

-- The alignment of each column, if `line` is a delimiter row.
---@return ("left"|"center"|"right")[]?
function M.delimiter(line)
  if not M.is_row(line) then
    return nil
  end
  local aligns = {}
  for i, cell in ipairs(M.cells(line)) do
    local left, right = vim.trim(cell):match("^(:?)%-+(:?)$")
    if not left then
      return nil
    end
    aligns[i] = left ~= "" and right ~= "" and "center" or right ~= "" and "right" or "left"
  end
  return #aligns > 0 and aligns or nil
end

---@class anvim.mdtable.Text
---@field text string
---@field spans { [1]: integer, [2]: integer, [3]: string }[] 0-based byte ranges, end exclusive, and their groups.

-- An `_` after a word character never opens emphasis, and one before a word
-- character never closes it.
local function word(c)
  return c ~= "" and c:find("^[%w\128-\255]") ~= nil
end

-- The end of the emphasis that `mark` opens at byte i, if it opens one.
local function emphasis_end(s, i, mark)
  local c = mark:sub(1, 1)
  local after = s:sub(i + #mark, i + #mark)
  if after == "" or after:find("^%s") or (c == "_" and word(s:sub(i - 1, i - 1))) then
    return nil
  end
  local j = i + #mark + 1
  while true do
    j = s:find(mark, j, true)
    if not j then
      return nil
    end
    local before, behind = s:sub(j - 1, j - 1), s:sub(j + #mark, j + #mark)
    -- A single marker is not half of a double one.
    local whole = #mark == 2 or (behind ~= c and before ~= c)
    if whole and not before:find("^%s") and not (c == "_" and word(behind)) then
      return j
    end
    j = j + 1
  end
end

local function with(groups, group)
  return vim.list_extend(vim.list_slice(groups), { group })
end

-- Appends the inline markdown of `s` to `out`, without its markers.
---@param out { parts: string[], len: integer, spans: table[] }
---@param groups string[] The groups of the text around `s`.
local function inline(s, out, groups)
  local function emit(text, group)
    if text == "" then
      return
    end
    for _, g in ipairs(group and with(groups, group) or groups) do
      out.spans[#out.spans + 1] = { out.len, out.len + #text, g }
    end
    out.parts[#out.parts + 1] = text
    out.len = out.len + #text
  end
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" and s:sub(i + 1, i + 1):find("^%p") then
      emit(s:sub(i + 1, i + 1))
      i = i + 2
    elseif c == "`" then
      local ticks = s:match("^`+", i)
      local close = s:find(ticks, i + #ticks, true)
      -- A longer run of backticks does not close the span.
      while close and s:sub(close + #ticks, close + #ticks) == "`" do
        close = s:find(ticks, s:match("^`+()", close), true)
      end
      if close then
        local code = s:sub(i + #ticks, close - 1)
        if code:find("^ .*[^ ].* $") then
          code = code:sub(2, -2)
        end
        code = code:gsub("\\|", "|")
        emit(code, "@markup.raw.markdown_inline")
        i = close + #ticks
      else
        emit(ticks)
        i = i + #ticks
      end
    elseif c == "*" or c == "_" then
      local mark = s:sub(i + 1, i + 1) == c and c .. c or c
      local close = emphasis_end(s, i, mark)
      if close then
        local group = #mark == 2 and "@markup.strong.markdown_inline" or "@markup.italic.markdown_inline"
        inline(s:sub(i + #mark, close - 1), out, with(groups, group))
        i = close + #mark
      else
        emit(mark)
        i = i + #mark
      end
    elseif c == "[" and s:find("^%[[^%]]*%]%([^%)]*%)", i) then
      local text, stop = s:match("^%[([^%]]*)%]%([^%)]*%)()", i)
      inline(text, out, with(groups, "@markup.link.label.markdown_inline"))
      i = stop
    else
      local stop = s:find("[\\`*_%[]", i + 1) or #s + 1
      emit(s:sub(i, stop - 1))
      i = stop
    end
  end
end

-- A cell's text without its markers, and the groups of its spans.
---@param s string
---@param bold boolean? For a header cell.
---@return anvim.mdtable.Text
local function cell_text(s, bold)
  local out = { parts = {}, len = 0, spans = {} }
  inline(vim.trim(s), out, bold and { "@markup.strong.markdown_inline" } or {})
  return { text = table.concat(out.parts), spans = out.spans }
end

-- The characters of `s` from byte `from` to byte `to`, with their widths.
local function chars(s, from, to)
  local list = {}
  for pos, char in s:sub(from, to):gmatch("()([%z\1-\127\192-\255][\128-\191]*)") do
    list[#list + 1] = { from + pos - 1, from + pos - 2 + #char, strwidth(char) }
  end
  return list
end

-- Wraps a cell's text at word boundaries, and breaks a word only where it is
-- wider than the column.
---@return { [1]: integer, [2]: integer }[] lines 1-based byte ranges of `text`.
local function wrap(text, width)
  local lines = {}
  local first, last
  for from, to in text:gmatch("()%S+()") do
    to = to - 1
    if first and strwidth(text:sub(first, to)) <= width then
      last = to
    else
      if first then
        lines[#lines + 1] = { first, last }
        first = nil
      end
      if strwidth(text:sub(from, to)) <= width then
        first, last = from, to
      else
        local used = 0
        for _, ch in ipairs(chars(text, from, to)) do
          if first and used + ch[3] > width then
            lines[#lines + 1] = { first, last }
            first, used = nil, 0
          end
          first, last, used = first or ch[1], ch[2], used + ch[3]
        end
      end
    end
  end
  if first then
    lines[#lines + 1] = { first, last }
  end
  return lines
end

local function longest_word(text)
  local longest = 0
  for chunk in text:gmatch("%S+") do
    longest = math.max(longest, strwidth(chunk))
  end
  return longest
end

-- Each column's width. Columns that fit whole keep their width. Otherwise
-- each column gets at least its longest word, up to a fair share, and the
-- rest goes to the columns in proportion to what they still lack.
---@param rows anvim.mdtable.Text[][]
---@return integer[]?
local function widths(rows, n, room)
  local natural, least = {}, {}
  for c = 1, n do
    natural[c], least[c] = 1, 1
    for _, row in ipairs(rows) do
      natural[c] = math.max(natural[c], strwidth(row[c].text))
      least[c] = math.max(least[c], longest_word(row[c].text))
    end
  end
  local total = 0
  for c = 1, n do
    total = total + natural[c]
  end
  if total <= room then
    return natural
  end
  -- Two cells hold any character, also a wide one.
  local share = math.floor(room / n)
  if share < 2 then
    return nil
  end
  local out, used, lack = {}, 0, 0
  for c = 1, n do
    out[c] = math.min(natural[c], math.max(math.min(least[c], share), 2))
    used = used + out[c]
    lack = lack + natural[c] - out[c]
  end
  local rest = room - used
  local given = 0
  for c = 1, n do
    local more = math.floor(rest * (natural[c] - out[c]) / lack)
    out[c], given = out[c] + more, given + more
  end
  -- The cells that rounding left go to the columns that lack the most.
  while given < rest do
    local best
    for c = 1, n do
      if out[c] < natural[c] and (not best or natural[c] - out[c] > natural[best] - out[best]) then
        best = c
      end
    end
    out[best], given = out[best] + 1, given + 1
  end
  return out
end

---@alias anvim.mdtable.Mark { [1]: integer, [2]: integer, [3]: integer, [4]: string } 0-based row, byte columns and group.

-- Draws the rows of a table, its header and delimiter rows first, in at most
-- `width` cells. Returns nil when the columns do not fit.
---@param raw string[]
---@param width integer
---@return string[]? lines, anvim.mdtable.Mark[] marks
function M.render(raw, width)
  local aligns = M.delimiter(raw[2] or "")
  local n = aligns and #aligns or 0
  if n == 0 or #M.cells(raw[1]) ~= n then
    return nil, {}
  end
  local rows = {}
  for r, line in ipairs(raw) do
    if r ~= 2 then
      local cells, row = M.cells(line), {}
      for c = 1, n do
        row[c] = cell_text(cells[c] or "", r == 1)
      end
      rows[#rows + 1] = row
    end
  end
  -- Each column has a border and a space on each side, and the last border.
  local cols = widths(rows, n, width - 3 * n - 1)
  if not cols then
    return nil, {}
  end
  local lines, marks = {}, {}
  local border = "AnvimTableBorder"
  local function rule(left, mid, right)
    local parts = {}
    for c = 1, n do
      parts[c] = ("─"):rep(cols[c] + 2)
    end
    local line = left .. table.concat(parts, mid) .. right
    marks[#marks + 1] = { #lines, 0, #line, border }
    lines[#lines + 1] = line
  end
  local wrapped = {}
  for r, row in ipairs(rows) do
    wrapped[r] = {}
    for c = 1, n do
      wrapped[r][c] = wrap(row[c].text, cols[c])
    end
  end
  local tall = false
  for r = 2, #rows do
    for c = 1, n do
      tall = tall or #wrapped[r][c] > 1
    end
  end
  local bar = "│"
  local function draw(r)
    local height = 1
    for c = 1, n do
      height = math.max(height, #wrapped[r][c])
    end
    for l = 1, height do
      local line = ""
      for c = 1, n do
        local cell = rows[r][c]
        local range = wrapped[r][c][l]
        local text = range and cell.text:sub(range[1], range[2]) or ""
        local pad = cols[c] - strwidth(text)
        local left = aligns[c] == "right" and pad or aligns[c] == "center" and math.floor(pad / 2) or 0
        marks[#marks + 1] = { #lines, #line, #line + #bar, border }
        line = line .. bar .. " " .. (" "):rep(left)
        if range then
          for _, span in ipairs(cell.spans) do
            local from, to = math.max(span[1], range[1] - 1), math.min(span[2], range[2])
            if from < to then
              marks[#marks + 1] = { #lines, #line + from - range[1] + 1, #line + to - range[1] + 1, span[3] }
            end
          end
        end
        line = line .. text .. (" "):rep(pad - left + 1)
      end
      marks[#marks + 1] = { #lines, #line, #line + #bar, border }
      lines[#lines + 1] = line .. bar
    end
  end
  rule("┌", "┬", "┐")
  draw(1)
  rule("├", "┼", "┤")
  for r = 2, #rows do
    if r > 2 and tall then
      rule("├", "┼", "┤")
    end
    draw(r)
  end
  rule("└", "┴", "┘")
  return lines, marks
end

return M
