---@module "luassert"

local helpers = require("helpers")

describe("keys", function()
  -- The key view lists the keys of keys.lua, so a map made elsewhere would be
  -- missing from it.
  it("maps keys only through keys.lua", function()
    local files = vim.fn.globpath(helpers.root, "lua/**/*.lua", true, true)
    files[#files + 1] = helpers.root .. "/init.lua"
    local found = {}
    for _, file in ipairs(files) do
      if not vim.endswith(file, "/lua/anvim/keys.lua") then
        for n, line in ipairs(vim.fn.readfile(file)) do
          if line:find("keymap%.set") or line:find("nvim_set_keymap") or line:find("nvim_buf_set_keymap") then
            found[#found + 1] = ("%s:%d"):format(file:sub(#helpers.root + 2), n)
          end
        end
      end
    end
    assert.are.same({}, found)
  end)
end)
