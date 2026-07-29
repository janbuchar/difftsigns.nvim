--- attach.lua
---
--- The working-buffer adapter (spec §7): new side = live buffer lines, old side
--- = reference text resolved from `compare_base`. Orchestrates buffer watching,
--- debounce, the filesize guard, job cancellation, and the deferred-when-hidden
--- optimization. Speaks the internal Region type to signs.lua and calls the
--- revision-agnostic core; knows nothing about difft's JSON.

local config = require("dft-signs.config")
local core = require("dft-signs.core")
local signs = require("dft-signs.signs")
local git = require("dft-signs.git")
local debounce = require("dft-signs.debounce")

local uv = vim.uv or vim.loop

local M = {}

--- @class DftSigns.Attached
--- @field bufnr integer
--- @field compare_base string
--- @field inflight DftSigns.Job|nil   -- current difft job, for cancellation
--- @field dirty boolean               -- update requested while hidden
--- @field scheduler fun(bufnr: integer)  -- debounced trigger
--- @field timer uv_timer_t
local attached = {}

--- Is this buffer eligible for structural signs?
--- @param bufnr integer
--- @return boolean
local function eligible(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false -- not a normal file buffer
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return false
  end
  return true
end

--- Is the buffer currently displayed in any window? (spec §5: no work when not
--- visible.)
--- @param bufnr integer
--- @return boolean
local function is_visible(bufnr)
  return #vim.fn.win_findbuf(bufnr) > 0
end

--- Run one structural update for a buffer. This is the async body throttled by
--- id in `attach`.
--- @param bufnr integer
--- @param done fun()
local function do_update(bufnr, done)
  local at = attached[bufnr]
  if at == nil or not eligible(bufnr) then
    done()
    return
  end

  -- Defer when hidden; flushed on BufEnter/TabEnter (spec §5).
  if not is_visible(bufnr) then
    at.dirty = true
    done()
    return
  end
  at.dirty = false

  local path = vim.api.nvim_buf_get_name(bufnr)

  -- Filesize guard (spec §5): skip past difft's own byte-limit rather than
  -- render a mislabeled line-diff fallback.
  local stat = uv.fs_stat(path)
  if stat ~= nil and stat.size > config.values.max_filesize then
    signs.clear(bufnr)
    done()
    return
  end

  local new_text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lang = vim.bo[bufnr].filetype
  lang = (lang ~= nil and lang ~= "") and lang or nil

  --- Once we have the reference text, run the diff.
  local function with_reference(old_text)
    -- Cancel any still-running job before starting a fresh one (spec §5).
    if at.inflight ~= nil then
      at.inflight.cancel()
      at.inflight = nil
    end

    at.inflight = require("dft-signs.process").run(old_text, new_text, {
      lang = lang,
      filename = path,
      difft_cmd = config.values.difft_cmd,
      language_overrides = config.values.language_overrides,
    }, function(err, json_str)
      at.inflight = nil
      if err ~= nil then
        -- Silent-ish: one message, then leave stale signs cleared.
        done()
        return
      end
      local ok, decoded = pcall(vim.json.decode, json_str)
      if not ok or type(decoded) ~= "table" then
        done()
        return
      end
      local parse_ok, result = pcall(core.parse, decoded)
      if not parse_ok then
        done()
        return
      end

      -- Language fallback (spec §9.4): if difft fell back to a line diff, we
      -- clear rather than lie about structural signs.
      if result.fallback then
        signs.clear(bufnr)
        done()
        return
      end

      if result.status == "unchanged" then
        signs.clear(bufnr)
      else
        -- Pass the reference text through so the span preview can show the
        -- actual "was" source lines, not difft's context-free tokens.
        signs.set_regions(bufnr, result.regions, old_text)
      end
      done()
    end)

    if at.inflight == nil then
      -- Spawn failed synchronously (already reported by process.run).
      done()
    end
  end

  -- Resolve reference. 'save' reads the file from disk (last saved state);
  -- everything else goes through git as a content store.
  if at.compare_base == "save" then
    local fd = uv.fs_open(path, "r", 420)
    if fd == nil then
      with_reference({})
      return
    end
    local st = uv.fs_fstat(fd)
    local data = uv.fs_read(fd, st.size, 0) or ""
    uv.fs_close(fd)
    local lines = vim.split(data, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    with_reference(lines)
  else
    git.reference_text(path, at.compare_base, function(err, ref_lines)
      if err ~= nil or ref_lines == nil then
        -- Not in a repo / no reference: nothing to compare against.
        signs.clear(bufnr)
        done()
        return
      end
      with_reference(ref_lines)
    end)
  end
end

-- Throttled-by-bufnr update so overlapping debounce ticks can't interleave.
local throttled_update = debounce.throttle_by_id(function(bufnr, done)
  do_update(bufnr, done)
end)

--- Public: request an update for a buffer (goes through throttle).
--- @param bufnr integer
function M.update(bufnr)
  throttled_update(bufnr)
end

--- Attach structural signs to a buffer.
--- @param bufnr integer
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if attached[bufnr] ~= nil or not eligible(bufnr) then
    return
  end

  local scheduler, timer = debounce.debounce_trailing(config.values.debounce_ms, function(b)
    M.update(b)
  end)

  attached[bufnr] = {
    bufnr = bufnr,
    compare_base = config.values.compare_base,
    inflight = nil,
    dirty = false,
    scheduler = scheduler,
    timer = timer,
  }

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b)
      if attached[b] == nil then
        return true -- detach callback
      end
      attached[b].scheduler(b)
    end,
    on_detach = function(_, b)
      M.detach(b)
    end,
  })

  if config.values.on_attach ~= nil then
    pcall(config.values.on_attach, bufnr)
  end

  -- Kick an initial update immediately (not debounced) so signs appear on open.
  M.update(bufnr)
end

--- Detach from a buffer and clean up all its resources.
--- @param bufnr integer
function M.detach(bufnr)
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
  signs.forget(bufnr)
  signs.clear(bufnr)
end

--- Change the comparison base for a buffer (`:DftSigns change_base <rev>`).
--- @param bufnr integer
--- @param rev string
function M.change_base(bufnr, rev)
  local at = attached[bufnr]
  if at == nil then
    return
  end
  at.compare_base = rev
  M.update(bufnr)
end

--- Flush any buffers deferred while hidden (spec §5). Called on BufEnter/TabEnter.
--- @param bufnr integer
function M.flush_if_dirty(bufnr)
  local at = attached[bufnr]
  if at ~= nil and at.dirty then
    M.update(bufnr)
  end
end

--- Is a buffer attached? (test/introspection helper)
--- @param bufnr integer
--- @return boolean
function M.is_attached(bufnr)
  return attached[bufnr] ~= nil
end

return M
