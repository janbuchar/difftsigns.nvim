--- Tests for core.lua — the difftastic parse boundary.
---
--- Every fixture in tests/fixtures/ is REAL output from Difftastic 0.69.0, not
--- hand-written JSON. Hand-written fixtures test our beliefs about the schema;
--- captured fixtures test the schema. The PoC's most expensive bugs came from
--- believing the wrong thing about this format.

local core = require("difftsigns.core")

local function fixture(name)
  local path = "tests/fixtures/" .. name .. ".json"
  local f = assert(io.open(path, "r"), "missing fixture: " .. path)
  local content = f:read("*a")
  f:close()
  return core.parse(vim.json.decode(content))
end

local function keys(set)
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

describe("core.parse", function()
  describe("the cases that justify the plugin", function()
    it("reports a pure reindent/reformat as structurally unchanged", function()
      -- 8 lines that a line differ flags; difft says nothing happened.
      local r = fixture("reformat_unchanged")
      assert.are.equal("unchanged", r.status)
      assert.are.same({}, keys(r.changed_rhs))
      assert.are.same({}, keys(r.changed_lhs))
      assert.is_false(r.all_significant)
      assert.is_false(r.fallback)
    end)

    it("reports a prettier-style rewrap as structurally unchanged", function()
      -- A call exploded across 6 lines WITH an added trailing comma. This is
      -- the single most common source of real-world diff noise.
      local r = fixture("rewrap_unchanged")
      assert.are.equal("unchanged", r.status)
      assert.are.same({}, keys(r.changed_rhs))
    end)

    it("marks only the genuinely new lines when a block is wrapped and reindented", function()
      -- w1 -> w2 wraps 3 statements in `if (enabled) {`. A line differ flags 5
      -- lines. difft flags exactly 2: the new `if` line and the new `}`.
      -- The 3 reindented body lines must NOT appear.
      local r = fixture("wrap_in_if")
      assert.are.equal("changed", r.status)
      assert.are.same({ 2, 6 }, keys(r.changed_rhs))
      for _, reindented in ipairs({ 3, 4, 5 }) do
        assert.is_nil(r.changed_rhs[reindented],
          "reindented body line " .. reindented .. " must not count as changed")
      end
    end)
  end)

  describe("cross-attribution: changes visible on only one side", function()
    -- REGRESSION. A token change wrapped in whitespace-only changes was dimmed.
    -- Removing a call argument while reindenting the line makes difftastic
    -- report the deletion on the LHS and the RHS line as pure CONTEXT (nothing
    -- was added there, only whitespace differs). Reading the rhs side alone
    -- concluded "this buffer line did not change" and hid a real deletion.
    it("marks the buffer line when a token was REMOVED from it", function()
      local r = fixture("token_removed_reindent")
      assert.are.equal("changed", r.status)
      assert.is_true(r.changed_lhs[2], "the lhs deletion must be recorded")
      assert.is_true(r.changed_rhs[2],
        "the aligned BUFFER line must be significant too, or a removed token gets dimmed")
    end)

    it("marks the reference line when a token was ADDED to it", function()
      -- The mirror image: rhs carries the change, lhs is context. Needed so
      -- deletion markers on such hunks are judged correctly.
      local r = fixture("token_added_reindent")
      assert.is_true(r.changed_rhs[2])
      assert.is_true(r.changed_lhs[2], "the aligned reference line must be marked too")
    end)

    it("does not invent changes from context-only entries", function()
      -- Cross-attribution must trigger only on a REAL change. An entry where
      -- both sides are context must stay clean, or every line inside every chunk
      -- would count as changed and the plugin would dim nothing at all.
      local r = core.parse({
        language = "TypeScript",
        status = "changed",
        chunks = { { { lhs = { line_number = 4, changes = {} }, rhs = { line_number = 9, changes = {} } } } },
      })
      assert.is_nil(r.changed_lhs[5])
      assert.is_nil(r.changed_rhs[10])
    end)

    it("still marks only the changed side when there is no aligned partner", function()
      -- A pure deletion entry (lhs only) must not fabricate an rhs line.
      local r = core.parse({
        language = "TypeScript",
        status = "changed",
        chunks = { { { lhs = { line_number = 4, changes = { { content = "x", start = 0, ["end"] = 1 } } } } } },
      })
      assert.is_true(r.changed_lhs[5])
      assert.are.same({}, r.changed_rhs)
    end)
  end)

  describe("changes it must not miss", function()
    it("marks every line touched by a rename, on both sides", function()
      local r = fixture("rename")
      assert.are.same({ 1, 2, 3 }, keys(r.changed_rhs))
      assert.are.same({ 1, 2, 3 }, keys(r.changed_lhs))
    end)

    it("marks a single changed token on one line only", function()
      local r = fixture("single_token")
      assert.are.same({ 6 }, keys(r.changed_rhs))
      assert.are.same({ 6 }, keys(r.changed_lhs))
    end)

    it("records reference-side lines for a genuine deletion", function()
      -- The `other` function (ref lines 5-7) was removed entirely. Nothing
      -- changed on the buffer side, so only changed_lhs is populated.
      local r = fixture("deletion")
      assert.are.same({}, keys(r.changed_rhs))
      assert.are.same({ 5, 6, 7 }, keys(r.changed_lhs))
    end)
  end)

  describe("line numbering and token detail", function()
    it("normalises difftastic's 0-based line numbers to 1-based", function()
      -- The fixture's raw JSON says line_number 5; the changed line is line 6.
      local raw = vim.json.decode((function()
        local f = assert(io.open("tests/fixtures/single_token.json"))
        local c = f:read("*a")
        f:close()
        return c
      end)())
      assert.are.equal(5, raw.chunks[1][1].rhs.line_number, "fixture should be 0-based")
      assert.is_true(core.parse(raw).changed_rhs[6], "parser must report 1-based line 6")
    end)

    it("retains token byte ranges for the preview", function()
      local r = fixture("single_token")
      local rhs_edit
      for _, e in ipairs(r.edits) do
        if e.side == "rhs" then
          rhs_edit = e
        end
      end
      assert.is_not_nil(rhs_edit)
      assert.are.equal("3", rhs_edit.content)
      assert.are.equal(6, rhs_edit.line)
      assert.are.equal(13, rhs_edit.col_start)
      assert.are.equal(14, rhs_edit.col_end)
    end)
  end)

  describe("whole-file statuses", function()
    it("treats a created file as entirely significant", function()
      local r = fixture("created")
      assert.are.equal("created", r.status)
      assert.is_true(r.all_significant)
    end)

    it("treats a deleted file as entirely significant", function()
      local r = fixture("deleted")
      assert.are.equal("deleted", r.status)
      assert.is_true(r.all_significant)
    end)

    it("does not crash when chunks are absent (created/deleted omit them)", function()
      local raw = vim.json.decode('{"language":"TypeScript","path":"x","status":"created"}')
      assert.has_no.errors(function()
        core.parse(raw)
      end)
    end)
  end)

  describe("refusing to answer", function()
    it("flags a Text-language line-diff fallback rather than presenting it as structural", function()
      local r = core.parse({ language = "Text", status = "changed", chunks = {} })
      assert.is_true(r.fallback)
    end)

    -- REGRESSION. difftastic does not report a fallback with one fixed string.
    -- Matching only the exact "Text" let "Text (exceeded DFT_GRAPH_LIMIT)" through,
    -- so a LINE DIFF was presented as a structural verdict: every token on every
    -- changed line marked, spaces included, which reads as a whole-hunk rewrite.
    it("flags the graph-limit fallback, real difft output", function()
      local r = fixture("graph_limit_fallback")
      assert.are.equal("Text (exceeded DFT_GRAPH_LIMIT)", r.language)
      assert.is_true(r.fallback, "a graph-limit fallback is NOT a structural verdict")
      assert.is_truthy(r.fallback_reason:find("graph limit"),
        "the reason must be actionable: " .. tostring(r.fallback_reason))
    end)

    it("flags every shape of difftastic's give-up language", function()
      for _, lang in ipairs({
        "Text",
        "text",
        "Text (exceeded DFT_GRAPH_LIMIT)",
        "Text (exceeded DFT_BYTE_LIMIT)",
        "Text (something new upstream)",
      }) do
        local r = core.parse({ language = lang, status = "changed", chunks = { {} } })
        assert.is_true(r.fallback, "must be treated as a fallback: " .. lang)
        assert.is_not_nil(r.fallback_reason, "must carry a reason: " .. lang)
      end
    end)

    it("does not mistake a real language for a fallback", function()
      for _, lang in ipairs({ "TypeScript", "Rust", "Lua", "Plain Text Config" }) do
        local r = core.parse({ language = lang, status = "changed", chunks = { {} } })
        assert.is_false(r.fallback, "must remain a structural verdict: " .. lang)
      end
    end)

    it("catches a line diff by SHAPE even if the language looks legitimate", function()
      -- Belt and braces, independent of the unstable language string: a genuine
      -- structural diff never reports whitespace as a changed token (verified
      -- across every fixture, including a 46-edit reorder). So whitespace edits
      -- mean a line diff, whatever the label claims.
      local r = core.parse({
        language = "TypeScript",
        status = "changed",
        chunks = { { {
          lhs = { line_number = 0, changes = {
            { start = 0, ["end"] = 1, content = " ", highlight = "normal" },
          } },
        } } },
      })
      assert.is_true(r.fallback, "whitespace-as-a-change betrays a line diff")
      assert.is_truthy(r.fallback_reason:find("line diff"))
    end)

    it("does not trip the shape check on genuine structural output", function()
      -- Every captured fixture must remain a structural verdict.
      for _, name in ipairs({
        "single_token", "rename", "deletion", "wrap_in_if", "reorder",
        "token_removed_reindent", "token_added_reindent",
      }) do
        assert.is_false(fixture(name).fallback, name .. " must not be flagged as a fallback")
      end
    end)

    it("flags malformed output as fallback rather than claiming everything is noise", function()
      -- Critical asymmetry: an empty verdict would DIM real changes. When we
      -- cannot parse, we must say "no answer", never "no changes".
      local r = core.parse({ language = "TypeScript", status = "changed" })
      assert.is_true(r.fallback)
    end)

    it("survives junk input", function()
      assert.has_no.errors(function()
        core.parse({ status = "changed", chunks = { {}, { {} }, { { lhs = 5 } } } })
      end)
    end)
  end)

  describe("known limitation: no move detection", function()
    it("reports a moved function as fully changed on both sides", function()
      -- Difftastic 0.69 has no move detection. A reorder is delete+add with
      -- every token flagged. This test exists to PIN the limitation so that if
      -- a future difft version gains move detection, we find out here rather
      -- than by wondering why the gutter got quieter.
      local r = fixture("reorder")
      assert.are.equal("changed", r.status)
      assert.is_true(#keys(r.changed_lhs) > 0, "moved-from lines flagged")
      assert.is_true(#keys(r.changed_rhs) > 0, "moved-to lines flagged")
    end)
  end)
end)
