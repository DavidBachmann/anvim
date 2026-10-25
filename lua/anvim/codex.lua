-- The model and the reasoning effort that anvim asks Codex runs for, over
-- Codex's own config. /codex-model and /codex-effort set them, prefs.json
-- keeps them, and a run of Claude's codex tool can set its own.
local prefs = require("anvim.prefs")
local sidecar = require("anvim.sidecar")
local state = require("anvim.state")
local transcript = require("anvim.transcript")

local M = {}

-- The picker's levels. A typed level goes to Codex as it is, so a newer one works too.
M.levels = { "low", "medium", "high", "xhigh", "max" }
-- The models that the model picker offers, at most.
M.recent_max = 5

---@return string?
function M.model()
  return prefs.get("codex_model")
end

---@return string?
function M.effort()
  return prefs.get("codex_effort")
end

---@return string[]
function M.recent()
  local list = prefs.get("codex_models")
  return type(list) == "table" and list or {}
end

-- "default", with what Codex's config.toml sets, when the sidecar could read it.
---@param key 'model'|'effort'
---@return string
function M.default_label(key)
  local value = state.codex_config and state.codex_config[key]
  return value and ("default (Codex's config: %s)"):format(value) or "default"
end

local function send()
  sidecar.send({ type = "set_codex_defaults", model = M.model() or vim.NIL, effort = M.effort() or vim.NIL })
end

---@param model string? Nil leaves it to Codex's config.
function M.set_model(model)
  prefs.set("codex_model", model)
  if model then
    prefs.update("codex_models", function(list)
      local recent = { model }
      for _, m in ipairs(type(list) == "table" and list or {}) do
        if m ~= model and #recent < M.recent_max then
          recent[#recent + 1] = m
        end
      end
      return recent
    end)
  end
  send()
  transcript.notice("info", "Set the Codex model to " .. (model or M.default_label("model")))
end

---@param level string? Nil leaves it to Codex's config.
function M.set_effort(level)
  prefs.set("codex_effort", level)
  send()
  transcript.notice("info", "Set the Codex effort to " .. (level or M.default_label("effort")))
end

---@param prompt string
---@param items string[] without "default"
---@param current string?
---@param key 'model'|'effort'
---@param set fun(value: string?)
local function pick(prompt, items, current, key, set)
  vim.ui.select(vim.list_extend({ "default" }, items), {
    prompt = prompt,
    format_item = function(item)
      local mark = (item == "default" and not current or item == current) and "⏺ " or "  "
      return mark .. (item == "default" and M.default_label(key) or item)
    end,
  }, function(choice)
    if choice then
      set(choice ~= "default" and choice or nil)
    end
  end)
end

function M.pick_model()
  pick("Codex model · /codex-model <name> sets another", M.recent(), M.model(), "model", M.set_model)
end

function M.pick_effort()
  pick("Codex effort", M.levels, M.effort(), "effort", M.set_effort)
end

-- A word goes to Codex as a flag's value, so it must not look like a flag.
local function valid(word)
  return word:match("^[%w_][%w_.:/-]*$") ~= nil
end

-- /codex-model, /codex-model <model> and /codex-model default.
---@param arg string
function M.model_command(arg)
  if arg == "" then
    M.pick_model()
  elseif arg == "default" then
    M.set_model(nil)
  elseif not valid(arg) then
    transcript.notice("info", "/codex-model takes the name of a Codex model, or default.")
  else
    M.set_model(arg)
  end
end

-- /codex-effort, /codex-effort <level> and /codex-effort default.
---@param arg string
function M.effort_command(arg)
  local level = arg:lower()
  if level == "" then
    M.pick_effort()
  elseif level == "default" then
    M.set_effort(nil)
  elseif not valid(level) then
    transcript.notice("info", "/codex-effort takes a level, such as low or high, or default.")
  else
    M.set_effort(level)
  end
end

-- What the next Codex run uses, for :checkhealth.
---@return string
function M.describe()
  local config = state.codex_config or {}
  local function part(what, mine, theirs)
    if mine then
      return ("the %s %s (anvim's default)"):format(what, mine)
    elseif theirs then
      return ("the %s %s (Codex's config)"):format(what, theirs)
    end
    return ("Codex's default %s"):format(what)
  end
  return ("Codex runs with %s and %s"):format(
    part("model", M.model(), config.model),
    part("effort", M.effort(), config.effort)
  )
end

return M
