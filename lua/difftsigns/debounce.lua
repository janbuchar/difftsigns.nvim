--- debounce.lua
---
--- Trailing debounce + async throttle, after gitsigns' pattern. The debounce
--- turns "every keystroke" into "once you pause"; the throttle keeps the async
--- body from overlapping itself for one id.

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

-- id -> { running = bool, pending = bool }
local throttle_state = {}

--- Never run the async `fn` concurrently for the same id. A call arriving while
--- one is in flight queues at most ONE further run. `fn` MUST call `done` when
--- its async work completes.
--- @param fn fun(id: any, done: fun())
--- @return fun(id: any)
function M.throttle_by_id(fn)
  local function run(st, id)
    st.running = true
    fn(id, function()
      st.running = false
      if st.pending then
        st.pending = false
        run(st, id)
      end
    end)
  end

  return function(id)
    local st = throttle_state[id]
    if st == nil then
      st = { running = false, pending = false }
      throttle_state[id] = st
    end
    if st.running then
      st.pending = true
      return
    end
    run(st, id)
  end
end

--- Clear throttle bookkeeping for an id (on buffer detach).
--- @param id any
function M.forget(id)
  throttle_state[id] = nil
end

return M
