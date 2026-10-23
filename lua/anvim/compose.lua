-- The compose window: the prompt in a large window in the middle of the
-- screen, as Claude Code's Ctrl+G opens the prompt in $EDITOR. It is a
-- snacks.win with the style of snacks' scratch window. Its buffer is like a
-- file whose disk is the prompt: :w puts the text in the prompt, :wq, :x and
-- ZZ also close the window, and :q! drops the changes. <C-g> puts the text in
-- the prompt and goes back there, and so does leaving the window.
local config = require("anvim.config")
local input = require("anvim.input")
local layout = require("anvim.layout")

local M = {}

local api = vim.api
local NAME = "anvim://compose"
local CODE_OPTIONS = { "cursorline", "conceallevel", "concealcursor" }

---@type snacks.win?
local win
---@type { at: [integer, integer], typing: boolean, stopped: boolean? }? Where the prompt's cursor goes after the window closes.
local landing
---@type [integer, integer]? The cursor when insert mode left the window.
local left_typing
---@type integer? The window before the prompt, for <C-w>p.
local previous

---@return integer?
function M.win()
  return win and win:valid() and win.win or nil
end

local function save(buf)
  local prompt = input.buf()
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if not vim.deep_equal(lines, api.nvim_buf_get_lines(prompt, 0, -1, false)) then
    api.nvim_buf_set_lines(prompt, 0, -1, false, lines)
    input.render()
  end
  vim.bo[buf].modified = false
end

-- The prompt gets the compose window's place and mode: typing goes on where
-- it was, and normal mode stays normal.
local function land()
  local to, prompt = landing, layout.wins.input
  landing = nil
  if to and to.stopped then
    -- Insert mode ended in another window. The next insert command in the
    -- prompt goes on where typing stopped.
    input.stop_at(to.at)
  end
  if not to or api.nvim_get_current_win() ~= prompt then
    return
  end
  local at = { math.min(to.at[1], api.nvim_buf_line_count(input.buf())), to.at[2] }
  if to.typing then
    input.resume({ at = at })
  elseif not to.stopped then
    api.nvim_win_set_cursor(prompt, at)
  end
end

-- After :q!, the prompt keeps its text and its place. Neovim enters the
-- prompt only after WinClosed, so the landing waits for the event loop.
---@param self snacks.win
local function on_close(self)
  if win == self then
    win = nil
  end
  local buf, w = self.buf, self.win
  -- Next, snacks would go back to the previous window from inside WinClosed,
  -- where it fires no WinEnter. Without its window, it leaves that to Neovim,
  -- which goes to the previous window too, with WinEnter. Plugins such as the
  -- explorer can change that window, so make it the prompt.
  self.win = nil
  local prompt, current = layout.wins.input, api.nvim_get_current_win()
  local hop = require("anvim.windows").hop
  if current == w and prompt and api.nvim_win_is_valid(prompt) then
    hop(prompt)
    hop(w)
  elseif current == prompt and previous ~= w and previous and api.nvim_win_is_valid(previous) then
    -- A window key or a click went to the prompt, which made this window the
    -- previous one. Neovim forgets it once it closes.
    hop(previous)
    hop(prompt)
  end
  if not (buf and api.nvim_buf_is_valid(buf) and w and api.nvim_win_is_valid(w)) or vim.bo[buf].modified then
    return
  end
  -- After the cursor left, the mode is the other window's.
  local insert = api.nvim_get_mode().mode:sub(1, 1) == "i"
  local typing = api.nvim_get_current_win() == w and insert
  local left = left_typing
  left_typing = nil
  if left and not insert then
    landing = { at = left, typing = false, stopped = true }
  elseif typing or not config.options.input.auto_insert then
    landing = { at = api.nvim_win_get_cursor(w), typing = typing }
  else
    landing = { at = { input.insert_pos(w) }, typing = true }
  end
  vim.schedule(land)
end

-- Typed keys that follow <C-g> go on in the prompt, so it lands at once.
function M.close()
  if M.win() then
    save(win.buf)
    win:close()
    land()
  end
end

