-- Loaded with --cmd before init.lua. Records each map that anvim's own code
-- makes, with the kind of buffer it belongs to, so that the stack spec can
-- check that the key view lists them all.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local set = vim.keymap.set

-- anvim's keys.set() and snacks' toggles map through these files for their
-- caller.
local wrappers = { "/lua/anvim/keys.lua", "/snacks/toggle.lua", "/snacks/keymap.lua" }

-- The spec reads them with require("anvim_test_maps").
---@type { mode: string, lhs: string, ctx: string, src: string }[]
local maps = {}
package.loaded["anvim_test_maps"] = maps

-- The file that called vim.keymap.set(), past snacks' wrappers.
local function caller()
  for level = 3, 12 do
    local info = debug.getinfo(level, "S")
    local src = info and info.source:match("^@(.*)")
    if not src then
      return
    end
    local wrapped = vim.iter(wrappers):any(function(file)
      return src:find(file, 1, true) ~= nil
    end)
    if not wrapped then
      return src
    end
  end
end

---@param buf integer?
local function ctx(buf)
  if not buf then
    return "global"
  elseif vim.b[buf].anvim_input then
    return "prompt"
  elseif vim.b[buf].anvim_transcript then
    return "transcript"
  elseif vim.api.nvim_buf_get_name(buf) == "anvim://compose" then
    return "compose"
  elseif vim.bo[buf].filetype == "anvim_keys" then
    return "view"
  elseif vim.bo[buf].buftype == "" then
    return "file"
  end
  return "other"
end

-- blink.cmp maps some of the prompt's insert keys over anvim's at the
-- prompt's first InsertEnter. This autocmd comes before blink's, so it sees
-- anvim's own maps. The spec reads them with require("anvim_test_prompt").
local prompt = {} ---@type table<integer, table<string, string>>
package.loaded["anvim_test_prompt"] = prompt
vim.api.nvim_create_autocmd("InsertEnter", {
  callback = function(ev)
    if vim.b[ev.buf].anvim_input and not prompt[ev.buf] then
      local own = {}
      for _, mode in ipairs({ "n", "x", "o", "i" }) do
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(ev.buf, mode)) do
          own[mode .. " " .. vim.keycode(m.lhs)] = m.desc or ""
        end
      end
      prompt[ev.buf] = own
    end
  end,
})

---@diagnostic disable-next-line: duplicate-set-field
vim.keymap.set = function(mode, lhs, rhs, opts)
  local src = caller()
  if src and (vim.startswith(src, root .. "/lua/") or src == root .. "/init.lua") then
    local buf = opts and opts.buffer
    if buf == true or buf == 0 then
      buf = vim.api.nvim_get_current_buf()
    end
    for _, m in ipairs(type(mode) == "table" and mode or { mode }) do
      maps[#maps + 1] = { mode = m, lhs = lhs, ctx = ctx(buf or nil), src = src }
    end
  end
  return set(mode, lhs, rhs, opts)
end
