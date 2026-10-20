-- Reads the user's lazy.lua for init.lua. It parses the text and never runs it,
-- because running it would bootstrap lazy.nvim into anvim's own data dir.
local M = {}

---@return string text The file without comments, or "" if it is missing.
function M.read(path)
  local f = io.open(path)
  if not f then
    return ""
  end
  local text = f:read("*a"):gsub("%-%-%[(=*)%[.-%]%1%]", "")
  f:close()
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    -- A line comment starts the line or follows a space, so "--" in a URL stays.
    lines[#lines + 1] = line:gsub("^%-%-.*", ""):gsub("(%s)%-%-.*", "%1")
  end
  return table.concat(lines, "\n")
end

-- The import names, in order. A line with `enabled = false` or `cond =` is
-- skipped. Specs that spread those over several lines are not detected.
---@return string[]
function M.imports(text)
  local imports = {}
  for line in text:gmatch("[^\n]+") do
    if not (line:find("%f[%w_]enabled%s*=%s*false") or line:find("%f[%w_]cond%s*=")) then
      for name in line:gmatch("import%s*=%s*[\"']([%w._-]+)[\"']") do
        imports[#imports + 1] = name
      end
    end
  end
  return #imports > 0 and imports or { "lazyvim.plugins", "plugins" }
end

---@return string[] names The `performance.rtp.disabled_plugins` list.
function M.disabled_plugins(text)
  local names = {}
  for name in (text:match("disabled_plugins%s*=%s*(%b{})") or ""):gmatch("[\"']([%w._-]+)[\"']") do
    names[#names + 1] = name
  end
  return names
end

return M
