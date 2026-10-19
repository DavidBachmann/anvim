-- anvim: a read-only Neovim for watching Claude work. Start it with bin/anvim.
local root = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
vim.opt.rtp:prepend(root)

vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'
vim.o.termguicolors = true
vim.o.number = true
vim.o.relativenumber = true
vim.o.signcolumn = 'yes'
vim.o.cursorline = true
vim.o.scrolloff = 8
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.mouse = 'a'
vim.o.laststatus = 2
vim.o.showmode = false
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.fillchars = 'eob: '
vim.o.breakat = ' \t;:,!?'
vim.o.clipboard = 'unnamedplus'

vim.pack.add({
  'https://github.com/folke/snacks.nvim',
  'https://github.com/nvim-mini/mini.icons',
  { src = 'https://github.com/rose-pine/neovim', name = 'rose-pine' },
}, { confirm = false })

require('mini.icons').setup()
require('rose-pine').setup({ dim_inactive_windows = false })
vim.cmd.colorscheme('rose-pine-main')

require('snacks').setup({
  explorer = { replace_netrw = true },
  picker = { enabled = true },
})
vim.keymap.set('n', '<leader><space>', function()
  Snacks.picker.files()
end, { desc = 'Find files' })
vim.keymap.set('n', '<leader>/', function()
  Snacks.picker.grep()
end, { desc = 'Grep' })
vim.keymap.set('n', '<leader>e', function()
  Snacks.explorer()
end, { desc = 'Toggle tree' })

-- Reuse the main Neovim's treesitter parsers and queries when they exist.
for _, dir in ipairs({ '~/.local/share/nvim/site', '~/.local/share/nvim/lazy/nvim-treesitter/runtime' }) do
  dir = vim.fn.expand(dir)
  if vim.uv.fs_stat(dir) then
    vim.opt.rtp:append(dir)
  end
end
vim.api.nvim_create_autocmd('FileType', {
  callback = function(ev)
    pcall(vim.treesitter.start, ev.buf)
  end,
})

-- ANVIM_REPLAY=<recording> plays a session that ANVIM_RECORD saved, at no API cost.
local replay = vim.env.ANVIM_REPLAY
require('anvim').setup({
  permission_mode = 'bypassPermissions',
  sidecar_cmd = replay and { 'bun', root .. '/sidecar/src/replay.ts', replay, vim.env.ANVIM_REPLAY_SPEED or '1' },
})

vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    require('anvim').start()
  end,
})
