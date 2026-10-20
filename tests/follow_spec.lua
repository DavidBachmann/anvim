---@module "luassert"

local follow = require("anvim.follow")
local helpers = require("helpers")
local layout = require("anvim.layout")
local sidecar = require("anvim.sidecar")

-- The catch-up on entering the prompt waits for the event loop.
local function shows(path)
  return vim.wait(1000, function()
    local win = layout.wins.code
    return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == vim.fn.bufnr(path)
  end)
end

describe("follow", function()
  it("points the statusline at Claude when not following, and focus catches up", function()
    helpers.start()
    local file = helpers.tmp .. "/follow.lua"
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a" }, file)
    vim.api.nvim_set_current_win(layout.wins.code)
    local before = vim.api.nvim_win_get_buf(layout.wins.code)
    sidecar.dispatch({ type = "tool_use", id = "r1", name = "Read", input = { file_path = file, offset = 3 } })
    assert.are.same(before, vim.api.nvim_win_get_buf(layout.wins.code), "code window stays put")
    local status = follow.status()
    assert(status:find("⏺ Claude at follow.lua:3", 1, true), status)
    layout.focus_input()
    assert(shows(file), "focusing the input catches up")
    assert.are.same(3, vim.api.nvim_win_get_cursor(layout.wins.code)[1])
    assert.are.same("◉ following", follow.status())
  end)

  it("gives a file that the catch-up loads its filetype and the read-only lock", function()
    helpers.start()
    local file = helpers.tmp .. "/caught.lua"
    vim.fn.writefile({ "local caught = 1", "return caught" }, file)
    vim.cmd.stopinsert()
    vim.api.nvim_set_current_win(layout.wins.code)
    sidecar.dispatch({ type = "tool_use", id = "r2", name = "Read", input = { file_path = file } })
    layout.focus_input()
    vim.cmd.stopinsert()
    assert(shows(file), "no catch-up")
    local buf = vim.fn.bufnr(file)
    assert.are.same("lua", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
  end)

  describe("with a pinned selection", function()
    local context = require("anvim.context")
    local input = require("anvim.input")
    local pinned = helpers.tmp .. "/follow_pinned.lua"
    local elsewhere = helpers.tmp .. "/follow_elsewhere.lua"

    local function read(path, id)
      sidecar.dispatch({ type = "tool_use", id = id, name = "Read", input = { file_path = path } })
    end

    -- Pins lines 2-3 of a file in the code window.
    local function pin()
      helpers.start()
      vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "return a" }, pinned)
      vim.fn.writefile({ "return 'elsewhere'" }, elsewhere)
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(layout.wins.code)
      vim.cmd.edit(pinned)
      vim.api.nvim_feedkeys(vim.keycode("2GVj<Esc>"), "mxt", false)
      assert(context.selection(), "no pin")
      return vim.api.nvim_get_current_buf()
    end

    local function send()
      local sent
      helpers.capture_sends(function(msgs)
        input.send("what does this do?")
        sent = msgs[1]
      end)
      input.set_busy(false)
      return sent
    end

    after_each(function()
      context.clear()
      vim.cmd.stopinsert()
    end)

    it("keeps the code window while Claude reads elsewhere, and catches up after the prompt", function()
      local buf = pin()
      layout.focus_input()
      vim.cmd.stopinsert()
      read(elsewhere, "p1")
      assert.are.same(buf, vim.api.nvim_win_get_buf(layout.wins.code), "follow mode left the pinned file")
      assert.are.same("⏸ pinned · Claude at follow_elsewhere.lua:1 +1", follow.status())
      local sent = send()
      assert.are.same({ 2, 3 }, { sent.context.selection.start_line, sent.context.selection.end_line })
      assert.is_nil(context.selection())
      assert(
        vim.wait(1000, function()
          return vim.api.nvim_win_get_buf(layout.wins.code) == vim.fn.bufnr(elsewhere)
        end),
        "follow mode did not catch up after the prompt"
      )
      assert.are.same("◉ following", follow.status())
    end)

    it("does not catch up on entering the prompt, when Claude moved while the user read", function()
      helpers.start()
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(layout.wins.code)
      read(elsewhere, "p2")
      local buf = pin()
      layout.focus_input()
      vim.cmd.stopinsert()
      vim.wait(100)
      assert.are.same(buf, vim.api.nvim_win_get_buf(layout.wins.code), "the catch-up took the pinned file away")
      assert.are.same("follow_pinned.lua", send().context.file)
    end)

    it("catches up when <C-x> unpins in the prompt", function()
      pin()
      layout.focus_input()
      vim.cmd.stopinsert()
      read(elsewhere, "p3")
      vim.api.nvim_feedkeys(vim.keycode("<C-x>"), "mxt", false)
      assert(
        vim.wait(1000, function()
          return vim.api.nvim_win_get_buf(layout.wins.code) == vim.fn.bufnr(elsewhere)
        end),
        "follow mode did not catch up after <C-x>"
      )
    end)

    it("says less in a narrow statusline, with the pause sign first", function()
      pin()
      read(elsewhere, "p4")
      assert.are.same("⏸ follow_elsewhere.lua:1 +1", follow.status(true))
    end)

    it("unpins on <leader>j, and goes to Claude in the same file", function()
      local buf = pin()
      sidecar.dispatch({ type = "tool_use", id = "p5", name = "Read", input = { file_path = pinned, offset = 4 } })
      follow.jump()
      assert.is_nil(context.selection())
      assert.are.same(buf, vim.api.nvim_win_get_buf(layout.wins.code))
      assert.are.same(4, vim.api.nvim_win_get_cursor(layout.wins.code)[1])
    end)

    it("catches up when the pinned buffer goes", function()
      local buf = pin()
      layout.focus_input()
      vim.cmd.stopinsert()
      read(elsewhere, "p6")
      vim.api.nvim_buf_delete(buf, { force = true })
      assert(shows(elsewhere), "follow mode did not catch up after the buffer went")
    end)

    describe("and a Write", function()
      local written = helpers.tmp .. "/follow_written.lua"
      local content = { "local a = 1", "local b = 2", "return a + b" }

      local function field(id, key, phase, x)
        helpers.field(id, "Write", key, phase, x)
      end

      local function start(id)
        sidecar.dispatch({ type = "tool_start", id = id, name = "Write" })
        field(id, "file_path", "end", written)
        field(id, "content", "start")
        field(id, "content", "delta", content[1] .. "\n")
      end

      local function finish(id)
        field(id, "content", "delta", content[2] .. "\n" .. content[3] .. "\n")
        field(id, "content", "end", table.concat(content, "\n") .. "\n")
        sidecar.dispatch({ type = "tool_input_end", id = id })
      end

      local function result(id)
        vim.fn.writefile(content, written)
        sidecar.dispatch({ type = "tool_result", id = id, is_error = false, text = "ok", result = { type = "create" } })
      end

      local function code_buf()
        return vim.api.nvim_win_get_buf(layout.wins.code)
      end

      before_each(function()
        os.remove(written)
      end)

      it("streams the preview in view once the pin ends, then shows the file", function()
        local buf = pin()
        layout.focus_input()
        vim.cmd.stopinsert()
        start("w1")
        assert.are.same(buf, code_buf(), "the pin kept the view")
        vim.api.nvim_feedkeys(vim.keycode("<C-x>"), "mxt", false)
        assert(
          vim.wait(1000, function()
            return vim.b[code_buf()].anvim_preview == written
          end),
          "the preview did not show"
        )
        finish("w1")
        assert(
          vim.wait(3000, function()
            return vim.deep_equal(content, vim.api.nvim_buf_get_lines(code_buf(), 0, 3, false))
          end),
          "the preview did not stream in view"
        )
        result("w1")
        assert.are.same(written, vim.api.nvim_buf_get_name(code_buf()))
      end)

      it("lands on the written file when the pin ends after the Write", function()
        local buf = pin()
        layout.focus_input()
        vim.cmd.stopinsert()
        start("w2")
        finish("w2")
        vim.wait(500)
        result("w2")
        assert.are.same(buf, code_buf(), "the pin kept the view")
        -- The preview, then the written file.
        assert.are.same("⏸ pinned · Claude at follow_written.lua:1 +2", follow.status())
        vim.api.nvim_feedkeys(vim.keycode("<C-x>"), "mxt", false)
        assert(shows(written), "the catch-up did not land on the file")
      end)
    end)
  end)
end)
