-- The choices that last from one start to the next, such as the side of the
-- Claude column. They live in one JSON file in anvim's state dir.
local M = {}

M.path = vim.fn.stdpath("state") .. "/prefs.json"

---@type table<string, any>?
local cache
-- The path that the cache holds, because specs move M.path.
local cache_path

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
  if cache_path ~= M.path then
    cache, cache_path = read(), M.path
  end
  return cache[key]
end

-- Another anvim may have made a choice since, so read the file again before
-- writing it.
function M.set(key, value)
  cache, cache_path = read(), M.path
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

-- Changes a key from the value in the file now, so that what another anvim
-- wrote under it stays.
---@param fn fun(value: any): any
function M.update(key, fn)
  M.set(key, fn(read()[key]))
end

return M
