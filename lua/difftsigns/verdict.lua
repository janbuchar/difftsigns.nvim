--- The join: gitsigns' hunk geometry x difftastic's structural verdict.
---
--- Pure: no Neovim API, no IO, no require of gitsigns. Plain tables in, plain
--- tables out, so the off-by-one cases (deletion anchoring, changedelete
--- markers) are cheap to test exhaustively.
---
--- Wrongly dimming a real change is much worse than failing to dim noise, so
--- every ambiguous case resolves to "significant".

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

--- Last buffer line of a hunk's "changed" portion. Mirrors gitsigns' internal
--- `change_end`; reproduced to keep this file pure, pinned by tests.
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

  -- Not an empty verdict set: that would read as "nothing is significant" and
  -- dim every real change in the buffer.
  if diff.fallback then
    return { verdicts = {}, unavailable = true }
  end

  local all = diff.all_significant == true
  local changed_rhs = diff.changed_rhs or {}
  local changed_lhs = diff.changed_lhs or {}

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

      for lnum = added.start, added.start + added.count - 1 do
        local sig = all or changed_rhs[lnum] == true
        lines[lnum] = sig
        significant = significant or sig
        for _, e in ipairs(edits_by_side.rhs[lnum] or {}) do
          table.insert(edits, e)
        end
      end

      -- Reference-only content has no buffer line of its own; judge it from
      -- the lhs verdict over the removed range and carry it as an anchor verdict.
      local anchor_significant = all
      for lnum = removed.start, removed.start + removed.count - 1 do
        if changed_lhs[lnum] == true then
          anchor_significant = true
        end
        for _, e in ipairs(edits_by_side.lhs[lnum] or {}) do
          table.insert(edits, e)
        end
      end

      if added.count == 0 then
        significant = significant or anchor_significant
      end

      -- gitsigns draws `changedelete` on the LAST changed line of a hunk that
      -- removed more than it added. That cell carries deletion semantics on top
      -- of its own line's verdict, so it must stay lit when the deletion was
      -- real even if the line itself only reflowed.
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
        -- The preview must tell "no information" (whole-file created/deleted)
        -- apart from "no tokens because the line only reflowed".
        no_token_detail = all,
      }
    end
  end

  return { verdicts = verdicts, unavailable = false }
end

--- Is the sign on `lnum` (belonging to `v`) worth the user's attention?
---
--- Order matters: the deletion marker cell first (lit by reference-side
--- content), then the line's own verdict, then the anchor verdict for signs on
--- lines the hunk does not cover (a `delete` hunk's marker).
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

--- Buffer line range a verdict's hunk occupies; a `delete` hunk collapses to
--- its anchor line.
--- @param v DifftSigns.Verdict
--- @return integer first, integer last
local function span_of(v)
  local a = v.hunk.added
  if a.count == 0 then
    return a.start, a.start
  end
  return a.start, a.start + a.count - 1
end

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
--- gitsigns diffs at zero context and, with `diff_opts.linematch`, can split
--- one logical edit into adjacent hunks (observed: `add(363,5)` + `change(368,1)`
--- for what git reports as one hunk). A preview keyed to one hunk then shows
--- different content on different lines of one contiguous block of signs.
---
--- gitsigns' own fix (`greedy` mode, re-diffing without linematch) is not used:
--- it would give a second hunk set different from the one rendered.
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
    -- A delete hunk covers no lines, so also accept its anchor and the line
    -- below it (where a topdelete cap lands).
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
