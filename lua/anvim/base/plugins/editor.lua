return {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      bigfile = { enabled = true },
      explorer = { enabled = true },
      -- Formats other than PNG need ImageMagick, which anvim does not
      -- install, or Bun, which the sidecar needs anyway.
      image = { enabled = true, formats = { "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "icns" } },
      indent = { enabled = true },
      input = { enabled = true },
      notifier = { enabled = true },
      picker = { enabled = true },
      quickfile = { enabled = true },
      scope = { enabled = true },
      scroll = { enabled = true },
      statuscolumn = { enabled = true },
      words = { enabled = true },
    },
    config = function(_, opts)
      require("snacks").setup(opts)
      -- snacks asks ImageMagick's identify for the size of each image, and
      -- shows an error without it. Without that step, snacks reads the size
      -- from the PNG itself. Bun takes the place of ImageMagick's convert.
      if opts.image.enabled and vim.fn.executable("magick") == 0 and vim.fn.executable("identify") == 0 then
        local convert = require("snacks.image.convert")
        local new = convert.convert
        local script = require("anvim.base.install").root .. "/sidecar/src/topng.ts"
        local topng = { ft = "png", cmd = { cmd = "bun", args = { script, "{src}", "{file}" } } }
        convert.convert = function(o)
          local ret = new(o)
          ret.steps = vim.tbl_filter(function(step)
            return step.name ~= "identify"
          end, ret.steps)
          for _, step in ipairs(ret.steps) do
            if step.name == "convert" then
              step.cmd = topng
            end
          end
          return ret
        end
      end
    end,
  },

  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts_extend = { "spec" },
    opts = {
      preset = "helix",
      spec = {
        {
          mode = { "n", "x" },
          { "<leader>f", group = "file/find" },
          { "<leader>g", group = "git" },
          { "<leader>gh", group = "hunks", icon = { cat = "filetype", name = "git" } },
          { "<leader>s", group = "search" },
          { "<leader>u", group = "ui" },
          { "[", group = "prev" },
          { "]", group = "next" },
          { "g", group = "goto" },
          { "z", group = "fold" },
          { "gx", desc = "Open with system app" },
        },
      },
    },
  },

  -- Changed lines in the sign column, and hunks to read. No keys stage or
  -- reset them.
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPost", "BufNewFile", "BufWritePre" },
    opts = {
      signs = {
        add = { text = "▎" },
        change = { text = "▎" },
        delete = { text = "" },
        topdelete = { text = "" },
        changedelete = { text = "▎" },
        untracked = { text = "▎" },
      },
      signs_staged = {
        add = { text = "▎" },
        change = { text = "▎" },
        delete = { text = "" },
        topdelete = { text = "" },
        changedelete = { text = "▎" },
      },
      on_attach = function(buffer)
        local gs = package.loaded.gitsigns

        local function map(mode, l, r)
          require("anvim.keys").set("code", mode, l, r, { buffer = buffer, silent = true })
        end

        map("n", "]h", function()
          if vim.wo.diff then
            vim.cmd.normal({ "]c", bang = true })
          else
            gs.nav_hunk("next")
          end
        end)
        map("n", "[h", function()
          if vim.wo.diff then
            vim.cmd.normal({ "[c", bang = true })
          else
            gs.nav_hunk("prev")
          end
        end)
        map("n", "]H", function()
          gs.nav_hunk("last")
        end)
        map("n", "[H", function()
          gs.nav_hunk("first")
        end)
        map("n", "<leader>ghp", gs.preview_hunk_inline)
        map("n", "<leader>ghb", function()
          gs.blame_line({ full = true })
        end)
      end,
    },
  },
}
