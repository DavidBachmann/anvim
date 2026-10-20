-- Desktop notifications while Neovim does not have focus: when Claude is done
-- or needs an answer. Inside cmux they go through `cmux notify`, elsewhere
-- through OSC 9, which many terminals show as a notification.
local state = require("anvim.state")

local M = {}

local api = vim.api

-- Neovim reports focus only after the terminal sends a focus event, so start
-- out focused and never notify a user who is looking.
M.focused = true
-- Seams for the tests.
M.system = vim.system
M.ui_send = function(text)
  api.nvim_ui_send(text)
end

local function cmux()
  if not (vim.env.CMUX_SOCKET_PATH and vim.env.CMUX_SURFACE_ID) then
    return
  end
  local bin = vim.fn.exepath("cmux")
  if bin == "" and vim.env.CMUX_BUNDLED_CLI_PATH and vim.fn.executable(vim.env.CMUX_BUNDLED_CLI_PATH) == 1 then
    bin = vim.env.CMUX_BUNDLED_CLI_PATH
  end
  return bin ~= "" and bin or nil
end

local function osc9(text)
  M.ui_send("\27]9;" .. text:gsub("%c", " ") .. "\7")
end

function M.send(text)
  if M.focused then
    return
  end
  local bin = cmux()
  if not bin then
    osc9(text)
    return
  end
  local cmd = { bin, "notify", "--surface", vim.env.CMUX_SURFACE_ID, "--title", "anvim", "--body", text }
  M.system(cmd, { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        osc9(text)
      end)
    end
  end)
end

local function first_line(text)
  local line = vim.trim(text or ""):match("^[^\n]*")
  return vim.fn.strchars(line) > 80 and vim.fn.strcharpart(line, 0, 77) .. "..." or line
end

function M.attach(sidecar)
  local group = api.nvim_create_augroup("anvim.notify", {})
  api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      M.focused = true
    end,
  })
  api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function()
      M.focused = false
    end,
  })
  sidecar.on("turn_end", function(ev)
    -- Slash commands such as /clear end a turn without asking the model.
    if (ev.num_turns or 0) == 0 then
      return
    end
    local project = vim.fs.basename(state.cwd)
    if ev.is_error then
      M.send(("Claude stopped with an error in %s"):format(project))
    else
      local reply = first_line(require("anvim.transcript").last_reply())
      M.send(reply ~= "" and ("%s: %s"):format(project, reply) or "Claude is waiting for your input")
    end
  end)
  sidecar.on("permission_request", function(ev)
    if ev.tool == "AskUserQuestion" then
      M.send("Claude has a question for you")
    elseif ev.tool == "ExitPlanMode" then
      M.send("Claude has a plan for you to review")
    else
      M.send("Claude needs your permission to use " .. ev.tool)
    end
  end)
  sidecar.on("exit", function(ev)
    if not ev.restart then
      M.send("Claude's sidecar exited. Run :AnvimRestart")
    end
  end)
end

return M
