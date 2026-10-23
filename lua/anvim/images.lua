-- Pasted images. A terminal pastes an image as its file's path, such as a
-- clipboard image that it saved to a temp file, or a file dropped on it. In
-- the prompt, that paste becomes a chip such as [Image #1], as in Claude
-- Code, and the prompt sends the image itself with its text.
local M = {}

local EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

---@type table<integer, string> The path of each image, by its number in this session.
local paths = {}
local count = 0

-- The paths in a paste: separated by blanks, with `\ ` for a blank in a
-- name, or in quotes.
---@return string[]
local function split(text)
  local out, word, quote, i = {}, "", nil, 1
  while i <= #text do
    local c = text:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      else
        word = word .. c
      end
    elseif c == "\\" and i < #text then
      i = i + 1
      word = word .. text:sub(i, i)
    elseif c == "'" or c == '"' then
      quote = c
    elseif c:match("%s") then
      if word ~= "" then
        out[#out + 1], word = word, ""
      end
    else
      word = word .. c
    end
    i = i + 1
  end
  if word ~= "" then
    out[#out + 1] = word
  end
  return out
end

local function is_image(path)
  local ext = path:match("%.(%w+)$")
  local stat = ext and EXTENSIONS[ext:lower()] and vim.uv.fs_stat(path)
  return stat and stat.type == "file"
end

-- The chips for a paste of image paths, or nil when the paste holds other text.
---@param text string
---@return string?
function M.chips(text)
  local words = split(vim.trim(text))
  if #words == 0 then
    return
  end
  for i, word in ipairs(words) do
    words[i] = vim.fs.normalize(word)
    if not vim.startswith(words[i], "/") or not is_image(words[i]) then
      return
    end
  end
  local chips = {}
  for _, path in ipairs(words) do
    count = count + 1
    paths[count] = path
    chips[#chips + 1] = ("[Image #%d]"):format(count)
  end
  return table.concat(chips, " ")
end

-- The paths of the images whose chips are in a prompt's text, in order.
---@return string[]
function M.take(text)
  local out, seen = {}, {}
  for n in text:gmatch("%[Image #(%d+)%]") do
    local path = paths[tonumber(n)]
    if path and not seen[path] then
      out[#out + 1], seen[path] = path, true
    end
  end
  return out
end

function M.attach()
  local paste = vim.paste
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.paste = function(lines, phase)
    -- A path comes in one piece. A streamed paste is long text.
    if phase == -1 and vim.bo.filetype == "anvim_input" then
      local chips = M.chips(table.concat(lines, "\n"))
      if chips then
        lines = { chips }
      end
    end
    return paste(lines, phase)
  end
end

return M
