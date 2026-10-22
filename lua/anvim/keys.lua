-- Every key that anvim maps, by the place where it works. The modules map
-- them with set(), which takes the description from here, and the key view
-- (<leader>?) lists them. A static entry is no map of its own: a command, the
-- mouse, or another place's key that acts differently in this place.
local M = {}

---@class anvim.Key
---@field [1] string|string[] The lhs, or several that share the description.
---@field [2] string The description.
---@field mode? string|string[] Normal mode when not given.
---@field label? string What the key view shows instead of the lhs.
---@field static? boolean
---@field default? boolean A map of Neovim's or of a plugin's, which anvim keeps.
---@field ctx? string Where the map lives, when it is not where the place's maps live.
---@field when? "lsp"|"git" The map exists only in buffers with a language server, or in a git repo.
---@field row? string The key view draws the next entries with the same row as one row, with this text.
---@field tag? string The key view's mode tag, instead of the one that the modes give.
---@field scrolls? boolean The key view's footer shows it only while the view scrolls.

---@class anvim.KeyPlace
---@field id string
---@field name string
---@field ctx "global"|"file"|"prompt"|"transcript"|"compose"|"explorer"|"overview"|"agentlog"|"view"|"other" Where its maps live.
---@field keys anvim.Key[]

---@type anvim.KeyPlace[]
M.places = {
  {
    id = "global",
    name = "Everywhere",
    ctx = "global",
    keys = {
      { "<leader>?", "Show anvim's keys" },
      { "<C-h>", "Go to the left window" },
      { "<C-j>", "Go to the window below" },
      { "<C-k>", "Go to the window above" },
      { "<C-l>", "Go to the right window" },
      {
        "<C-w>H",
        "Move the window to the far left; a float stays",
        label = "<C-w>HJKLT",
        row = "Move the window; a float stays",
      },
      {
        "<C-w>J",
        "Move the window to the very bottom; a float stays",
        label = "<C-w>HJKLT",
        row = "Move the window; a float stays",
      },
      {
        "<C-w>K",
        "Move the window to the very top; a float stays",
        label = "<C-w>HJKLT",
        row = "Move the window; a float stays",
      },
      {
        "<C-w>L",
        "Move the window to the far right; a float stays",
        label = "<C-w>HJKLT",
        row = "Move the window; a float stays",
      },
      {
        "<C-w>T",
        "Move the window to a new tab page; a float stays",
        label = "<C-w>HJKLT",
        row = "Move the window; a float stays",
      },
      { "<S-h>", "Previous buffer", row = "Previous and next buffer" },
      { "<S-l>", "Next buffer", row = "Previous and next buffer" },
      { { "j", "<Down>" }, "Down a screen line", mode = { "n", "x" }, row = "Down and up by screen line" },
      { { "k", "<Up>" }, "Up a screen line", mode = { "n", "x" }, row = "Down and up by screen line" },
      { "<Esc>", "Clear the search highlight" },
      { "<leader><space>", "Find files" },
      { "<leader>/", "Grep the files" },
      { "<leader>,", "Pick a buffer" },
      { "<leader>fr", "Recent files" },
      { "<leader>e", "Go to the explorer" },
      { "<leader>sw", "Grep the word or the selection", mode = { "n", "x" } },
      { "<leader>ss", "Symbols of the file" },
      { "<leader>sS", "Symbols of the workspace" },
      { "<leader>sd", "Diagnostics of the workspace" },
      { "<leader>sD", "Diagnostics of the file" },
      { "<leader>sh", "Help pages" },
      { "<leader>gs", "Git status" },
      { "<leader>gd", "Git diff by hunk" },
      { "<leader>gl", "Git log" },
      { "<leader>gf", "The file's git history" },
      { "<leader>gb", "The line's git history" },
      { "<leader>uw", "Toggle wrap in the code window" },
      { "<leader>ud", "Toggle diagnostics" },
      { "<leader>uH", "Toggle Claude on the left" },
      { "<leader>ue", "Toggle explorer auto-minimize" },
      { "q", "Close a help, quickfix or info window", ctx = "other" },
    },
  },
  {
    id = "code",
    name = "Code window",
    ctx = "file",
    -- Neovim's other defaults, such as [q ]q and the treesitter selections
    -- an in [n ]n, work as in any Neovim, and :help index lists them.
    keys = {
      { { "i", "a", "I", "A", "o", "O" }, "Talk to Claude" },
      { "c", "Point Claude at the selection", mode = "x" },
      { "c", "Point Claude at the lines of a motion", label = "c{motion}" },
      { "c", "Point Claude at the current line", label = "cc", mode = "o", tag = "" },
      { "<C-l>", "Go to the prompt with the selection", mode = "x" },
      { "gd", "Go to the definition", when = "lsp" },
      { "gr", "Find the references", when = "lsp" },
      { "gI", "Go to the implementation", when = "lsp" },
      { "gy", "Go to the type definition", when = "lsp" },
      { "gD", "Go to the declaration", when = "lsp" },
      { "K", "Show the hover text", default = true, when = "lsp" },
      { "gO", "List the file's symbols", default = true, ctx = "global" },
      { "]]", "Next reference", when = "lsp", row = "Next and previous reference" },
      { "[[", "Previous reference", when = "lsp", row = "Next and previous reference" },
      { "]d", "Next diagnostic", default = true, ctx = "global", row = "Next and previous diagnostic" },
      { "[d", "Previous diagnostic", default = true, ctx = "global", row = "Next and previous diagnostic" },
      { "]D", "Last diagnostic", default = true, ctx = "global", row = "Last and first diagnostic" },
      { "[D", "First diagnostic", default = true, ctx = "global", row = "Last and first diagnostic" },
      { "<C-w>d", "Show the diagnostics at the cursor", default = true, ctx = "global" },
      { "]h", "Next hunk", when = "git", row = "Next and previous hunk" },
      { "[h", "Previous hunk", when = "git", row = "Next and previous hunk" },
      { "]H", "Last hunk", when = "git", row = "Last and first hunk" },
      { "[H", "First hunk", when = "git", row = "Last and first hunk" },
      { "<leader>ghp", "Preview the hunk", when = "git" },
      { "<leader>ghb", "Blame the line", when = "git" },
      { "gx", "Open the path or link", mode = { "n", "x" }, default = true, ctx = "global" },
      { "ii", "The scope inside its edges", mode = { "x", "o" }, default = true, ctx = "global", tag = "object" },
      { "ai", "The scope with its edges", mode = { "x", "o" }, default = true, ctx = "global", tag = "object" },
      {
        "[i",
        "Go to the scope's top edge",
        mode = { "n", "x", "o" },
        default = true,
        ctx = "global",
        row = "Go to the scope's top and bottom edge",
      },
      {
        "]i",
        "Go to the scope's bottom edge",
        mode = { "n", "x", "o" },
        default = true,
        ctx = "global",
        row = "Go to the scope's top and bottom edge",
      },
    },
  },
  {
    id = "prompt",
    name = "Prompt",
    ctx = "prompt",
    keys = {
      { "<CR>", "Send the prompt", mode = { "i", "n" } },
      { { "<S-CR>", "<M-CR>" }, "New line", mode = "i" },
      { "<Esc>", "Stop Claude (press twice)" },
      { "<C-c>", "Stop Claude", mode = { "i", "n" } },
      { "<S-Tab>", "Cycle the permission mode", mode = { "i", "n" } },
      { "<C-x>", "Unpin the selection", mode = { "i", "n" } },
      { "<C-g>", "Write the prompt in a large window", mode = { "i", "n" } },
      { "<Up>", "Previous prompt", mode = "i", row = "Previous and next prompt, or menu item" },
      { "<Down>", "Next prompt", mode = "i", row = "Previous and next prompt, or menu item" },
      { "<C-p>", "Previous prompt", row = "Previous and next prompt" },
      { "<C-n>", "Next prompt", row = "Previous and next prompt" },
      { { "<C-u>", "<C-d>" }, "Scroll the transcript" },
      { { "<C-b>", "<C-f>" }, "Scroll the transcript" },
      { { "<PageUp>", "<PageDown>" }, "Scroll the transcript", mode = { "n", "i" } },
      { "@", "Complete a file", static = true },
      { "/", "Complete a slash command", static = true },
      { "?", "Show anvim's keys", mode = { "n", "i" } },
      { "<C-Space>", "Show the completion menu", mode = "i" },
      -- Neovim's own keys for its completion menu, which are no maps.
      { "<C-e>", "Close the completion menu", mode = "i", static = true },
      { "<C-y>", "Take the highlighted item", mode = "i", static = true },
      { { "<C-n>", "<C-p>" }, "Next and previous item", mode = "i", static = true },
    },
  },
  {
    id = "compose",
    name = "Compose window",
    ctx = "compose",
    keys = {
      { "<C-g>", "Back to the prompt", mode = { "n", "i" } },
      { ":w", "Put the text in the prompt", static = true },
      { { ":wq", "ZZ" }, "Put the text in the prompt and close", static = true },
      { ":q!", "Drop the changes", static = true },
    },
  },
  {
    id = "explorer",
    name = "Explorer",
    ctx = "explorer",
    keys = {
      { "@", "Point Claude at the file" },
      { { "<C-w>h", "<C-h>", "<C-w>l", "<C-l>" }, "Go to the code window", label = "<C-h> <C-l> <C-w>hl" },
      { "?", "Show the explorer's own keys", static = true },
    },
  },
  {
    id = "transcript",
    name = "Transcript and read mode",
    ctx = "transcript",
    keys = {
      { { "q", "<Esc>" }, "Back to the prompt" },
      { { "i", "a", "I", "A", "o", "O" }, "Back to typing" },
      { "<LeftDrag>", "Select in the transcript", label = "drag", mode = { "n", "i" }, ctx = "prompt" },
      { "<ScrollWheelUp>", "Scroll it from any window", label = "wheel", static = true },
    },
  },
  {
    id = "permission",
    name = "Permission requests",
    ctx = "prompt",
    keys = {
      { { "1", "2", "3", "4", "5", "6", "7", "8", "9" }, "Choose that option", label = "1-9" },
      { { "j", "<Down>" }, "Next choice", row = "Next and previous choice" },
      { { "k", "<Up>" }, "Previous choice", row = "Next and previous choice" },
      { "<CR>", "Choose the highlighted option", static = true },
      { "<Esc>", "No (press twice)", static = true },
    },
  },
  {
    id = "claude",
    name = "Claude and its agents",
    ctx = "global",
    keys = {
      {
        { "<leader>j", "<leader>cj" },
        "Jump to where Claude or the focused agent is",
        row = "Jump to Claude or the focused agent",
      },
      { "<leader>c0", "Go to the prompt and follow Claude" },
      {
        "<leader>c1",
        "Go to the prompt and follow agent 1",
        row = "Go to the prompt and follow agent 1-4",
        label = "<leader>c1-4",
      },
      {
        "<leader>c2",
        "Go to the prompt and follow agent 2",
        row = "Go to the prompt and follow agent 1-4",
        label = "<leader>c1-4",
      },
      {
        "<leader>c3",
        "Go to the prompt and follow agent 3",
        row = "Go to the prompt and follow agent 1-4",
        label = "<leader>c1-4",
      },
      {
        "<leader>c4",
        "Go to the prompt and follow agent 4",
        row = "Go to the prompt and follow agent 1-4",
        label = "<leader>c1-4",
      },
      { "<leader>ca", "Open the Agent Overview" },
      { "<leader>ct", "Pick a place from Claude's trail" },
      { "<leader>cr", "Read the transcript" },
      { "<leader>cy", "Yank Claude's last reply" },
      { "<leader>cs", "Resume a session" },
      { "<leader>cm", "Choose the model" },
      { "<leader>cR", "Restart Claude" },
    },
  },
  -- The tabs are the list of a snacks picker, which keeps snacks' own keys.
  {
    id = "overview",
    name = "Agent Overview",
    ctx = "overview",
    keys = {
      { "<CR>", "Close the window and follow the agent", row = "Close the window and follow the agent" },
      {
        "<2-LeftMouse>",
        "Close the window and follow the agent",
        label = "double-click",
        row = "Close the window and follow the agent",
      },
      { "j", "Next agent", default = true, label = "j k", row = "Next and previous agent" },
      { "k", "Previous agent", default = true, label = "j k", row = "Next and previous agent" },
      { "<Tab>", "Next agent", label = "<Tab> <S-Tab>", row = "Next and previous agent" },
      { "<S-Tab>", "Previous agent", label = "<Tab> <S-Tab>", row = "Next and previous agent" },
      { { "0", "1", "2", "3", "4" }, "Select the agent in that slot", label = "0-4" },
      { { "<C-f>", "<C-b>" }, "Scroll the conversation", default = true },
      { "<a-w>", "Go into the conversation", default = true },
      { { "q", "<Esc>" }, "Close the window", default = true, row = "Close the window" },
      { { "q", "<Esc>" }, "Close the window", ctx = "agentlog", row = "Close the window" },
      { "?", "Show the window's own keys", default = true },
    },
  },
  -- The key view's own keys, which its footer shows.
  {
    id = "view",
    name = "Key view",
    ctx = "view",
    keys = {
      { { "q", "<Esc>" }, "close" },
      { "j", "scroll down", scrolls = true, row = "scroll", label = "j k" },
      { "k", "scroll up", scrolls = true, row = "scroll", label = "j k" },
    },
  },
}

