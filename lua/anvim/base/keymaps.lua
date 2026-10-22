-- anvim's keys for reading. They sit where stock LazyVim puts them, so the
-- habits of a LazyVim user carry over. Keys that edit are left out.
local keys = require("anvim.keys")

local function map(mode, lhs, rhs, opts)
  keys.set("global", mode, lhs, rhs, opts)
end

-- Down and up by screen line in wrapped text, by line with a count.
map({ "n", "x" }, "j", "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })
map({ "n", "x" }, "<Down>", "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })
map({ "n", "x" }, "k", "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })
map({ "n", "x" }, "<Up>", "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })

map("n", "<C-h>", "<C-w>h", { remap = true })
map("n", "<C-j>", "<C-w>j", { remap = true })
map("n", "<C-k>", "<C-w>k", { remap = true })
map("n", "<C-l>", "<C-w>l", { remap = true })

-- In a float, Neovim's own <C-w>H, J, K and L turn it into a split, which
-- resizes anvim's columns, and <C-w>T moves it to a new tab page. A float,
-- such as a picker, keeps its place. Splits keep Neovim's own moves.
for _, key in ipairs({ "H", "J", "K", "L", "T" }) do
  map("n", "<C-w>" .. key, function()
    if vim.api.nvim_win_get_config(0).relative == "" then
      vim.cmd((vim.v.count > 0 and vim.v.count or "") .. "wincmd " .. key)
    end
  end)
end

map("n", "<S-h>", "<cmd>bprevious<cr>")
map("n", "<S-l>", "<cmd>bnext<cr>")

map("n", "<Esc>", function()
  vim.cmd("noh")
  return "<Esc>"
end, { expr = true })

-- Neovim's LSP keys that rename, run code actions and code lenses edit files.
-- With the other gr keys gone, gr answers at once.
for _, key in ipairs({ "grn", "gra", "grx", "grr", "gri", "grt" }) do
  pcall(vim.keymap.del, "n", key)
end
pcall(vim.keymap.del, "x", "gra")
-- Neovim's keys that only change text: comments, blank lines and :&&. The
-- operator-pending gc stays. It is a text object: ygc yanks a comment, and
-- cgc points Claude at it.
for _, key in ipairs({ "gc", "gcc", "[<Space>", "]<Space>", "&" }) do
  pcall(vim.keymap.del, "n", key)
end
pcall(vim.keymap.del, "x", "gc")

local function pick(source)
  return function()
    Snacks.picker[source]()
  end
end

-- find
map("n", "<leader><space>", pick("files"))
map("n", "<leader>/", pick("grep"))
map("n", "<leader>,", pick("buffers"))
map("n", "<leader>fr", pick("recent"))

-- The explorer is part of the layout, so this key goes there and never closes it.
map("n", "<leader>e", function()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if explorer then
    explorer:focus("list")
  else
    Snacks.explorer()
  end
end)

-- search
map({ "n", "x" }, "<leader>sw", pick("grep_word"))
map("n", "<leader>ss", pick("lsp_symbols"))
map("n", "<leader>sS", pick("lsp_workspace_symbols"))
map("n", "<leader>sd", pick("diagnostics"))
map("n", "<leader>sD", pick("diagnostics_buffer"))
map("n", "<leader>sh", pick("help"))

-- git
map("n", "<leader>gs", pick("git_status"))
map("n", "<leader>gd", pick("git_diff"))
map("n", "<leader>gl", pick("git_log"))
map("n", "<leader>gf", pick("git_log_file"))
map("n", "<leader>gb", pick("git_log_line"))

-- lsp, per buffer as in LazyVim, so that a buffer without a language server
-- keeps Vim's own gd, gD, ]] and [[.
local function lsp_keys(buf)
  local function bmap(lhs, rhs, opts)
    keys.set("code", "n", lhs, rhs, vim.tbl_extend("force", { buffer = buf }, opts or {}))
  end
  bmap("gd", pick("lsp_definitions"))
  bmap("gr", pick("lsp_references"), { nowait = true })
  bmap("gI", pick("lsp_implementations"))
  bmap("gy", pick("lsp_type_definitions"))
  bmap("gD", pick("lsp_declarations"))
  bmap("]]", function()
    Snacks.words.jump(vim.v.count1)
  end)
  bmap("[[", function()
    Snacks.words.jump(-vim.v.count1)
  end)
end
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("anvim.base.lsp_keys", { clear = true }),
  callback = function(ev)
    lsp_keys(ev.buf)
  end,
})
-- These keys load at VeryLazy, maybe after a server attached.
for _, client in ipairs(vim.lsp.get_clients()) do
  for buf in pairs(client.attached_buffers) do
    lsp_keys(buf)
  end
end

-- toggles
Snacks.toggle.option("wrap", { name = "Wrap" }):map("<leader>uw", { desc = keys.desc("global", "n", "<leader>uw") })
Snacks.toggle.diagnostics():map("<leader>ud", { desc = keys.desc("global", "n", "<leader>ud") })
Snacks.toggle({
  name = "Claude on the left",
  get = function()
    return require("anvim.layout").claude_side() == "left"
  end,
  set = function(state)
    require("anvim.layout").set_claude_side(state and "left" or "right")
  end,
}):map("<leader>uH", { desc = keys.desc("global", "n", "<leader>uH") })
