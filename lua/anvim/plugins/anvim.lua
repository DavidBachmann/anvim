local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

-- ANVIM_REPLAY=<recording> plays a session that ANVIM_RECORD saved, at no API cost.
local replay = vim.env.ANVIM_REPLAY

return {
  {
    dir = root,
    name = "anvim",
    lazy = false,
    opts = {
      model = vim.env.ANVIM_MODEL,
      effort = vim.env.ANVIM_EFFORT,
      permission_mode = vim.env.ANVIM_MODE,
      resume = vim.env.ANVIM_RESUME,
      continue = vim.env.ANVIM_CONTINUE == "1",
      sandbox = vim.env.ANVIM_SANDBOX ~= "0",
      sidecar_cmd = replay and { "bun", root .. "/sidecar/src/replay.ts", replay, vim.env.ANVIM_REPLAY_SPEED or "1" },
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
