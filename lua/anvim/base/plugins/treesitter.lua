local base = require("anvim.base")

-- nvim-treesitter builds parsers with the tree-sitter CLI, which mason has.
local function with_cli(cb)
  if vim.fn.executable("tree-sitter") == 1 then
    return cb()
  end
  local registry = require("mason-registry")
  registry.refresh(vim.schedule_wrap(function()
    local pkg = registry.get_package("tree-sitter-cli")
    if pkg:is_installed() then
      return cb()
    end
    pkg:install(
      nil,
      vim.schedule_wrap(function(ok)
        if ok then
          cb()
        else
          vim.notify("Failed to install tree-sitter-cli with mason", vim.log.levels.ERROR)
        end
      end)
    )
  end))
end

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile", "BufWritePre", "VeryLazy" },
    cmd = { "TSUpdate", "TSInstall", "TSLog", "TSUninstall" },
    opts_extend = { "ensure_installed" },
    opts = {
      install_dir = base.dir .. "/site",
      ensure_installed = {
        "bash",
        "c",
        "css",
        "diff",
        "gitignore",
        "go",
        "html",
        "javascript",
        "jsdoc",
        "json",
        "lua",
        "luadoc",
        "luap",
        "markdown",
        "markdown_inline",
        "printf",
        "python",
        "query",
        "regex",
        "rust",
        "toml",
        "tsx",
        "typescript",
        "vim",
        "vimdoc",
        "xml",
        "yaml",
      },
    },
    config = function(_, opts)
      local ts = require("nvim-treesitter")
      ts.setup({ install_dir = opts.install_dir })

      if base.install then
        local installed = {}
        for _, lang in ipairs(ts.get_installed("parsers")) do
          installed[lang] = true
        end
        local missing = vim.tbl_filter(function(lang)
          return not installed[lang]
        end, opts.ensure_installed)
        if #missing > 0 then
          with_cli(function()
            ts.install(missing, { summary = true })
          end)
        end
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("anvim.base.treesitter", { clear = true }),
        callback = function(ev)
          -- The prompt and the transcript start their own markdown parser.
          if ev.match == "anvim_input" or ev.match == "anvim_transcript" then
            return
          end
          local lang = vim.treesitter.language.get_lang(ev.match)
          -- Neovim's own parsers count too.
          if not (lang and vim.treesitter.language.add(lang)) then
            return
          end
          if vim.treesitter.query.get(lang, "highlights") then
            pcall(vim.treesitter.start, ev.buf, lang)
          end
          -- Folds are window options, so they go to the window that shows the
          -- buffer, and not to one that loaded it without showing it.
          if vim.treesitter.query.get(lang, "folds") and vim.api.nvim_get_current_buf() == ev.buf then
            vim.wo[0][0].foldmethod = "expr"
            vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
          end
        end,
      })
    end,
  },
}
