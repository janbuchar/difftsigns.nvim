--- Lifecycle: decides WHEN to ask difftastic for a verdict and wires the result
--- into the overlay. Knows nothing about difftastic's JSON.
---
--- We do not watch the buffer ourselves. gitsigns already does, and announces
--- `User GitSignsUpdate` whenever its hunks change; driving off that means we
--- can never compute a verdict against hunks it has since superseded, and a
--- buffer is eligible exactly when gitsigns is attached to it.
---
--- Our own debounce sits on top because gitsigns updates roughly every 100 ms
--- while typing and difftastic is an out-of-process parse plus graph diff.

local config = require("difftsigns.config")
local core = require("difftsigns.core")
local gs = require("difftsigns.gitsigns")
local overlay = require("difftsigns.overlay")
local verdict = require("difftsigns.verdict")
local debounce = require("difftsigns.debounce")

local M = {}

--- @class DifftSigns.Attached
--- @field inflight   DifftSigns.Job|nil
--- @field scheduler  fun()
--- @field timer      uv_timer_t
--- @field last_error string|nil   -- de-duplicates error notifications
local attached = {}

--- Report a problem once per distinct message per buffer (this runs on a debounce).
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

--- Run one update now. A run already in flight is cancelled: newest wins.
--- @param bufnr integer
function M.update(bufnr)
  local at = attached[bufnr]
  if at == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if not gs.attached(bufnr) then
    overlay.unavailable(bufnr, "gitsigns is not attached to this buffer")
    return
  end

  if not gs.signcolumn_enabled() then
    -- Sign-based overrides are invisible without a sign column.
    overlay.unavailable(bufnr, "gitsigns signcolumn is disabled; overlay has nothing to dim")
    return
  end

  local signs, hunks = gs.signs_for(bufnr)
  if signs == nil or hunks == nil then
    overlay.unavailable(bufnr, "could not read gitsigns hunks (internals changed?)")
    return
  end

  if #hunks == 0 then
    overlay.apply(bufnr, { verdicts = {}, unavailable = false }, {}, nil)
    return
  end

  local ref = gs.reference_text(bufnr)
  if ref == nil then
    -- Not computed yet; the next GitSignsUpdate brings us back.
    return
  end

  local new_text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Measured on the buffer, not the file on disk: the buffer is what gets diffed.
  local bytes = 0
  for _, l in ipairs(new_text) do
    bytes = bytes + #l + 1
  end
  if bytes > config.values.max_filesize then
    overlay.unavailable(bufnr, ("buffer exceeds max_filesize (%d bytes)"):format(bytes))
    return
  end

  -- If the buffer changes while difftastic runs, the verdict describes text and
  -- hunks that no longer exist; drop it and wait for the next GitSignsUpdate.
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)

  if at.inflight ~= nil then
    at.inflight.cancel()
  end

  at.inflight = core.run_diff(ref, new_text, {
    lang = vim.bo[bufnr].filetype,
    filename = vim.api.nvim_buf_get_name(bufnr),
    difft_cmd = config.values.difft_cmd,
    language_overrides = config.values.language_overrides,
    graph_limit = config.values.graph_limit,
  }, function(err, result)
    at.inflight = nil

    if err ~= nil then
      report(bufnr, err)
      overlay.unavailable(bufnr, "difftastic failed")
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr)
      or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
    then
      return
    end

    if result.fallback then
      overlay.unavailable(bufnr, result.fallback_reason
        or ("difftastic could not diff %s structurally"):format(tostring(result.language)))
      return
    end

    local set = verdict.compute(hunks, result)
    if set.unavailable then
      overlay.unavailable(bufnr, "no structural verdict available")
      return
    end

    overlay.apply(bufnr, set, signs, ref)
  end)
end

--- Request an update on the debounce.
--- @param bufnr integer
function M.schedule(bufnr)
  local at = attached[bufnr]
  if at ~= nil then
    at.scheduler()
  end
end

--- Begin annotating a buffer.
--- @param bufnr integer
function M.attach(bufnr)
  if attached[bufnr] ~= nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local scheduler, timer = debounce.debounce_trailing(config.values.debounce_ms, function()
    M.update(bufnr)
  end)

  attached[bufnr] = {
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

  -- Immediately, so the overlay appears on open rather than after the first edit.
  M.update(bufnr)
end

--- Stop annotating a buffer and release its resources.
--- @param bufnr integer
function M.detach(bufnr)
  local at = attached[bufnr]
  if at == nil then
    return
  end
  if at.inflight ~= nil then
    at.inflight.cancel()
  end
  pcall(function()
    at.timer:stop()
    at.timer:close()
  end)
  attached[bufnr] = nil
  overlay.forget(bufnr)
end

--- @param bufnr integer
--- @return boolean
function M.is_attached(bufnr)
  return attached[bufnr] ~= nil
end

--- Detach from every buffer (teardown / tests).
function M.detach_all()
  -- M.detach mutates `attached`; the entries hold timer userdata, so no deepcopy.
  for _, bufnr in ipairs(vim.tbl_keys(attached)) do
    M.detach(bufnr)
  end
end

return M
