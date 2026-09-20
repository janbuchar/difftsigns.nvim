local M = {}

--- Coalesce a burst of calls into one call `ms` after the last.
--- @param ms integer
--- @param fn fun()
--- @return fun() debounced
--- @return uv_timer_t timer  -- exposed so callers can stop it on teardown
function M.debounce_trailing(ms, fn)
  local timer = assert(vim.uv.new_timer())
  -- Timer callbacks run in libuv's fast context; hop to the main loop.
  local fire = vim.schedule_wrap(fn)
  return function()
    timer:stop()
    timer:start(ms, 0, fire)
  end, timer
end

return M
