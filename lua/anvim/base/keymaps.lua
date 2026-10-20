-- anvim's keys for reading. They sit where stock LazyVim puts them, so the
-- habits of a LazyVim user carry over. Keys that edit are left out.
local map = vim.keymap.set

-- Down and up by screen line in wrapped text, by line with a count.
map({ "n", "x" }, "j", "v:count == 0 ? 'gj' : 'j'", { desc = "Down", expr = true, silent = true })
map({ "n", "x" }, "<Down>", "v:count == 0 ? 'gj' : 'j'", { desc = "Down", expr = true, silent = true })
map({ "n", "x" }, "k", "v:count == 0 ? 'gk' : 'k'", { desc = "Up", expr = true, silent = true })
map({ "n", "x" }, "<Up>", "v:count == 0 ? 'gk' : 'k'", { desc = "Up", expr = true, silent = true })

map("n", "<C-h>", "<C-w>h", { desc = "Go to Left Window", remap = true })
map("n", "<C-j>", "<C-w>j", { desc = "Go to Lower Window", remap = true })
map("n", "<C-k>", "<C-w>k", { desc = "Go to Upper Window", remap = true })
map("n", "<C-l>", "<C-w>l", { desc = "Go to Right Window", remap = true })

map("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Prev Buffer" })
map("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next Buffer" })

map("n", "<Esc>", function()
  vim.cmd("noh")
  return "<Esc>"
end, { expr = true, desc = "Escape and Clear hlsearch" })

-- Neovim's LSP keys that rename, run code actions and code lenses edit files.
-- With the other gr keys gone, gr answers at once.
for _, key in ipairs({ "grn", "gra", "grx", "grr", "gri", "grt" }) do
  pcall(vim.keymap.del, "n", key)
end
pcall(vim.keymap.del, "x", "gra")

local function pick(source)
  return function()
    Snacks.picker[source]()
  end
end

-- find
map("n", "<leader><space>", pick("files"), { desc = "Find Files" })
map("n", "<leader>/", pick("grep"), { desc = "Grep" })
map("n", "<leader>,", pick("buffers"), { desc = "Buffers" })
map("n", "<leader>fr", pick("recent"), { desc = "Recent" })

-- The explorer is part of the layout, so this key goes there and never closes it.
map("n", "<leader>e", function()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if explorer then
    explorer:focus("list")
  else
    Snacks.explorer()
  end
end, { desc = "Explorer" })

-- search
map({ "n", "x" }, "<leader>sw", pick("grep_word"), { desc = "Visual selection or word" })
map("n", "<leader>ss", pick("lsp_symbols"), { desc = "LSP Symbols" })
map("n", "<leader>sS", pick("lsp_workspace_symbols"), { desc = "LSP Workspace Symbols" })
map("n", "<leader>sd", pick("diagnostics"), { desc = "Diagnostics" })
map("n", "<leader>sD", pick("diagnostics_buffer"), { desc = "Buffer Diagnostics" })
map("n", "<leader>sh", pick("help"), { desc = "Help Pages" })

-- git
map("n", "<leader>gs", pick("git_status"), { desc = "Git Status" })
map("n", "<leader>gd", pick("git_diff"), { desc = "Git Diff (hunks)" })
map("n", "<leader>gl", pick("git_log"), { desc = "Git Log" })
map("n", "<leader>gf", pick("git_log_file"), { desc = "Git Current File History" })
map("n", "<leader>gb", pick("git_log_line"), { desc = "Git Blame Line" })

-- lsp, per buffer as in LazyVim, so that a buffer without a language server
-- keeps Vim's own gd, gD, ]] and [[.
local function lsp_keys(buf)
  local function bmap(lhs, rhs, opts)
    map("n", lhs, rhs, vim.tbl_extend("force", { buffer = buf }, opts))
  end
  bmap("gd", pick("lsp_definitions"), { desc = "Goto Definition" })
  bmap("gr", pick("lsp_references"), { desc = "References", nowait = true })
  bmap("gI", pick("lsp_implementations"), { desc = "Goto Implementation" })
  bmap("gy", pick("lsp_type_definitions"), { desc = "Goto T[y]pe Definition" })
  bmap("gD", pick("lsp_declarations"), { desc = "Goto Declaration" })
  bmap("]]", function()
    Snacks.words.jump(vim.v.count1)
  end, { desc = "Next Reference" })
  bmap("[[", function()
    Snacks.words.jump(-vim.v.count1)
  end, { desc = "Prev Reference" })
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
Snacks.toggle.option("wrap", { name = "Wrap" }):map("<leader>uw")
Snacks.toggle.diagnostics():map("<leader>ud")
