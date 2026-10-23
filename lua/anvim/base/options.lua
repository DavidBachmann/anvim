-- Options as in LazyVim. They load before lazy.nvim, because the specs' keys
-- need the leader.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local opt = vim.opt

opt.autowrite = true
-- Yanks go to the system clipboard, except over SSH, as in LazyVim.
opt.clipboard = vim.env.SSH_CONNECTION and "" or "unnamedplus"
-- Icons first in the completion menu, as in the explorer.
opt.completeitemalign = "kind,abbr,menu"
opt.completeopt = "menu,menuone,noselect"
-- Markdown in the code window keeps its backticks and stars. The transcript
-- sets its own.
opt.conceallevel = 0
opt.confirm = true
opt.cursorline = true
opt.expandtab = true
opt.fillchars = {
  foldopen = "",
  foldclose = "",
  fold = " ",
  foldsep = " ",
  diff = "╱",
  eob = " ",
}
opt.foldlevel = 99
opt.foldmethod = "indent"
opt.foldtext = ""
opt.formatoptions = "jcroqlnt"
opt.grepformat = "%f:%l:%c:%m"
opt.grepprg = "rg --vimgrep"
opt.ignorecase = true
opt.inccommand = "nosplit"
opt.jumpoptions = "view"
opt.laststatus = 3
opt.linebreak = true
opt.list = true
opt.mouse = "a"
opt.number = true
-- The menu only: Neovim has no option for a border on its info popup.
opt.pumborder = "rounded"
opt.pumheight = 10
opt.relativenumber = true
opt.ruler = false
opt.scrolloff = 4
opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize", "help", "globals", "skiprtp", "folds" }
opt.shiftround = true
opt.shiftwidth = 2
opt.shortmess:append({ W = true, I = true, c = true, C = true })
opt.showmode = false
opt.sidescrolloff = 8
opt.signcolumn = "yes"
opt.smartcase = true
opt.smartindent = true
opt.smoothscroll = true
opt.spelllang = { "en" }
opt.splitbelow = true
opt.splitkeep = "screen"
opt.splitright = true
-- anvim's own (lua/anvim/statusline.lua), from the first frame on.
opt.statusline = "%!v:lua.require'anvim.statusline'.render()"
opt.tabstop = 2
opt.termguicolors = true
-- Short, so that which-key shows soon.
opt.timeoutlen = 300
opt.undofile = true
opt.undolevels = 10000
opt.updatetime = 200
opt.virtualedit = "block"
-- The command line shows its menu as the user types (autocmds.lua), with no
-- item selected, so that Enter runs what was typed.
opt.wildmode = "noselect:lastused,full"
opt.wildoptions = "pum,fuzzy"
opt.winminwidth = 5
opt.wrap = false

-- The markdown ftplugin would set 'shiftwidth' and friends to 4.
vim.g.markdown_recommended_style = 0

-- Neovim's new message UI. The old one stops on an error from a callback until
-- Enter: no redraws while Claude streams, and the next typed key answers it.
-- ui2 shows the error in one line, and :messages in a pager.
-- No row for the command line: the command line opens over the code, and
-- messages show in ui2's float, which closes after a few seconds. A message
-- aimed at the command line would grow it and move the windows.
local ok, ui2 = pcall(require, "vim._core.ui2")
if ok then
  opt.cmdheight = 0
  ui2.enable({ msg = { target = "msg" } })
  require("anvim.cmdline").setup(ui2)
end
