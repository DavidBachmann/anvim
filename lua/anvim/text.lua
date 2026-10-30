-- Text for one-line places, cut to a width in display cells.
local M = {}

local api = vim.api

-- The longest start of the text, or its end with `from_end`, that takes at
-- most `max` cells. It cuts only between characters, so a wide character
-- that does not fit goes whole.
---@param text string
---@param max integer
---@param from_end boolean?
---@return string
local function take(text, max, from_end)
  local chars = vim.fn.split(text, [[\zs]])
  local used, n = 0, 0
  for i = 1, #chars do
    local w = api.nvim_strwidth(chars[from_end and #chars + 1 - i or i])
    if used + w > max then
      break
    end
    used, n = used + w, i
  end
  return from_end and table.concat(chars, "", #chars - n + 1) or table.concat(chars, "", 1, n)
end

-- The text, cut to `max` cells with an ellipsis at the end.
---@param text string
---@param max integer
---@return string
function M.truncate(text, max)
  if api.nvim_strwidth(text) <= max then
    return text
  end
  return max > 0 and take(text, max - 1):gsub("%s+$", "") .. "…" or ""
end

-- The text, cut to `max` cells with an ellipsis in the middle, so that its
-- start and its end stay.
---@param text string
---@param max integer
---@return string
function M.middle(text, max)
  if api.nvim_strwidth(text) <= max then
    return text
  elseif max < 2 then
    return M.truncate(text, max)
  end
  local tail = take(text, math.ceil((max - 1) / 2), true)
  return take(text, max - 1 - api.nvim_strwidth(tail)) .. "…" .. tail
end

return M
