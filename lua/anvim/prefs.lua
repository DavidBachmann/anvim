-- The choices that last from one start to the next, such as the side of the
-- Claude column. They live in one JSON file in anvim's state dir.
local M = {}

M.path = vim.fn.stdpath("state") .. "/prefs.json"

---@type table<string, any>?
local cache

---@return table<string, any>
local function read()
  local f = io.open(M.path, "r")
  if not f then
    return {}
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or {}
end

function M.get(key)
  cache = cache or read()
  return cache[key]
end

-- Another anvim may have made a choice since, so read the file again before
-- writing it.
function M.set(key, value)
  cache = read()
  cache[key] = value
  vim.fn.mkdir(vim.fs.dirname(M.path), "p")
  local tmp = M.path .. ".tmp"
  local f = io.open(tmp, "w")
  if f then
    f:write(vim.json.encode(cache))
    f:close()
    os.rename(tmp, M.path)
  end
end

return M
