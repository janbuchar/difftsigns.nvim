--- verdict.lua
---
--- The join: gitsigns' hunk geometry x difftastic's structural verdict.
--- This is the heart of the plugin and the only genuinely novel logic in it.
---
--- PURE BY MANDATE (REDESIGN §5). No Neovim API, no IO, no subprocess, no
--- require of gitsigns. Plain tables in, plain tables out. This is deliberate:
--- the hard cases here (deletion anchoring, changedelete markers) are exactly
--- the ones that produce off-by-one verdicts on the wrong line, so they must be
--- the cheapest thing in the tree to test exhaustively.
---
--- The asymmetry that governs every decision in this file: **wrongly dimming a
--- real change is much worse than failing to dim noise.** A missed dim is a
--- cosmetic disappointment; a wrong dim actively hides a real change from
--- review. Every ambiguous case therefore resolves to "significant".

local M = {}

--- @class DifftSigns.Verdict
--- @field hunk               table    -- gitsigns' hunk, PASSED THROUGH UNMODIFIED
--- @field significant        boolean  -- rollup: does anything real happen in this hunk?
--- @field lines              table<integer, boolean>  -- buffer line -> significant?
--- @field anchor_significant boolean  -- verdict for reference-only (deleted) content
--- @field delete_marker_line integer|nil  -- buffer line carrying deletion semantics
--- @field edits              DifftSigns.Edit[]  -- edits attributable to this hunk
--- @field no_token_detail    boolean  -- true when difftastic supplied no chunks at all

--- @class DifftSigns.VerdictSet
--- @field verdicts    DifftSigns.Verdict[]
--- @field unavailable boolean  -- no structural answer; caller must place nothing

--- Last buffer line of a hunk's "changed" portion.
---
--- Mirrors gitsigns' internal `change_end`. Reproduced rather than imported so
--- this file stays pure; pinned by tests against gitsigns' real sign placement.
--- @param hunk table
--- @return integer
local function change_end(hunk)
  local added, removed = hunk.added, hunk.removed
  if added.count == 0 then
    return added.start -- delete: the anchor line in the buffer
  elseif removed.count == 0 then
    return added.start + added.count - 1 -- add
  end
  return added.start + math.min(added.count, removed.count) - 1 -- change
end

--- Compute verdicts for a whole buffer.
---
--- @param hunks table[]  -- gitsigns hunks: { type, added={start,count}, removed={start,count} }
--- @param diff DifftSigns.DiffResult
--- @return DifftSigns.VerdictSet
function M.compute(hunks, diff)
  if type(hunks) ~= "table" or type(diff) ~= "table" then
    return { verdicts = {}, unavailable = true }
  end

  -- No structural answer available. Critically we must NOT return an empty
  -- verdict set here: empty verdicts read as "nothing is significant", which
  -- would dim every real change in the buffer. Refusing to answer means the
  -- caller places nothing and the user sees plain gitsigns (REDESIGN R6).
  if diff.fallback then
    return { verdicts = {}, unavailable = true }
  end

  local all = diff.all_significant == true
  local changed_rhs = diff.changed_rhs or {}
  local changed_lhs = diff.changed_lhs or {}

  -- Bucket edits by side/line once, so attributing them to hunks is O(1) per
  -- line rather than O(edits) per hunk.
  local edits_by_side = { lhs = {}, rhs = {} }
  for _, e in ipairs(diff.edits or {}) do
    local bucket = edits_by_side[e.side]
    if bucket ~= nil then
      bucket[e.line] = bucket[e.line] or {}
      table.insert(bucket[e.line], e)
    end
  end

  local verdicts = {}

  for _, hunk in ipairs(hunks) do
    local added, removed = hunk.added, hunk.removed
    if type(added) == "table" and type(removed) == "table" then
      local lines = {}
      local edits = {}
      local significant = false

      -- Buffer-side lines: judged directly by difftastic's rhs verdict. This is
      -- where a reindented line gets dimmed and an edited line does not.
      for lnum = added.start, added.start + added.count - 1 do
        local sig = all or changed_rhs[lnum] == true
        lines[lnum] = sig
        significant = significant or sig
        for _, e in ipairs(edits_by_side.rhs[lnum] or {}) do
          table.insert(edits, e)
        end
      end

      -- Reference-only content (whole or partial deletions) has no buffer line
      -- of its own. Judge it from difftastic's lhs verdict over the removed
      -- range, and carry that as a separate anchor verdict.
      local anchor_significant = all
      for lnum = removed.start, removed.start + removed.count - 1 do
        if changed_lhs[lnum] == true then
          anchor_significant = true
        end
        for _, e in ipairs(edits_by_side.lhs[lnum] or {}) do
          table.insert(edits, e)
        end
      end

      -- A `delete` hunk removes lines without adding any: it is significant iff
      -- the removed content was structurally real.
      if added.count == 0 then
        significant = significant or anchor_significant
      end

      -- gitsigns draws `changedelete` on the LAST changed line of a hunk that
      -- removed more lines than it added. That one cell carries deletion
      -- semantics on top of its own line's verdict, so it must be able to stay
      -- lit when the deletion was real even if the line itself only reflowed.
      -- Getting this wrong silently hides deletions; hence the special case.
      local delete_marker_line = nil
      if added.count > 0 and removed.count > added.count then
        delete_marker_line = change_end(hunk)
        significant = significant or anchor_significant
      end

      verdicts[#verdicts + 1] = {
        hunk = hunk,
        significant = significant,
        lines = lines,
        anchor_significant = anchor_significant,
        delete_marker_line = delete_marker_line,
        edits = edits,
        -- Whole-file created/deleted: difftastic omits chunks entirely, so there
        -- is no token detail to show. The preview needs to tell this apart from
        -- "no tokens because the line was only reflowed" — the first means "we
        -- have no information", the second means "we know nothing happened".
        no_token_detail = all,
      }
    end
  end

  return { verdicts = verdicts, unavailable = false }
