--- gitsigns.lua
---
--- The gitsigns quarantine boundary (REDESIGN §4). This is the ONLY file in the
--- plugin that knows gitsigns exists. Everything above it speaks Verdicts.
---
--- We deliberately BORROW geometry rather than compute it. Resolving the git
--- reference ourselves and running our own `vim.diff` would decouple us, but it
--- would trade a *breakage* class for a *correctness* class — and correctness is
--- worse. If our hunk boundaries drifted from gitsigns' by one line, we would
--- silently mislabel which change matters, in a plugin whose entire purpose is
--- labelling which change matters. Taking the hunks and the reference text from
--- the same source makes that misalignment structurally impossible.
---
--- The price is coupling, some of it to internals:
---
---   * `require("gitsigns").get_hunks(bufnr)`     -- PUBLIC, documented
---   * `require("gitsigns.cache").cache[bufnr]`   -- INTERNAL: compare_text, hunks, git_obj
---   * `require("gitsigns.hunks").calc_signs(..)` -- INTERNAL, but a PURE function
---   * `require("gitsigns.config").config`        -- semi-public: signs, sign_priority
---
--- Mitigation is uniform: every access is wrapped, and any missing piece makes
--- us report unavailable. We go INERT, never wrong (REDESIGN R6) — the user then
--- simply has plain gitsigns, which is a harmless outcome.
---
--- On borrowing `calc_signs` rather than reimplementing it: mapping hunks to
--- per-line sign types (`add`/`change`/`delete`/`topdelete`/`changedelete`/
--- `untracked`) is genuinely fiddly, has two code paths behind a feature flag,
--- and must match gitsigns EXACTLY or our override lands on the wrong cell or
--- with the wrong glyph. Reimplementing it would be a slow-motion bug. It is a
--- pure function of hunks; borrowing it is the lowest-risk option available.

local M = {}

--- @param mod string
--- @return table|nil
local function try_require(mod)
  local ok, m = pcall(require, mod)
  if not ok or type(m) ~= "table" then
    return nil
  end
  return m
end

--- Is gitsigns present and functional enough to annotate?
--- @return boolean
--- @return string|nil reason  -- populated when unavailable, for :checkhealth
function M.available()
  if try_require("gitsigns") == nil then
    return false, "gitsigns.nvim is not installed or not loaded"
  end
  if try_require("gitsigns.cache") == nil then
    return false, "gitsigns.cache is unavailable (gitsigns internals changed?)"
  end
  local hunks = try_require("gitsigns.hunks")
  if hunks == nil or type(hunks.calc_signs) ~= "function" then
    return false, "gitsigns.hunks.calc_signs is missing (gitsigns internals changed?)"
  end
  return true, nil
end

--- The gitsigns cache entry for a buffer, or nil.
--- @param bufnr integer
--- @return table|nil
local function cache_entry(bufnr)
  local c = try_require("gitsigns.cache")
  if c == nil or type(c.cache) ~= "table" then
    return nil
  end
  return c.cache[bufnr]
end

--- gitsigns' config table, or nil.
--- @return table|nil
local function gs_config()
  local c = try_require("gitsigns.config")
  if c == nil or type(c.config) ~= "table" then
    return nil
  end
  return c.config
end

--- Is gitsigns attached to this buffer?
--- @param bufnr integer
--- @return boolean
function M.attached(bufnr)
  return cache_entry(bufnr) ~= nil
end

--- The reference text gitsigns is diffing this buffer against.
---
--- Taking this rather than resolving `git show` ourselves is what guarantees
--- difftastic and gitsigns are looking at the same "before". It also means we
--- follow gitsigns' base automatically, including after its `change_base`.
--- @param bufnr integer
--- @return string[]|nil
function M.reference_text(bufnr)
  local entry = cache_entry(bufnr)
  if entry == nil then
    return nil
  end
  local text = entry.compare_text
  if type(text) ~= "table" then
    return nil -- not computed yet; caller retries on the next GitSignsUpdate
  end
  return text
end

--- The unstaged hunks gitsigns computed for this buffer. Taken from the cache
--- rather than the public `get_hunks`: same list, but the cache's carry `vend`,
--- which `calc_signs` needs.
---
--- Staged hunks are deliberately NOT handled: gitsigns diffs those against a
--- different base (`compare_text_head`), so judging them would require a second
--- difftastic run against a second reference. Documented limitation.
--- @param bufnr integer
--- @return table[]|nil
function M.hunks(bufnr)
  local entry = cache_entry(bufnr)
  if entry ~= nil and type(entry.hunks) == "table" then
    return entry.hunks
  end
  return nil
end

--- Every sign gitsigns would place in this buffer, with the hunk each came from.
---
--- Computed for the WHOLE buffer (1..huge) rather than a viewport. gitsigns
--- itself places signs lazily per window from a decoration provider, so reading
--- its placed extmarks would only ever reveal the visible ones — and would make
--- us depend on decoration-provider ordering. Asking `calc_signs` directly for
--- the full range avoids both problems.
---
--- @param bufnr integer
--- @return { lnum: integer, type: string, count: integer|nil, hunk_index: integer }[]|nil
--- @return table[]|nil hunks  -- the hunk list the indices refer to
function M.signs_for(bufnr)
  local hunks = M.hunks(bufnr)
  if hunks == nil then
    return nil, nil
  end

  local H = try_require("gitsigns.hunks")
  if H == nil or type(H.calc_signs) ~= "function" then
    return nil, nil
  end

  -- gitsigns renders an untracked file's hunks with the `untracked` glyph, and
  -- calc_signs rejects a non-`add` hunk when untracked is true. Mirror its own
  -- determination exactly.
  local entry = cache_entry(bufnr)
  local untracked = false
  if entry ~= nil and type(entry.git_obj) == "table" then
    untracked = entry.git_obj.object_name == nil
  end

  local out = {}
  for i, h in ipairs(hunks) do
    local ok, signs = pcall(H.calc_signs, hunks[i - 1], h, hunks[i + 1], 1, math.huge, untracked)
    if ok and type(signs) == "table" then
      for _, s in ipairs(signs) do
        if type(s) == "table" and type(s.lnum) == "number" then
          out[#out + 1] = {
            lnum = s.lnum,
            type = s.type,
            count = s.count,
            hunk_index = i,
          }
        end
      end
    end
  end
  return out, hunks
end

--- The extmark priority gitsigns places its signs at. We must beat it.
--- @return integer
function M.sign_priority()
  local cfg = gs_config()
  if cfg ~= nil and type(cfg.sign_priority) == "number" then
    return cfg.sign_priority
  end
  return 6 -- gitsigns' documented default
end

--- The glyph gitsigns uses for a given sign type.
---
--- Mirroring the glyph means our override changes only the COLOUR of the cell,
--- not its shape — so a dimmed hunk still reads as the same kind of change.
--- @param sign_type string
--- @return string|nil
function M.sign_text(sign_type)
  local cfg = gs_config()
  if cfg == nil or type(cfg.signs) ~= "table" then
    return nil
  end
  local entry = cfg.signs[sign_type]
  if type(entry) ~= "table" or type(entry.text) ~= "string" then
    return nil
  end
  return entry.text
end

--- Would gitsigns render anything in the sign column at all? If the user runs
--- `numhl`/`linehl` only, our sign overrides are invisible and we should say so
--- rather than silently do nothing (REDESIGN §6.5).
--- @return boolean
function M.signcolumn_enabled()
  local cfg = gs_config()
  if cfg == nil then
    return true -- unknown; assume yes rather than disable ourselves
  end
  return cfg.signcolumn ~= false
end

return M
