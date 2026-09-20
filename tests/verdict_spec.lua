--- Tests for verdict.lua — the gitsigns-geometry x difftastic-verdict join.
---
--- This is the heart of the plugin, so it gets the most tests. The hunk shapes
--- below are gitsigns' real shape; the diff results are real difft fixtures
--- wherever a fixture exists, so the join is exercised against genuine data on
--- both sides rather than against two sets of assumptions.

local core = require("difftsigns.core")
local verdict = require("difftsigns.verdict")

local function fixture(name)
  local f = assert(io.open("tests/fixtures/" .. name .. ".json", "r"))
  local content = f:read("*a")
  f:close()
  return core.parse(vim.json.decode(content))
end

--- Build a gitsigns-shaped hunk.
local function hunk(kind, added_start, added_count, removed_start, removed_count)
  return {
    type = kind,
    added = { start = added_start, count = added_count },
    removed = { start = removed_start, count = removed_count },
  }
end

--- Collect { [lnum] = significant } across all verdicts, via the public
--- is_significant resolution (not by peeking at internals).
local function classify(set)
  local out = {}
  for _, v in ipairs(set.verdicts) do
    for lnum in pairs(v.lines) do
      out[lnum] = verdict.is_significant(v, lnum)
    end
  end
  return out
end

describe("verdict.compute", function()
  describe("the pure-noise case (the plugin's whole reason to exist)", function()
    it("marks every line of a reformatted hunk as noise", function()
      -- gitsigns sees lines 1-8 changed. difft says the file is unchanged.
      -- Therefore: all eight lines are noise, and the hunk is insignificant.
      local set = verdict.compute({ hunk("change", 1, 8, 1, 4) }, fixture("reformat_unchanged"))
      assert.is_false(set.unavailable)
      local cls = classify(set)
      for lnum = 1, 8 do
        assert.is_false(cls[lnum], "line " .. lnum .. " should be noise")
      end
      assert.is_false(set.verdicts[1].significant)
      assert.are.equal(8, verdict.summary(set).noise)
    end)

    it("marks a prettier-style rewrap entirely as noise", function()
      local set = verdict.compute({ hunk("change", 1, 6, 1, 1) }, fixture("rewrap_unchanged"))
      assert.are.same({ significant = 0, noise = 6, hunks = 1 }, verdict.summary(set))
    end)
  end)

  describe("the mixed case (wrap a block in a conditional)", function()
    it("keeps the new lines lit and dims the reindented body", function()
      -- w1 -> w2: gitsigns reports lines 2-6 changed (3 reindented + 2 new).
      -- difft flags only lines 2 and 6. Expect exactly 2 lit, 3 dim.
      local set = verdict.compute({ hunk("change", 2, 5, 2, 3) }, fixture("wrap_in_if"))
      local cls = classify(set)
      assert.is_true(cls[2], "the new `if (enabled) {` line must stay lit")
      assert.is_true(cls[6], "the new `}` line must stay lit")
      assert.is_false(cls[3], "reindented body line 3 must dim")
      assert.is_false(cls[4], "reindented body line 4 must dim")
      assert.is_false(cls[5], "reindented body line 5 must dim")
      assert.is_true(set.verdicts[1].significant, "hunk rolls up as significant")
      assert.are.same({ significant = 2, noise = 3, hunks = 1 }, verdict.summary(set))
    end)
  end)

  describe("changes that must never be dimmed", function()
    it("keeps every line of a rename lit", function()
      local set = verdict.compute({ hunk("change", 1, 3, 1, 3) }, fixture("rename"))
      local cls = classify(set)
      assert.is_true(cls[1])
      assert.is_true(cls[2])
      assert.is_true(cls[3])
    end)

    it("treats a whole created file as significant even with no chunk data", function()
      local set = verdict.compute({ hunk("add", 1, 7, 0, 0) }, fixture("created"))
      local cls = classify(set)
      for lnum = 1, 7 do
        assert.is_true(cls[lnum], "line " .. lnum .. " of a new file is significant")
      end
    end)

    it("keeps a moved block lit, since difft cannot detect moves", function()
      -- Pins the known limitation end-to-end: a reorder stays fully lit rather
      -- than being wrongly dimmed. Safe direction of failure.
      local d = fixture("reorder")
      local set = verdict.compute({ hunk("add", 4, 4, 3, 0), hunk("delete", 3, 0, 1, 4) }, d)
      assert.is_true(set.verdicts[1].significant)
      assert.is_true(set.verdicts[2].significant)
    end)
  end)

  describe("regression: token changes wrapped in whitespace-only changes", function()
    it("does not dim a line that had a token REMOVED while being reindented", function()
      -- The end-to-end shape of the bug: gitsigns marks line 2 as changed (the
      -- indentation moved), and the only structural evidence lives on the
      -- reference side. Dimming it would hide a deleted argument.
      local set = verdict.compute(
        { hunk("change", 2, 1, 2, 1) },
        fixture("token_removed_reindent")
      )
      local v = set.verdicts[1]
      assert.is_true(verdict.is_significant(v, 2),
        "a line with a removed token must stay lit, not be dimmed as reflow")
      assert.is_true(v.significant)
      assert.are.equal(0, verdict.summary(set).noise)
    end)

    it("does not dim a line that had a token ADDED while being reindented", function()
      local set = verdict.compute(
        { hunk("change", 2, 1, 2, 1) },
        fixture("token_added_reindent")
      )
      assert.is_true(verdict.is_significant(set.verdicts[1], 2))
    end)

    it("still dims a line that was ONLY reindented", function()
      -- The guard on the fix: cross-attribution must not light up everything.
      -- A pure reindent yields status=unchanged, so nothing is marked.
      local set = verdict.compute({ hunk("change", 2, 3, 2, 3) }, fixture("reformat_unchanged"))
      for lnum = 2, 4 do
        assert.is_false(verdict.is_significant(set.verdicts[1], lnum),
          "line " .. lnum .. " is pure reflow and must still dim")
      end
    end)

    it("keeps reindented neighbours dim while the edited line stays lit", function()
      -- Mixed hunk: line 3 has a real value change, lines 2 and 4 only moved.
      -- Cross-attribution must not leak the verdict onto the neighbours.
      local set = verdict.compute({ hunk("change", 2, 3, 2, 3) }, fixture("single_token"))
      local v = set.verdicts[1]
      assert.is_false(verdict.is_significant(v, 2), "neighbour must stay dim")
      assert.is_false(verdict.is_significant(v, 4), "neighbour must stay dim")
    end)
  end)

  describe("verdict.group_at_line (contiguous hunk grouping)", function()
    -- REGRESSION, found in the wild. gitsigns computes hunks at zero context and
    -- with diff_opts.linematch performs a second-stage alignment, so ONE logical
    -- edit can arrive as several adjacent hunks. Observed in crawlee: adding 5
    -- lines and altering the 6th became add(363,5) + change(368,1), which git
    -- itself reports as a single hunk. The preview keyed to one hunk therefore
    -- showed different content on different lines of one unbroken run of signs.
    local function real_world_split()
      local d = {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = { [363] = true, [364] = true, [365] = true,
                        [366] = true, [367] = true, [368] = true },
        changed_lhs = { [363] = true },
        edits = {},
      }
      return verdict.compute({
        { type = "add", added = { start = 363, count = 5 }, removed = { start = 362, count = 0 } },
        { type = "change", added = { start = 368, count = 1 }, removed = { start = 363, count = 1 } },
      }, d)
    end

    it("returns BOTH adjacent hunks from anywhere in the run", function()
      local set = real_world_split()
      for lnum = 363, 368 do
        local group = verdict.group_at_line(set, lnum)
        assert.are.equal(2, #group,
          ("line %d must yield the whole contiguous run, not one hunk"):format(lnum))
      end
    end)

    it("returns the same group regardless of which line you ask from", function()
      -- The actual user-visible symptom: <leader>hp behaving differently on
      -- different parts of the same visual hunk.
      local set = real_world_split()
      local first = verdict.group_at_line(set, 363)
      for lnum = 364, 368 do
        local g = verdict.group_at_line(set, lnum)
        assert.are.equal(#first, #g)
        for i = 1, #first do
          assert.are.equal(first[i], g[i], "group must be identical from line " .. lnum)
        end
      end
    end)

    it("orders the group by buffer position", function()
      local set = real_world_split()
      local g = verdict.group_at_line(set, 368)
      assert.are.equal(363, g[1].hunk.added.start)
      assert.are.equal(368, g[2].hunk.added.start)
    end)

    it("does NOT merge hunks separated by unchanged lines", function()
      local d = {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = { [10] = true, [30] = true }, changed_lhs = {}, edits = {},
      }
      local set = verdict.compute({
        { type = "change", added = { start = 10, count = 2 }, removed = { start = 10, count = 2 } },
        { type = "change", added = { start = 30, count = 2 }, removed = { start = 30, count = 2 } },
      }, d)
      assert.are.equal(1, #verdict.group_at_line(set, 10), "distant hunks must stay separate")
      assert.are.equal(1, #verdict.group_at_line(set, 30))
    end)

    it("merges a delete hunk with the change immediately below it", function()
      local d = {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = { [21] = true }, changed_lhs = { [20] = true }, edits = {},
      }
      local set = verdict.compute({
        { type = "delete", added = { start = 20, count = 0 }, removed = { start = 20, count = 2 } },
        { type = "change", added = { start = 21, count = 1 }, removed = { start = 22, count = 1 } },
      }, d)
      assert.are.equal(2, #verdict.group_at_line(set, 21))
    end)

    it("returns empty outside any hunk", function()
      local set = real_world_split()
      assert.are.same({}, verdict.group_at_line(set, 100))
      assert.are.same({}, verdict.group_at_line({ verdicts = {} }, 5))
    end)
  end)

  describe("deletions (the hard part)", function()
    it("judges a delete hunk from reference-side content, not buffer lines", function()
      -- `other` (ref lines 5-7) removed. The hunk covers NO buffer lines, so the
      -- verdict must come from changed_lhs via the anchor.
      local d = fixture("deletion")
      local h = hunk("delete", 4, 0, 5, 3)
      local set = verdict.compute({ h }, d)
      local v = set.verdicts[1]
      assert.is_true(v.anchor_significant, "a real deletion is significant")
      assert.is_true(v.significant)
      -- The marker sits on an untouched buffer line, so resolution must fall
      -- through to the anchor rather than returning nil/false.
      assert.is_true(verdict.is_significant(v, 4), "delete marker on line 4")
      assert.is_true(verdict.is_significant(v, 5), "or line 5 if topdelete shifted it")
    end)

    it("dims a delete marker when the removed content was not structural", function()
      -- Blank lines removed: gitsigns draws a delete marker, difft reports
      -- nothing structural on the lhs. This is noise and should dim.
      local d = {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = {}, changed_lhs = {}, edits = {},
      }
      local set = verdict.compute({ hunk("delete", 10, 0, 11, 2) }, d)
      local v = set.verdicts[1]
      assert.is_false(v.anchor_significant)
      assert.is_false(v.significant)
      assert.is_false(verdict.is_significant(v, 10))
    end)

    it("keeps a changedelete marker lit when the deleted part was real", function()
      -- A hunk that reflows 2 lines AND deletes a real line. The reflowed lines
      -- dim, but the marker cell carrying the deletion must stay lit or we hide
      -- a genuine removal. This is the case most likely to regress.
      local d = {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = {},          -- buffer lines only reflowed
        changed_lhs = { [7] = true }, -- a genuinely removed reference line
        edits = {},
      }
      local h = hunk("change", 5, 2, 5, 3) -- removed(3) > added(2) => changedelete
      local set = verdict.compute({ h }, d)
      local v = set.verdicts[1]
      assert.are.equal(6, v.delete_marker_line, "marker on the last changed line")
      assert.is_false(verdict.is_significant(v, 5), "reflowed line dims")
      assert.is_true(verdict.is_significant(v, 6), "deletion marker stays lit")
      assert.is_true(v.significant)
    end)

    it("dims a changedelete marker when nothing real was removed", function()
      local d = {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = {}, changed_lhs = {}, edits = {},
      }
      local set = verdict.compute({ hunk("change", 5, 2, 5, 3) }, d)
      local v = set.verdicts[1]
      assert.is_false(verdict.is_significant(v, 6))
      assert.is_false(v.significant)
    end)
  end)

  describe("refusing to answer", function()
    it("reports unavailable rather than dimming everything on a fallback", function()
      -- The critical asymmetry. An empty verdict set would read as "all noise"
      -- and dim every real change in the file.
      local set = verdict.compute({ hunk("change", 1, 3, 1, 3) }, {
        status = "changed", fallback = true,
        changed_rhs = {}, changed_lhs = {}, edits = {},
      })
      assert.is_true(set.unavailable)
      assert.are.same({}, set.verdicts)
    end)

    it("reports unavailable on junk input", function()
      assert.is_true(verdict.compute(nil, nil).unavailable)
      assert.is_true(verdict.compute({}, nil).unavailable)
    end)

    it("skips malformed hunks instead of crashing", function()
      local d = fixture("wrap_in_if")
      assert.has_no.errors(function()
        local set = verdict.compute({ {}, { added = {} }, hunk("change", 2, 5, 2, 3) }, d)
        assert.are.equal(1, #set.verdicts, "only the well-formed hunk yields a verdict")
      end)
    end)
  end)

  describe("edit attribution", function()
    it("attaches token edits to the hunk that contains them", function()
      local set = verdict.compute({ hunk("change", 6, 1, 6, 1) }, fixture("single_token"))
      local v = set.verdicts[1]
      assert.is_true(#v.edits >= 1)
      local found
      for _, e in ipairs(v.edits) do
        if e.side == "rhs" then
          found = e
        end
      end
      assert.is_not_nil(found, "the rhs token edit belongs to this hunk")
      assert.are.equal(13, found.col_start)
      assert.are.equal(14, found.col_end)
    end)

    it("does not attach edits from lines outside the hunk", function()
      -- Hunk covers line 1 only; the fixture's edits are on line 6.
      local set = verdict.compute({ hunk("change", 1, 1, 1, 1) }, fixture("single_token"))
      assert.are.equal(0, #set.verdicts[1].edits)
    end)
  end)
end)
