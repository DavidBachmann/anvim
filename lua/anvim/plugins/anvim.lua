return {
  {
    dir = require("anvim.base.install").root,
    name = "anvim",
    lazy = false,
    opts = {
      model = vim.env.ANVIM_MODEL,
      effort = vim.env.ANVIM_EFFORT,
      permission_mode = vim.env.ANVIM_MODE,
      resume = vim.env.ANVIM_RESUME,
      continue = vim.env.ANVIM_CONTINUE == "1",
      account = vim.env.ANVIM_ACCOUNT,
      sandbox = vim.env.ANVIM_SANDBOX ~= "0",
      debug = vim.env.ANVIM_DEBUG == "1",
      chrome = ({ ["1"] = true, ["0"] = false })[vim.env.ANVIM_CHROME or ""],
      codex = vim.env.ANVIM_CODEX == "1",
      -- ANVIM_REPLAY=<recording> plays a session that ANVIM_RECORD saved, at no API cost.
      replay = vim.env.ANVIM_REPLAY,
      replay_speed = tonumber(vim.env.ANVIM_REPLAY_SPEED),
    },
    config = function(_, opts)
      local anvim = require("anvim")
      anvim.setup(opts)
      if vim.v.vim_did_enter == 1 then
        anvim.start()
      else
        vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = anvim.start })
      end
    end,
  },
}
