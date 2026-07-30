--- debounce.lua
---
--- Trailing debounce + async throttle, ported from gitsigns' proven pattern
--- (REDESIGN §6). Two primitives:
---
---   * debounce_trailing(ms, fn): coalesces a burst of calls into one call that
---     fires `ms` after the LAST call. This is what turns "every keystroke" into
---     "once you pause" (REDESIGN §6, 1.5s default).
---
---   * throttle_by_id(fn): ensures an async `fn` for a given id never runs
---     concurrently with itself. If a call arrives while one is in flight, at
---     most ONE more run is scheduled after the current one finishes (stale
---     intermediate requests are dropped). This is gitsigns' throttle_async
---     with a hash key.

local uv = vim.uv or vim.loop

local M = {}

--- @param ms integer
--- @param fn fun(...)
--- @return fun(...) debounced  -- call to schedule; last call within window wins
--- @return uv_timer_t timer    -- exposed so callers can stop it on teardown
function M.debounce_trailing(ms, fn)
  local timer = assert(uv.new_timer())
  local last_args = nil

  local function wrapped(...)
    last_args = { ... }
    -- Reschedule: stop any pending fire and start a fresh window.
    timer:stop()
    timer:start(ms, 0, function()
      timer:stop()
      local args = last_args
      last_args = nil
      -- Timer callbacks run in libuv fast context; hop to main loop so fn can
      -- freely call the Neovim API.
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end

  return wrapped, timer
end

-- id -> { running = bool, pending = bool, pending_args = table|nil }
local throttle_state = {}

--- Throttle an ASYNC function by id. `fn` receives its normal args plus a final
--- `done` callback it MUST invoke when the async work completes.
---
--- @param fn fun(id: any, ..., done: fun())
--- @return fun(id: any, ...)
function M.throttle_by_id(fn)
  return function(id, ...)
    local args = { ... }
    local st = throttle_state[id]
    if st == nil then
      st = { running = false, pending = false, pending_args = nil }
      throttle_state[id] = st
    end

    if st.running then
      -- Something is already in flight. Remember only the LATEST request; drop
      -- any earlier pending one (stale). At most one run is queued.
      st.pending = true
      st.pending_args = args
      return
    end

    local function run(call_args)
      st.running = true
      local function done()
        st.running = false
        if st.pending then
          st.pending = false
          local next_args = st.pending_args
          st.pending_args = nil
          run(next_args)
        end
      end
      -- Build the full argv: id, the caller's args, then `done` LAST. We must
      -- not put `unpack()` mid-list — Lua truncates it to a single value there,
      -- which would drop `done`. Assemble a flat table and unpack once at the end.
      local argv = { id }
      for _, v in ipairs(call_args) do
        table.insert(argv, v)
      end
      table.insert(argv, done)
      fn(unpack(argv))
    end

    run(args)
  end
end

--- Clear throttle bookkeeping for an id (on buffer detach).
--- @param id any
function M.forget(id)
  throttle_state[id] = nil
end

return M
