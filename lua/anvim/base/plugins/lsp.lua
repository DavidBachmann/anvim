local base = require("anvim.base")

return {
  -- Server configs for vim.lsp.enable(). The lsp_ tools and gd, gr and K ask
  -- these servers.
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "mason-org/mason.nvim",
      { "mason-org/mason-lspconfig.nvim", config = function() end },
    },
    opts = {
      ---@type vim.diagnostic.Opts
      diagnostics = {
        underline = true,
        update_in_insert = false,
        virtual_text = false,
        virtual_lines = false,
        severity_sort = true,
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = base.icons.diagnostics.Error,
            [vim.diagnostic.severity.WARN] = base.icons.diagnostics.Warn,
            [vim.diagnostic.severity.HINT] = base.icons.diagnostics.Hint,
            [vim.diagnostic.severity.INFO] = base.icons.diagnostics.Info,
          },
        },
      },
      ---@type table<string, vim.lsp.Config>
      servers = {
        -- lua-language-server writes its logs and generated files into its
        -- own install dir, unless told otherwise.
        lua_ls = {
          cmd = {
            "lua-language-server",
            "--logpath=" .. vim.fn.stdpath("log") .. "/lua_ls",
            "--metapath=" .. vim.fn.stdpath("cache") .. "/lua_ls/meta",
          },
          settings = {
            Lua = {
              workspace = {
                checkThirdParty = false,
              },
            },
          },
        },
      },
    },
    config = function(_, opts)
      vim.diagnostic.config(vim.deepcopy(opts.diagnostics))
      -- Before mason-lspconfig enables the servers, which can start them at once.
      for name, server in pairs(opts.servers) do
        vim.lsp.config(name, server)
      end
      local plugin = require("lazy.core.config").plugins["mason-lspconfig.nvim"]
      require("mason-lspconfig").setup(require("lazy.core.plugin").values(plugin, "opts", false))
    end,
  },

  {
    "mason-org/mason.nvim",
    cmd = { "Mason", "MasonInstall", "MasonUninstall", "MasonUpdate", "MasonLog" },
    build = ":MasonUpdate",
    opts = {
      install_root_dir = base.dir .. "/mason",
      registry_cache = { refresh = base.install },
    },
  },

  -- Tells lua_ls about Neovim's runtime and the plugins that a file requires,
  -- so that `vim` is no undefined global.
  {
    "folke/lazydev.nvim",
    ft = "lua",
    cmd = "LazyDev",
    opts = {
      library = {
        { path = "${3rd}/luv/library", words = { "vim%.uv" } },
        { path = "snacks.nvim", words = { "Snacks" } },
      },
    },
  },

  -- Installs the servers and enables every server that mason installed.
  {
    "mason-org/mason-lspconfig.nvim",
    opts_extend = { "ensure_installed" },
    opts = {
      ensure_installed = base.install and { "vtsls", "lua_ls", "jsonls" } or {},
      automatic_enable = true,
    },
  },
}