---@param key anvim.Key
---@return string[]
function M.lhs(key)
  return type(key[1]) == "table" and key[1] or { key[1] }
end

---@param key anvim.Key
---@return string[]
function M.modes(key)
  local mode = key.mode or "n"
  return type(mode) == "table" and mode or { mode }
end

---@param key anvim.Key
function M.label(key)
  return key.label or table.concat(M.lhs(key), " ")
end

---@return anvim.KeyPlace?
function M.place(id)
  for _, place in ipairs(M.places) do
    if place.id == id then
      return place
    end
  end
end

-- The map's entry in a place, for each of the modes.
---@param mode string|string[]
---@return anvim.Key?
function M.find(place, mode, lhs)
  local p = M.place(place)
  local code = vim.keycode(lhs)
  for _, key in ipairs(p and p.keys or {}) do
    local modes = M.modes(key)
    local ok = not key.static and not key.default
    for _, m in ipairs(type(mode) == "table" and mode or { mode }) do
      ok = ok and vim.tbl_contains(modes, m)
    end
    if ok then
      for _, l in ipairs(M.lhs(key)) do
        if vim.keycode(l) == code then
          return key
        end
      end
    end
  end
end

---@param mode string|string[]
function M.desc(place, mode, lhs)
  local key = M.find(place, mode, lhs)
  if not key then
    local modes = type(mode) == "table" and table.concat(mode, ",") or mode
    error(("anvim.keys: %s has no key %s in mode %s"):format(place, lhs, modes), 2)
  end
  return key[2]
end

-- vim.keymap.set(), with the description of the key's entry in the place.
---@param mode string|string[]
---@param opts? vim.keymap.set.Opts
function M.set(place, mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts or {}, { desc = M.desc(place, mode, lhs) }))
end

return M
