-- The spinners of running agents. They all take their frame from one clock,
-- so they turn together. The focused agent's spinner is a half circle, where
-- an agent at rest would show ◉.
local M = {}

M.frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.focus_frames = { "◐", "◓", "◑", "◒" }
-- The timer's tick, in ms. A braille frame lasts one tick, and a half circle
-- two. Whole ticks keep each spinner's pace even.
M.tick = 80
-- Specs replace it.
M.clock = vim.uv.now

---@param focused boolean?
---@return string
function M.frame(focused)
  local frames = focused and M.focus_frames or M.frames
  local ms = focused and 2 * M.tick or M.tick
  return frames[math.floor(M.clock() / ms) % #frames + 1]
end

-- Calls `draw` on each frame while `spins()` holds. The first frame after it
-- stops holding draws too, and stops the timer. Call the returned function
-- when spinners may have come.
---@param spins fun(): boolean
---@param draw fun()
---@return fun() sync
function M.animate(spins, draw)
  local timer ---@type uv.uv_timer_t?
  local function sync()
    if not spins() then
      if timer then
        timer:stop()
      end
    elseif not (timer and timer:is_active()) then
      timer = timer or assert(vim.uv.new_timer())
      timer:start(
        M.tick,
        M.tick,
        vim.schedule_wrap(function()
          local ok, err = pcall(draw)
          if not ok then
            -- One error, not one on each frame.
            timer:stop()
            error(err, 0)
          end
          sync()
        end)
      )
    end
  end
  return sync
end

return M
