--- attach.lua
---
--- Lifecycle: decides WHEN to ask difftastic for a verdict, and wires the result
--- into the overlay. Speaks Verdicts upward and borrows geometry sideways; knows
--- nothing about difftastic's JSON.
---
--- We do NOT watch the buffer ourselves. gitsigns already watches it, already
--- debounces, and already announces `User GitSignsUpdate` whenever its hunks
--- change. Driving off that event instead of our own `nvim_buf_attach` means we
--- can never compute a verdict against hunks gitsigns has already superseded —
--- the staleness class of bug is designed out rather than guarded against. It
--- also deletes a whole watcher, a whole debouncer, and the buffer-eligibility
--- guessing the PoC did (buftype, filename, visibility): if gitsigns is attached,
--- the buffer is eligible, by definition.
---
--- On top of gitsigns' event we still need our own debounce, because gitsigns
--- updates roughly every 100 ms while typing and difftastic is an out-of-process
--- tree-sitter parse plus a graph diff. See config.debounce_ms for the measured
--- basis of the default.

local config = require("difftsigns.config")
local core = require("difftsigns.core")
local gs = require("difftsigns.gitsigns")
local overlay = require("difftsigns.overlay")
local verdict = require("difftsigns.verdict")
local debounce = require("difftsigns.debounce")

local uv = vim.uv or vim.loop

local M = {}

--- @class DifftSigns.Attached
--- @field bufnr      integer
--- @field inflight   DifftSigns.Job|nil
--- @field scheduler  fun(bufnr: integer)
--- @field timer      uv_timer_t
--- @field last_error string|nil   -- de-duplicates error notifications
local attached = {}