end

--- Is the sign on `lnum` (belonging to `v`) worth the user's attention?
---
--- Resolution order matters:
---   1. the deletion marker cell, which may be lit by reference-side content;
---   2. the line's own buffer-side verdict;
---   3. the anchor verdict, for signs on lines the hunk does not cover (a
---      `delete` hunk's marker sits on an untouched buffer line).
--- @param v DifftSigns.Verdict
--- @param lnum integer
--- @return boolean
function M.is_significant(v, lnum)
  if v.delete_marker_line == lnum and v.anchor_significant then
    return true
  end
  local own = v.lines[lnum]
  if own ~= nil then
    return own
  end
  return v.anchor_significant
end

--- The buffer line range a verdict's hunk occupies. A `delete` hunk adds no
--- lines, so it collapses to the single anchor line it is rendered against.
--- @param v DifftSigns.Verdict
--- @return integer first, integer last
local function span_of(v)
  local a = v.hunk.added
  if a.count == 0 then
    return a.start, a.start
  end
  return a.start, a.start + a.count - 1
end

--- Verdicts sorted by buffer position.
--- @param set DifftSigns.VerdictSet
--- @return DifftSigns.Verdict[]
local function sorted(set)
  local vs = {}
  for _, v in ipairs(set.verdicts or {}) do
    vs[#vs + 1] = v
  end
  table.sort(vs, function(a, b)
    return a.hunk.added.start < b.hunk.added.start
  end)
  return vs
end

--- Every verdict in the maximal run of CONTIGUOUS hunks containing `lnum`.
---
--- Why this exists. gitsigns computes hunks at zero context and, with
--- `diff_opts.linematch` on, performs a second-stage alignment that can split one
--- logical edit into several adjacent hunks. Observed in the wild: adding five
--- lines and altering the sixth became `add(363,5)` + `change(368,1)` — which git
--- itself reports as a single hunk once context is applied. The gutter does not
--- care (its verdict is per line, and correct either way), but a preview keyed to
--- one hunk then shows *different content on different lines of what the user
--- sees as one contiguous block of signs*.
---
--- gitsigns solves this for staging with a `greedy` mode that re-runs the diff
--- without linematch. We deliberately do NOT use that: it would give us a second,
--- different hunk set from the one actually rendered, reintroducing the
--- geometry divergence this design exists to prevent. Grouping what we already
--- borrowed keeps one source of truth and is purely presentational.
---
--- @param set DifftSigns.VerdictSet
--- @param lnum integer
--- @return DifftSigns.Verdict[]  -- empty when no hunk covers the line
function M.group_at_line(set, lnum)
  local vs = sorted(set)
  if #vs == 0 then
    return {}
  end

  local hit = nil
  for i, v in ipairs(vs) do
    local first, last = span_of(v)
    -- `lines[lnum] ~= nil` for covered lines; a delete hunk covers none, so also
    -- accept its anchor and the line below it (where a topdelete cap lands).
    if v.lines[lnum] ~= nil
      or (v.hunk.added.count == 0 and (lnum == first or lnum == first + 1))
      or (lnum >= first and lnum <= last)
    then
      hit = i
      break
    end
  end
  if hit == nil then
    return {}
  end

  local from, to = hit, hit
  while from > 1 do
    local _, prev_last = span_of(vs[from - 1])
    local this_first = span_of(vs[from])
    if prev_last + 1 < this_first then
      break
    end
    from = from - 1
  end
  while to < #vs do
    local _, this_last = span_of(vs[to])
    local next_first = span_of(vs[to + 1])
    if this_last + 1 < next_first then
      break
    end
    to = to + 1
  end

  local group = {}
  for i = from, to do
    group[#group + 1] = vs[i]
  end
  return group
end

--- Count significant vs noise lines. For the status function (REDESIGN R6) and
--- for tests that want a one-line summary of a whole buffer.
--- @param set DifftSigns.VerdictSet
--- @return { significant: integer, noise: integer, hunks: integer }
function M.summary(set)
  local significant, noise = 0, 0
  for _, v in ipairs(set.verdicts or {}) do
    for _, sig in pairs(v.lines) do
      if sig then
        significant = significant + 1
      else
        noise = noise + 1
      end
    end
  end
  return { significant = significant, noise = noise, hunks = #(set.verdicts or {}) }
end

return M
