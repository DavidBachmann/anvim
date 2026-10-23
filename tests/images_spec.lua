---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")

local api = vim.api

describe("images", function()
  it("turns a pasted image path into a chip, and the prompt sends the image", function()
    helpers.start()
    local shot = helpers.tmp .. "/Screen Shot.png"
    vim.fn.writefile({ "png" }, shot)
    api.nvim_set_current_win(layout.wins.input)
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
    -- A terminal sends the path in chunks.
    local path = (shot:gsub(" ", "\\ "))
    vim.paste({ path:sub(1, 10) }, 1)
    vim.paste({ path:sub(11) }, 2)
    vim.paste({ "" }, 3)
    vim.paste({ "see", "this" }, -1)
    assert.are.same({ "[Image #1] see", "this" }, api.nvim_buf_get_lines(input.buf(), 0, -1, false))
    helpers.capture_sends(function(sent)
      input.send("[Image #1] see this")
      assert.are.same({ type = "prompt", text = "[Image #1] see this", images = { shot } }, sent[#sent])
      input.send("no image")
      assert.is_nil(sent[#sent].images)
    end)
    input.set_busy(false)
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)
end)