-- A float copies the options of the window it opens from, here the prompt.
-- So it takes the gutter that the code window has in review mode, and wraps
-- prose. As in the prompt, a reference ends in a
-- space, which 'list' would mark. With 'winfixbuf', <C-o> and :edit cannot
-- put another buffer in the window.
local function window_options()
  local wo = {
    winbar = "",
    wrap = true,
    linebreak = true,
    list = false,
    spell = false,
    winfixheight = false,
    winfixbuf = true,
  }
  local code = layout.code_win()
  for _, name in ipairs(CODE_OPTIONS) do
    wo[name] = vim.wo[code][name]
  end
  -- In follow mode, which the compose window is in, the code window has another.
  return vim.tbl_extend("force", wo, require("anvim.follow").review_options())
end

local function footer()
  local chunks = {}
  for _, key in ipairs({ { "<c-g>", "back to the prompt" }, { ":q!", "discard" } }) do
    vim.list_extend(chunks, {
      { " ", "SnacksFooter" },
      { " " .. key[1] .. " ", "SnacksFooterKey" },
      { " " .. key[2] .. " ", "SnacksFooterDesc" },
    })
  end
  chunks[#chunks + 1] = { " ", "SnacksFooter" }
  return chunks
end

function M.open()
  if M.win() then
    api.nvim_set_current_win(M.win())
    return
  end
  local prompt = layout.wins.input
  if not (prompt and api.nvim_win_is_valid(prompt)) then
    return
  end
  local insert = api.nvim_get_mode().mode:sub(1, 1) == "i"
  local cursor = api.nvim_win_get_cursor(prompt)
  left_typing = nil
  previous = vim.fn.win_getid(vim.fn.winnr("#"))
  local lines = api.nvim_buf_get_lines(input.buf(), 0, -1, false)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(b) == NAME then
      api.nvim_buf_delete(b, { force = true })
    end
  end
  local buf = api.nvim_create_buf(false, false)
  -- Set before anything can lock it as a file buffer.
  vim.bo[buf].buftype = "acwrite"
  -- snacks.image would show the images of markdown links inline.
  vim.b[buf].snacks_image_attached = true
  api.nvim_buf_set_name(buf, NAME)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      save(buf)
    end,
  })
  -- As snacks maps the keys of its windows, without a wait.
  require("anvim.keys").set("compose", { "n", "i" }, "<C-g>", M.close, { buffer = buf, nowait = true })
  -- After a window command, the cursor is in the other window by the time
  -- the event loop runs. After :q! the compose window is gone. The key view
  -- and the Agent Overview give the cursor back.
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function()
      left_typing = api.nvim_get_mode().mode:sub(1, 1) == "i" and api.nvim_win_get_cursor(0) or nil
      vim.schedule(function()
        local w, current = M.win(), api.nvim_get_current_win()
        local on_top = current == require("anvim.keyview").win() or require("anvim.overview").owns(current)
        if w and current ~= w and not on_top then
          M.close()
        end
      end)
    end,
  })
  -- snacks defines the scratch style when its scratch module loads.
  require("snacks.scratch")
  win = Snacks.win({
    style = "scratch",
    -- The scratch window's size, within the screen, so the statusline shows.
    width = function()
      return math.min(100, vim.o.columns - 4)
    end,
    height = function()
      return math.min(30, vim.o.lines - 4)
    end,
    -- Above other floats, such as the explorer's list, as for a scratch window.
    zindex = Snacks.win.zindex(20),
    buf = buf,
    -- The filetype of the prompt, for its completion of @ files and slash commands.
    bo = { buftype = "acwrite", bufhidden = "wipe", buflisted = false, swapfile = false, filetype = "anvim_input" },
    wo = window_options(),
    title = { { " ❯ ", "AnvimPrompt" }, { "Prompt ", "FloatTitle" } },
    footer = footer(),
    footer_keys = false,
    -- snacks maps q to a forced close, which drops the changes. Macros keep q.
    keys = { q = false },
    on_close = on_close,
  })
  local line = lines[cursor[1]] or ""
  api.nvim_win_set_cursor(win.win, cursor)
  if insert then
    vim.cmd.startinsert({ bang = cursor[2] >= #line })
  end
end

return M