--- Resolve Neovim's "0 means current buffer" convention. Our per-buffer tables are
--- keyed by real buffer number, so an unresolved 0 is a silently different key.
--- @param bufnr integer|nil
--- @return integer
local function resolve(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

--- Report a problem exactly once per distinct message per buffer.
---
--- The PoC's single worst habit was discarding every error it received: git.lua
--- carefully distinguished a real `git show` failure from an untracked file,
--- built an error string, and attach.lua dropped it on the floor. The result was
--- a class of bug that could only ever present as "no signs, no reason". We
--- surface instead — but only once, because this runs on a debounce.
--- @param bufnr integer
--- @param msg string
local function report(bufnr, msg)
  local at = attached[bufnr]
  if at ~= nil then
    if at.last_error == msg then
      return
    end
    at.last_error = msg
  end
  vim.notify(msg, vim.log.levels.WARN)
end

--- Note a benign reason for having no overlay. Not an error: an unsupported
--- language or an oversized file is an expected outcome, and the user simply
--- keeps plain gitsigns (REDESIGN R6).
--- @param bufnr integer
--- @param reason string
local function stand_down(bufnr, reason)
  overlay.unavailable(bufnr, reason)
end

--- Derive difftastic's language hint from the buffer's filetype.
--- @param bufnr integer
--- @return string|nil
local function lang_of(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == nil or ft == "" then
    return nil
  end
  return ft
end

--- One update pass. Async body, throttled by buffer.
--- @param bufnr integer
--- @param done fun()
local function do_update(bufnr, done)
  local at = attached[bufnr]
  if at == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    done()
    return
  end

  local ok, reason = gs.available()
  if not ok then
    stand_down(bufnr, reason or "gitsigns unavailable")
    done()
    return
  end

  if not gs.attached(bufnr) then
    -- gitsigns is not tracking this buffer, so there are no cells to annotate.
    stand_down(bufnr, "gitsigns is not attached to this buffer")
    done()
    return
  end

  if not gs.signcolumn_enabled() then
    -- Our overrides are sign-based; with gitsigns' signcolumn off they would be
    -- invisible. Say so rather than appear broken (REDESIGN §6.5).
    stand_down(bufnr, "gitsigns signcolumn is disabled; overlay has nothing to dim")
    done()
    return
  end

  local signs, hunks = gs.signs_for(bufnr)
  if signs == nil or hunks == nil then
    stand_down(bufnr, "could not read gitsigns hunks (internals changed?)")
    done()
    return
  end

  if #hunks == 0 then
    -- No hunks: nothing marked, nothing to demote. Clear any stale overlay.
    overlay.apply(bufnr, { verdicts = {}, unavailable = false }, {}, nil)
    done()
    return
  end

  local ref = gs.reference_text(bufnr)
  if ref == nil then
    -- gitsigns has not computed its reference yet. Not an error; the next
    -- GitSignsUpdate will bring us back.
    done()
    return
  end

  local new_text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Filesize guard, measured on the buffer rather than on disk: the buffer is
  -- what we are about to diff, and it may differ wildly from the saved file.
  local bytes = 0
  for _, l in ipairs(new_text) do
    bytes = bytes + #l + 1
  end
  if bytes > config.values.max_filesize then
    stand_down(bufnr, ("buffer exceeds max_filesize (%d bytes)"):format(bytes))
    done()
    return
  end

  -- Staleness guard: the buffer can change while difftastic runs. If it does,
  -- the verdict we get back describes text that no longer exists AND hunks that
  -- gitsigns has since recomputed, so applying it would mislabel lines. Drop it
  -- and wait for the next GitSignsUpdate.
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)

  if at.inflight ~= nil then
    at.inflight.cancel()
    at.inflight = nil
  end

  at.inflight = core.run_diff(ref, new_text, {
    lang = lang_of(bufnr),
    filename = vim.api.nvim_buf_get_name(bufnr),
    difft_cmd = config.values.difft_cmd,
    language_overrides = config.values.language_overrides,
    graph_limit = config.values.graph_limit,
  }, function(err, result)
    at.inflight = nil

    if err ~= nil then
      report(bufnr, err)
      stand_down(bufnr, "difftastic failed")
      done()
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      done()
      return
    end

    if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      done() -- stale; a fresh update is already on its way
      return
    end

    if result.fallback then
      -- Say WHY, not just that. "difftastic hit its graph limit" is actionable
      -- (raise graph_limit); "no structural parser for this file type" is not.
      stand_down(bufnr, result.fallback_reason
        or ("difftastic could not diff %s structurally"):format(tostring(result.language)))
      done()
      return
    end

    local set = verdict.compute(hunks, result)
    if set.unavailable then
      stand_down(bufnr, "no structural verdict available")
      done()
      return
    end

    overlay.apply(bufnr, set, signs, ref)
    done()
  end)

  if at.inflight == nil then
    -- Spawn failed synchronously; core/process already reported why.
    done()
  end
end

-- Throttled by bufnr so overlapping updates cannot interleave; at most one
-- further run is queued while one is in flight, and stale intermediates drop.
local throttled = debounce.throttle_by_id(function(bufnr, done)
  do_update(bufnr, done)
end)

--- Request an update immediately (still throttled).
--- @param bufnr integer
function M.update(bufnr)
  bufnr = resolve(bufnr)
  throttled(bufnr)
end

--- Request an update on the debounce.
--- @param bufnr integer
function M.schedule(bufnr)
  bufnr = resolve(bufnr)
  local at = attached[bufnr]
  if at ~= nil then
    at.scheduler(bufnr)
  end
end

--- Begin annotating a buffer.
--- @param bufnr integer
function M.attach(bufnr)
  bufnr = resolve(bufnr)
  if attached[bufnr] ~= nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local scheduler, timer = debounce.debounce_trailing(config.values.debounce_ms, function(b)
    M.update(b)
  end)

  attached[bufnr] = {
    bufnr = bufnr,
    inflight = nil,
    scheduler = scheduler,
    timer = timer,
    last_error = nil,
  }

  if config.values.on_attach ~= nil then
    local ok, err = pcall(config.values.on_attach, bufnr)
    if not ok then
      report(bufnr, "difftsigns: on_attach failed: " .. tostring(err))
    end
  end

  -- First pass immediately, so the overlay appears on open rather than after the
  -- first edit.
  M.update(bufnr)
end

--- Stop annotating a buffer and release its resources.
--- @param bufnr integer
function M.detach(bufnr)
  bufnr = resolve(bufnr)
  local at = attached[bufnr]
  if at == nil then
    return
  end
  if at.inflight ~= nil then
    at.inflight.cancel()
  end
  if at.timer ~= nil then
    pcall(function()
      at.timer:stop()
      at.timer:close()
    end)
  end
  attached[bufnr] = nil
  debounce.forget(bufnr)
  overlay.forget(bufnr)
end

--- @param bufnr integer
--- @return boolean
function M.is_attached(bufnr)
  bufnr = resolve(bufnr)
  return attached[bufnr] ~= nil
end

--- Detach from every buffer (teardown / tests).
function M.detach_all()
  -- Collect keys first: M.detach mutates `attached`, and the entries hold libuv
  -- timer userdata so they cannot be deepcopied.
  local bufnrs = vim.tbl_keys(attached)
  for _, bufnr in ipairs(bufnrs) do
    M.detach(bufnr)
  end
end

return M
