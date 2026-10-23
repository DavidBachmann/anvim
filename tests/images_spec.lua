---@module "luassert"

local helpers = require("helpers")
local input = require("anvim.input")
local layout = require("anvim.layout")

local api = vim.api

-- A 1x1 transparent PNG.
local PNG_1X1 = "\137PNG\r\n\26\n"
  .. "\0\0\0\13IHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137"
  .. "\0\0\0\10IDATx\156c\0\1\0\0\5\0\1\13\10\45\180"
  .. "\0\0\0\0IEND\174B\96\130"

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
      sent[#sent].id = nil
      assert.are.same({ type = "prompt", text = "[Image #1] see this", images = { shot } }, sent[#sent])
      input.set_busy(false)
      input.send("no image")
      assert.is_nil(sent[#sent].images)
    end)
    input.set_busy(false)
    api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "" })
  end)

  it("sends an image file to the terminal again after it changed on disk", function()
    helpers.start()
    local terminal = require("snacks.image.terminal")
    local saved = { request = terminal.request, terminal = terminal._terminal, env = terminal._env }
    local sent, freed = {}, {}
    terminal.request = function(o)
      if o.t == "f" then
        sent[#sent + 1] = o
      elseif o.a == "d" and o.d == "I" then
        freed[#freed + 1] = o.i
      end
    end
    -- A kitty terminal, already detected, so no query goes to the UI.
    terminal._terminal = { terminal = "kitty", supported = true, placeholders = true }
    terminal._env = { name = "kitty", env = {}, supported = true, placeholders = true }
    -- The specs start snacks without its image module. anvim starts it with the module on.
    local enabled = Snacks.config.image.enabled
    Snacks.config.image.enabled = true
    Snacks.image.setup()
    local png = helpers.tmp .. "/chart.png"
    local function write(mtime)
      local f = assert(io.open(png, "wb"))
      f:write(PNG_1X1)
      f:close()
      vim.uv.fs_utime(png, mtime, mtime)
    end
    local ok, err = pcall(function()
      write(1000)
      api.nvim_set_current_win(layout.wins.code)
      vim.cmd.edit(png)
      assert(
        vim.wait(500, function()
          return #sent == 1
        end),
        "the image was not sent"
      )
      write(2000)
      vim.cmd.checktime()
      assert(
        vim.wait(500, function()
          return #sent == 2
        end),
        "the changed image was not sent again"
      )
      -- A new image, with a new id, and the terminal frees the old one.
      assert.are_not.equal(sent[1].i, sent[2].i)
      assert.are.same({ sent[1].i }, freed)
      vim.cmd.checktime()
      vim.wait(100)
      assert.are.equal(2, #sent, "an unchanged image was sent again")
    end)
    terminal.request, terminal._terminal, terminal._env = saved.request, saved.terminal, saved.env
    Snacks.config.image.enabled = enabled
    api.nvim_win_set_buf(layout.wins.code, api.nvim_create_buf(false, true))
    api.nvim_set_current_win(layout.wins.input)
    assert(ok, err)
  end)
end)
