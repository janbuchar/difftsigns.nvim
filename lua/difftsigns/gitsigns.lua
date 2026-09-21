--- The gitsigns boundary: the only file that knows gitsigns exists.
---
--- We BORROW geometry rather than compute it. Taking hunks and reference text
--- from the same source makes a one-line drift between our verdict and
--- gitsigns' signs structurally impossible. The price is coupling to internals:
---
---   * `require("gitsigns").get_hunks(bufnr)`     -- PUBLIC
---   * `require("gitsigns.cache").cache[bufnr]`   -- INTERNAL: compare_text, hunks, git_obj
---   * `require("gitsigns.hunks").calc_signs(..)` -- INTERNAL, but pure
---   * `require("gitsigns.config").config`        -- semi-public: signs, sign_priority
---
--- Every access is wrapped; any missing piece makes us report unavailable and
--- the user is left with plain gitsigns.
---
--- `calc_signs` is borrowed rather than reimplemented because hunk -> sign type
--- (`add`/`change`/`delete`/`topdelete`/`changedelete`/`untracked`) has two code
--- paths behind a feature flag and must match gitsigns exactly or our override
--- lands on the wrong cell.

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

--- gitsigns' own line-based preview, for lines we have no structural verdict on.
function M.preview_hunk()
  local gitsigns = try_require("gitsigns")
  if gitsigns ~= nil and type(gitsigns.preview_hunk) == "function" then
    gitsigns.preview_hunk()
  end
end

--- @param bufnr integer
--- @return table|nil
local function cache_entry(bufnr)
  local c = try_require("gitsigns.cache")
  if c == nil or type(c.cache) ~= "table" then
    return nil
  end
  return c.cache[bufnr]
end

--- @return table|nil
local function gs_config()
  local c = try_require("gitsigns.config")
  if c == nil or type(c.config) ~= "table" then
    return nil
  end
  return c.config
end

--- @param bufnr integer
--- @return boolean
function M.attached(bufnr)
  return cache_entry(bufnr) ~= nil
end

--- The reference text gitsigns is diffing this buffer against, so difftastic
--- and gitsigns see the same "before" (including after `change_base`).
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

--- Unstaged hunks, from the cache rather than the public `get_hunks`: same
--- list, but the cache's carry `vend`, which `calc_signs` needs.
---
--- Staged hunks are not handled: gitsigns diffs those against a different base
--- (`compare_text_head`), which would need a second difftastic run.
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
--- Computed for the WHOLE buffer: gitsigns places signs lazily per window from
--- a decoration provider, so its placed extmarks only cover the visible range.
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

  -- calc_signs rejects a non-`add` hunk when untracked is true; mirror gitsigns'
  -- own determination.
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

--- @return integer
function M.sign_priority()
  local cfg = gs_config()
  if cfg ~= nil and type(cfg.sign_priority) == "number" then
    return cfg.sign_priority
  end
  return 6 -- gitsigns' documented default
end

--- The glyph gitsigns uses for a given sign type.
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

--- With `numhl`/`linehl` only, sign overrides are invisible.
--- @return boolean
function M.signcolumn_enabled()
  local cfg = gs_config()
  if cfg == nil then
    return true -- unknown; assume yes rather than disable ourselves
  end
  return cfg.signcolumn ~= false
end

return M
