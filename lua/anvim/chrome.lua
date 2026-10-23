-- Claude in Chrome's tool calls and pages, as Claude Code shows and opens them.
local M = {}

local function cut(text, n)
  return vim.fn.strchars(text) > n and vim.fn.strcharpart(text, 0, n - 1) .. "..." or text
end

-- What Claude Code writes in the parentheses after the tool's name.
---@return string?
local function summary(tool, input)
  local str = function(key)
    return type(input[key]) == "string" and input[key] or nil
  end
  if tool == "navigate" and str("url") then
    return str("url"):match("^%a[%w+.-]*://([^/?#:]+)") or cut(str("url"), 30)
  elseif tool == "find" and str("query") then
    return "pattern: " .. cut(str("query"), 30)
  elseif tool == "computer" and str("action") then
    local action = str("action")
    if action:match("_click$") and action ~= "triple_click" then
      if str("ref") then
        return ("%s on %s"):format(action, str("ref"))
      elseif type(input.coordinate) == "table" then
        return ("%s at (%s)"):format(action, table.concat(input.coordinate, ", "))
      end
    elseif action == "type" and str("text") then
      return ('type "%s"'):format(cut(str("text"), 15))
    elseif action == "key" and str("text") then
      return "key " .. str("text")
    elseif action == "scroll" and str("scroll_direction") then
      return "scroll " .. str("scroll_direction")
    elseif action == "wait" and type(input.duration) == "number" then
      return ("wait %ss"):format(input.duration)
    elseif action == "left_click_drag" then
      return "drag"
    end
    return action
  elseif tool == "gif_creator" then
    return str("action")
  elseif tool == "resize_window" and type(input.width) == "number" and type(input.height) == "number" then
    return ("%dx%d"):format(input.width, input.height)
  elseif tool == "read_console_messages" then
    local parts = {}
    if str("pattern") then
      parts[#parts + 1] = "pattern: " .. cut(str("pattern"), 20)
    end
    if input.onlyErrors == true then
      parts[#parts + 1] = "errors only"
    end
    return #parts > 0 and table.concat(parts, ", ") or nil
  elseif tool == "read_network_requests" and str("urlPattern") then
    return "pattern: " .. cut(str("urlPattern"), 20)
  elseif tool == "shortcuts_execute" and str("shortcutId") then
    return "shortcut_id: " .. str("shortcutId")
  end
end

-- Claude in Chrome[navigate](example.com)
---@param tool string The tool's name without the mcp__claude-in-chrome__ prefix.
---@param input table?
function M.label(tool, input)
  local name = ("Claude in Chrome[%s]"):format((tool:gsub("_mcp$", "")))
  local arg = summary(tool, input or {})
  return arg and ("%s(%s)"):format(name, arg) or name
end

-- Claude Code opens the extension's pages in Chrome, which has the extension.
function M.open(url)
  if vim.fn.has("mac") == 0 then
    vim.ui.open(url)
    return
  end
  vim.system({ "open", "-a", "Google Chrome", url }, {}, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        vim.ui.open(url)
      end)
    end
  end)
end

return M
