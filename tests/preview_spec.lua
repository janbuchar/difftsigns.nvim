--- Tests for preview.lua — the unified line-hunk + structural view.
---
--- The PoC's preview showed difftastic's bare tokens in isolation, which for a
--- reorder meant the SAME string on both sides with no context: useless. These
--- tests assert on the two properties that make the new one useful — real source
--- lines are present verbatim, and the structural verdict is visible in the
--- float rather than only in the gutter.
---
--- Source lines are now shown VERBATIM (no inline -/+): the marker lives in the
--- sign column (`l.sign`), the line carries the source's own syntax highlighting,
--- and change emphasis is a red/green BACKGROUND (`*Bg` groups) over it.

local core = require("difftsigns.core")
local verdict = require("difftsigns.verdict")
local preview = require("difftsigns.preview")
local config = require("difftsigns.config")

local function fixture(name)
  local f = assert(io.open("tests/fixtures/" .. name .. ".json", "r"))
  local content = f:read("*a")
  f:close()
  return core.parse(vim.json.decode(content))
end

local function buf_with(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function texts(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    out[#out + 1] = l.text
  end
  return out
end

local function joined(rendered)
  return table.concat(texts(rendered), "\n")
end

--- Index rendered lines by their verbatim source text (no -/+ prefix now).
local function by_text(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    out[l.text] = l
  end
  return out
end

--- The single removed / added source line in a rendered group, found by its
--- sign-column marker rather than an inline prefix.
local function marker_lines(rendered)
  local minus, plus
  for _, l in ipairs(rendered) do
    if l.sign == "-" then minus = l elseif l.sign == "+" then plus = l end
  end
  return minus, plus
end

describe("preview building", function()
  before_each(function()
    config.setup({})
  end)

  it("shows real source lines from both sides, verbatim", function()
    -- Uses a genuinely two-sided change (a value edit), because a one-sided one
    -- now renders only the relevant side by design.
    local now = { "a", "b", "c", "d", "e", "  return x * 3;", "}" }
    local was = { "a", "b", "c", "d", "e", "  return x * 2;", "}" }
    local buf = buf_with(now)

    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))

    local rendered = preview._build(buf, { set.verdicts[1] }, was)
    local minus, plus = marker_lines(rendered)
    assert.is_not_nil(minus, "a removed line is marked with a - sign")
    assert.is_not_nil(plus, "an added line is marked with a + sign")
    -- Each side's content must come from its own source, VERBATIM (the marker is
    -- in the sign column, not inline): the reference from the retained text, the
    -- buffer read live.
    assert.are.equal("  return x * 2;", minus.text, "the reference line appears verbatim")
    assert.are.equal("  return x * 3;", plus.text, "the buffer line appears verbatim")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("shows the buffer side verbatim for a one-sided (additive) change", function()
    local now = {
      "function run() {", "  if (enabled) {", "    doThing();",
      "    doOther();", "    return 1;", "  }", "}",
    }
    local was = { "function run() {", "  doThing();", "  doOther();", "  return 1;", "}" }
    local buf = buf_with(now)
    local set = verdict.compute({
      { type = "change", added = { start = 2, count = 5 }, removed = { start = 2, count = 3 } },
    }, fixture("wrap_in_if"))

    local rendered = preview._build(buf, { set.verdicts[1] }, was)
    local out = joined(rendered)
    assert.is_truthy(out:find("if %(enabled%) {"), "the new line must appear")
    local bt = by_text(rendered)
    assert.is_not_nil(bt["    doThing();"], "buffer content appears verbatim")
    assert.are.equal("+", bt["    doThing();"].sign, "on the added side")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("states the noise/real split in the header", function()
    local buf = buf_with({
      "function run() {", "  if (enabled) {", "    doThing();",
      "    doOther();", "    return 1;", "  }", "}",
    })
    local set = verdict.compute({
      { type = "change", added = { start = 2, count = 5 }, removed = { start = 2, count = 3 } },
    }, fixture("wrap_in_if"))

    local header = preview._build(buf, { set.verdicts[1] }, {})[1].text
    assert.is_truthy(header:find("2 real"), "header should quantify real changes")
    assert.is_truthy(header:find("3 formatting%-only"), "header should quantify noise")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("says so plainly when a hunk is formatting only", function()
    local buf = buf_with({ "const a = 1;", "const b = 2;" })
    local set = verdict.compute({
      { type = "change", added = { start = 1, count = 2 }, removed = { start = 1, count = 1 } },
    }, fixture("reformat_unchanged"))

    local header = preview._build(buf, { set.verdicts[1] }, { "const a=1; const b=2;" })[1].text
    assert.is_truthy(header:find("formatting only"), "header: " .. header)
    assert.is_truthy(header:find("no structural change"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("dims reflow-only lines and lights genuinely changed ones", function()
    local buf = buf_with({
      "function run() {", "  if (enabled) {", "    doThing();",
      "    doOther();", "    return 1;", "  }", "}",
    })
    local set = verdict.compute({
      { type = "change", added = { start = 2, count = 5 }, removed = { start = 2, count = 3 } },
    }, fixture("wrap_in_if"))

    local rendered = preview._build(buf, { set.verdicts[1] }, {})
    local bt = by_text(rendered)

    -- A line with token detail carries NO whole-line wash: the token backgrounds
    -- are the answer, and washing the whole line would compete with them.
    local changed = bt["  if (enabled) {"]
    assert.is_nil(changed.hl, "a line with tokens must not be washed whole-line")
    assert.are.equal("DifftSignsAddedBg", changed.token_hl, "its tokens get the added background")
    assert.is_true(#changed.tokens > 0)
    assert.are.equal("DifftSignsAdded", changed.sign_hl, "the + marker stays scannable")

    -- Reflow-only lines still recede, exactly as in the gutter.
    assert.are.equal("DifftSignsContext", bt["    doThing();"].hl, "reindented line recedes")
    assert.are.equal("DifftSignsContext", bt["    return 1;"].hl, "reindented line recedes")
    assert.is_nil(bt["    doThing();"].token_hl)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  describe("one-sided changes show one side", function()
    local function sides(rendered)
      local minus, plus = 0, 0
      for _, l in ipairs(rendered) do
        if l.sign == "-" then minus = minus + 1 elseif l.sign == "+" then plus = plus + 1 end
      end
      return minus, plus
    end

    it("shows only the reference side for a pure deletion", function()
      -- `doThing(alpha, beta)` -> `doThing(alpha)`: all token detail is on the
      -- lhs. The buffer line would render with no colour at all, so printing it
      -- is dead weight.
      local buf = buf_with({ "function f() {", "      doThing(alpha);", "}" })
      local ref = { "function f() {", "  doThing(alpha, beta);", "}" }
      local set = verdict.compute(
        { { type = "change", added = { start = 2, count = 1 }, removed = { start = 2, count = 1 } } },
        fixture("token_removed_reindent")
      )
      local rendered = preview._build(buf, { set.verdicts[1] }, ref)
      local minus, plus = sides(rendered)
      assert.are.equal(1, minus, "the removal must be shown")
      assert.are.equal(0, plus, "the buffer side has nothing to say and must be omitted")
      assert.is_truthy(rendered[1].text:find("deletions only"),
        "header must explain the missing side: " .. rendered[1].text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows only the buffer side for a pure addition", function()
      local buf = buf_with({ "function f() {", "      doThing(alpha, gamma);", "}" })
      local ref = { "function f() {", "  doThing(alpha);", "}" }
      local set = verdict.compute(
        { { type = "change", added = { start = 2, count = 1 }, removed = { start = 2, count = 1 } } },
        fixture("token_added_reindent")
      )
      local rendered = preview._build(buf, { set.verdicts[1] }, ref)
      local minus, plus = sides(rendered)
      assert.are.equal(0, minus, "the reference side has nothing to say")
      assert.are.equal(1, plus)
      assert.is_truthy(rendered[1].text:find("additions only"), rendered[1].text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows only the buffer side when a block is wrapped and reindented", function()
      -- Semantically additive (a new `if` and `}`); the body only moved.
      local buf = buf_with({
        "function run() {", "  if (enabled) {", "    doThing();",
        "    doOther();", "    return 1;", "  }", "}",
      })
      local ref = { "function run() {", "  doThing();", "  doOther();", "  return 1;", "}" }
      local set = verdict.compute({
        { type = "change", added = { start = 2, count = 5 }, removed = { start = 2, count = 3 } },
      }, fixture("wrap_in_if"))
      local minus, plus = sides(preview._build(buf, { set.verdicts[1] }, ref))
      assert.are.equal(0, minus)
      assert.are.equal(5, plus)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows BOTH sides when the change is genuinely two-sided", function()
      local buf = buf_with({ "a", "b", "c", "d", "e", "  return x * 3;", "}" })
      local ref = { "a", "b", "c", "d", "e", "  return x * 2;", "}" }
      local set = verdict.compute({
        { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
      }, fixture("single_token"))
      local rendered = preview._build(buf, { set.verdicts[1] }, ref)
      local minus, plus = sides(rendered)
      assert.are.equal(1, minus, "a value change is visible on both sides")
      assert.are.equal(1, plus)
      assert.is_nil(rendered[1].text:find("only"), rendered[1].text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows BOTH sides for a formatting-only hunk", function()
      -- No tokens on either side, so there is no 'relevant part' to pick and the
      -- reflow itself is the only thing worth looking at.
      local buf = buf_with({ "const a = 1;", "const b = 2;" })
      local ref = { "const a=1; const b=2;" }
      local set = verdict.compute({
        { type = "change", added = { start = 1, count = 2 }, removed = { start = 1, count = 1 } },
      }, fixture("reformat_unchanged"))
      local minus, plus = sides(preview._build(buf, { set.verdicts[1] }, ref))
      assert.is_true(minus > 0, "the reflow must remain inspectable")
      assert.is_true(plus > 0)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not claim a side was trimmed when there were no lines there", function()
      -- A real `add` hunk removes nothing, so its one-sidedness is unremarkable.
      local buf = buf_with({ "const brand = 1;", "const shiny = 2;" })
      local set = verdict.compute(
        { { type = "add", added = { start = 1, count = 2 }, removed = { start = 0, count = 0 } } },
        fixture("created")
      )
      local header = preview._build(buf, { set.verdicts[1] }, nil)[1].text
      assert.is_nil(header:find("only"), "nothing was suppressed: " .. header)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  it("colours tokens by direction: removed red, added green", function()
    -- A two-sided value change, so both directions are present at once.
    local buf = buf_with({ "a", "b", "c", "d", "e", "  return x * 3;", "}" })
    local ref = { "a", "b", "c", "d", "e", "  return x * 2;", "}" }
    local set = verdict.compute(
      { { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } } },
      fixture("single_token")
    )
    local rendered = preview._build(buf, { set.verdicts[1] }, ref)

    local minus, plus = marker_lines(rendered)

    assert.are.equal("DifftSignsRemovedBg", minus.token_hl, "the old token gets the removed background")
    assert.are.equal("DifftSignsAddedBg", plus.token_hl, "the new token gets the added background")
    assert.is_true(#minus.tokens > 0 and #plus.tokens > 0)
    -- And neither line is washed: the token backgrounds carry the meaning over
    -- the syntax highlighting.
    assert.is_nil(minus.hl)
    assert.is_nil(plus.hl)
    assert.are.equal("DifftSignsRemoved", minus.sign_hl)
    assert.are.equal("DifftSignsAdded", plus.sign_hl)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("leaves a token-free significant line neutral, never dimmed", function()
    -- The neutral state is reachable only inside a hunk whose buffer side DOES
    -- carry tokens somewhere (otherwise that side is trimmed away entirely): here
    -- line 2 gained a token, while line 3 is significant only by
    -- cross-attribution from the reference side. Line 3 must be neither green
    -- (nothing was added on it) nor dim (it is part of a real change).
    local buf = buf_with({ "keep;", "  added_here;", "  untouched;" })
    local set = verdict.compute(
      { { type = "change", added = { start = 2, count = 2 }, removed = { start = 2, count = 2 } } },
      {
        status = "changed", fallback = false, all_significant = false,
        changed_rhs = { [2] = true, [3] = true },
        changed_lhs = { [3] = true },
        edits = {
          { side = "rhs", line = 2, content = "added_here", highlight = "normal", col_start = 2, col_end = 12 },
          { side = "lhs", line = 3, content = "gone", highlight = "normal", col_start = 2, col_end = 6 },
        },
      }
    )
    local rendered = preview._build(buf, { set.verdicts[1] }, { "keep;", "added_here;", "gone;" })

    local bt = by_text(rendered)
    local neutral = bt["  untouched;"]
    assert.is_not_nil(neutral, "the line must still be rendered")
    assert.is_nil(neutral.token_hl, "no tokens on this side of this line")
    assert.is_nil(neutral.hl, "significant with nothing added => syntax only, not dimmed")
    assert.are.equal("DifftSignsAdded", neutral.sign_hl, "the marker still shows the side")

    -- Sanity: the line that DID gain a token gets the added background.
    assert.are.equal("DifftSignsAddedBg", bt["  added_here;"].token_hl)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("falls back to a whole-line colour only when there is no token detail", function()
    -- Whole-file created: difftastic omits chunks entirely, so there are no
    -- tokens to point at and the line-level colour is the only thing we can say.
    local buf = buf_with({ "const brand = 1;", "const shiny = 2;" })
    local set = verdict.compute(
      { { type = "add", added = { start = 1, count = 2 }, removed = { start = 0, count = 0 } } },
      fixture("created")
    )
    local rendered = preview._build(buf, { set.verdicts[1] }, nil)
    local _, plus = marker_lines(rendered)
    assert.are.equal("DifftSignsAddedBg", plus.hl,
      "with no token detail, a whole-line background wash is all we can honestly draw")
    assert.is_nil(plus.token_hl)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("marks changed token byte ranges verbatim, with no prefix offset", function()
    local buf = buf_with({
      "function greet(name: string) {",
      '  console.log("hello " + name);',
      "  return name.length;",
      "}",
      "function other(x: number) {",
      "  return x * 3;",
      "}",
    })
    -- single_token fixture: the `3` on line 6 at bytes 13-14.
    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))

    local rendered = preview._build(buf, { set.verdicts[1] }, {})
    local marked
    for _, l in ipairs(rendered) do
      if l.tokens ~= nil and #l.tokens > 0 and l.sign == "+" then
        marked = l
      end
    end
    assert.is_not_nil(marked, "the added line should carry a token range")
    -- The source line is verbatim now, so difft's 13..14 is used unshifted.
    assert.are.equal(13, marked.tokens[1].from)
    assert.are.equal(14, marked.tokens[1].to)
    -- And the range must actually cover the changed character.
    assert.are.equal("3", marked.text:sub(marked.tokens[1].from + 1, marked.tokens[1].to))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renders a pure deletion from the reference side", function()
    local buf = buf_with({ "function greet(name: string) {", "  return 1;", "}", "" })
    local was = {
      "function greet(name: string) {", "  return 1;", "}",
      "function other(x: number) {", "  return x * 2;", "}",
    }
    local set = verdict.compute({
      { type = "delete", added = { start = 3, count = 0 }, removed = { start = 4, count = 3 } },
    }, fixture("deletion"))

    local out = joined(preview._build(buf, { set.verdicts[1] }, was))
    assert.is_truthy(out:find("function other"), "deleted content comes from the reference text")
    assert.is_truthy(out:find("delete @@"), "header names the hunk type")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("degrades gracefully with no reference text", function()
    local buf = buf_with({ "a", "b" })
    local set = verdict.compute({
      { type = "change", added = { start = 1, count = 2 }, removed = { start = 1, count = 2 } },
    }, fixture("reformat_unchanged"))
    assert.has_no.errors(function()
      preview._build(buf, { set.verdicts[1] }, nil)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("preview across a split hunk", function()
  -- The user-visible half of the same regression: identical preview content from
  -- every line of a contiguous run that gitsigns split into two hunks.
  local function split_set()
    local d = {
      status = "changed", fallback = false, all_significant = false,
      changed_rhs = { [2] = true, [3] = true, [4] = true },
      changed_lhs = { [2] = true },
      edits = {},
    }
    return verdict.compute({
      { type = "add", added = { start = 2, count = 2 }, removed = { start = 1, count = 0 } },
      { type = "change", added = { start = 4, count = 1 }, removed = { start = 2, count = 1 } },
    }, d)
  end

  it("renders identical content from every line of the run", function()
    config.setup({})
    local buf = buf_with({ "keep;", "added_one;", "added_two;", "changed_line;", "tail;" })
    local ref = { "keep;", "original_line;", "tail;" }
    local set = split_set()

    local renders = {}
    for lnum = 2, 4 do
      local group = verdict.group_at_line(set, lnum)
      assert.are.equal(2, #group, "line " .. lnum .. " must see the whole run")
      renders[lnum] = joined(preview._build(buf, group, ref))
    end
    assert.are.equal(renders[2], renders[3])
    assert.are.equal(renders[3], renders[4])

    -- And the merged render must contain the content of BOTH hunks.
    assert.is_truthy(renders[2]:find("added_one;"), "content of the add hunk")
    assert.is_truthy(renders[2]:find("changed_line;"), "content of the change hunk")
    assert.is_truthy(renders[2]:find("original_line;"), "the removed reference line")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("says how many hunks were merged, so the range is not misread", function()
    config.setup({})
    local buf = buf_with({ "keep;", "added_one;", "added_two;", "changed_line;", "tail;" })
    local header = preview._build(buf, verdict.group_at_line(split_set(), 3), { "keep;", "original_line;" })[1].text
    assert.is_truthy(header:find("2 hunks"), "header should disclose the merge: " .. header)
    assert.is_truthy(header:find("add%+change"), "header should name both kinds: " .. header)
    -- The add hunk's removed.start is 1 (an insertion POINT, not a removed
    -- line); the change hunk actually removes line 2. The range must report 2.
    assert.is_truthy(header:find("%-2,1"),
      "a zero-count side must not shift the range start: " .. header)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not claim a merge when there is only one hunk", function()
    config.setup({})
    local buf = buf_with({ "a", "b", "c", "d", "e", "  return x * 3;", "}" })
    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))
    local header = preview._build(buf, { set.verdicts[1] }, {})[1].text
    assert.is_nil(header:find("hunks"), "single hunk must not mention a merge: " .. header)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("preview highlight priorities", function()
  -- REGRESSION. nvim_buf_set_extmark defaults priority to 4096. The whole-line
  -- highlight was placed without a priority (4096) and the token highlight with
  -- 200, on the false assumption that "placed later wins". Extmark precedence is
  -- by priority alone, so the line highlight painted over every token highlight
  -- and the structural change was invisible in every hunk. These tests assert on
  -- the actual placed priorities, because that is the thing that was wrong.
  local overlay = require("difftsigns.overlay")

  it("places token highlights ABOVE line highlights", function()
    config.setup({})
    local buf = buf_with({
      "function greet(name: string) {",
      '  console.log("hello " + name);',
      "  return name.length;",
      "}",
      "function other(x: number) {",
      "  return x * 3;",
      "}",
    })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 70, height = 12,
    })

    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))
    overlay.apply(buf, set, {}, { "x", "x", "x", "x", "x", "  return x * 2;", "}" })

    vim.api.nvim_win_set_cursor(win, { 6, 0 })
    local float = preview.show(buf, win)
    assert.is_not_nil(float)

    local fbuf = vim.api.nvim_win_get_buf(float)
    local marks = vim.api.nvim_buf_get_extmarks(fbuf, preview.ns, 0, -1, { details = true })

    -- Token backgrounds (the *Bg groups) must sit above the whole-line highlight
    -- (DifftSignsContext / the Bg wash), or the structural change is painted over.
    -- Sign-column marks carry no inline hl_group, so they're skipped here.
    local line_prio, token_prio
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.hl_group == "DifftSignsAddedBg" or d.hl_group == "DifftSignsRemovedBg" then
        token_prio = math.max(token_prio or 0, d.priority)
      elseif d.hl_group ~= nil then
        line_prio = d.priority
      end
    end

    assert.is_not_nil(token_prio, "a token highlight must be placed at all")
    assert.is_not_nil(line_prio, "a line highlight must be placed at all")
    assert.is_true(token_prio > line_prio,
      ("token priority (%s) must exceed line priority (%s), or the structural "
        .. "change is painted over and invisible"):format(tostring(token_prio), tostring(line_prio)))

    vim.api.nvim_win_close(float, true)
    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("never leaves a highlight at the 4096 default", function()
    -- Any unset priority is a latent instance of the same bug.
    config.setup({})
    local buf = buf_with({ "const a = 1;", "const b = 2;", "const c = 3;", "const d = 4;",
      "const e = 5;", "  return x * 3;", "}" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 60, height = 10,
    })
    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))
    overlay.apply(buf, set, {}, { "a", "b", "c", "d", "e", "  return x * 2;", "}" })
    vim.api.nvim_win_set_cursor(win, { 6, 0 })
    local float = preview.show(buf, win)

    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
      vim.api.nvim_win_get_buf(float), preview.ns, 0, -1, { details = true })) do
      assert.is_not.equal(4096, m[4].priority,
        ("%s was placed at the default priority; set it explicitly"):format(tostring(m[4].hl_group)))
    end

    vim.api.nvim_win_close(float, true)
    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("preview window", function()
  it("opens a float and closes it on cursor move", function()
    local overlay = require("difftsigns.overlay")
    config.setup({})
    local buf = buf_with({
      "function run() {", "  if (enabled) {", "    doThing();",
      "    doOther();", "    return 1;", "  }", "}",
    })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 70, height = 12,
    })

    local set = verdict.compute({
      { type = "change", added = { start = 2, count = 5 }, removed = { start = 2, count = 3 } },
    }, fixture("wrap_in_if"))
    overlay.apply(buf, set, {}, { "function run() {", "  doThing();", "}" })

    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    local float = preview.show(buf, win)
    assert.is_not_nil(float, "a float should open for a hunk under the cursor")
    assert.is_true(vim.api.nvim_win_is_valid(float))

    local content = table.concat(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n"
    )
    assert.is_truthy(content:find("formatting%-only"))

    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("gives the float the source's syntax and puts markers in the sign column", function()
    local overlay = require("difftsigns.overlay")
    config.setup({})
    local buf = buf_with({ "a", "b", "c", "d", "e", "  return x * 3;", "}" })
    -- A filetype with no treesitter parser, so the deterministic fallback path
    -- (:syntax, not treesitter) is exercised regardless of what's installed.
    vim.bo[buf].filetype = "difftsigns_fake_ft"
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 60, height = 10,
    })
    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))
    overlay.apply(buf, set, {}, { "a", "b", "c", "d", "e", "  return x * 2;", "}" })
    vim.api.nvim_win_set_cursor(win, { 6, 0 })

    local float = preview.show(buf, win)
    assert.is_not_nil(float)
    local fbuf = vim.api.nvim_win_get_buf(float)

    -- The float wears the source's own highlighting, not the old sentinel ft.
    assert.are.equal("difftsigns_fake_ft", vim.bo[fbuf].syntax,
      "the float must carry the source buffer's syntax")

    -- The -/+ markers are in the sign column, so source text starts at column 0
    -- and highlights cleanly. sign_text marks carry no inline hl_group.
    local signs = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, preview.ns, 0, -1, { details = true })) do
      if m[4].sign_text ~= nil then
        signs = signs + 1
        assert.is_truthy(m[4].sign_text:find("[-+]"), "sign marker is -/+")
      end
    end
    assert.is_true(signs >= 2, "both the - and + lines must place a sign marker")

    vim.api.nvim_win_close(float, true)
    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("says nothing useful rather than erroring outside a hunk", function()
    local overlay = require("difftsigns.overlay")
    local buf = buf_with({ "a", "b", "c" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 40, height = 5,
    })
    overlay.apply(buf, { verdicts = {}, unavailable = false }, {}, nil)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    assert.is_nil(preview.show(buf, win))
    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- A `]c` that keeps the preview open re-shows it after navigating. Two things
  -- must hold or that mapping breaks: is_open() must report an open float, and a
  -- re-show must supersede the previous float rather than leak a second one that
  -- then dismisses the new one on its own pending CursorMoved.
  it("re-showing supersedes the open float instead of leaking one", function()
    local overlay = require("difftsigns.overlay")
    config.setup({})
    local buf = buf_with({ "const a = 1;", "const b = 2;", "const c = 3;", "const d = 4;",
      "const e = 5;", "  return x * 3;", "}" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 60, height = 10,
    })
    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))
    overlay.apply(buf, set, {}, { "a", "b", "c", "d", "e", "  return x * 2;", "}" })
    vim.api.nvim_win_set_cursor(win, { 6, 0 })

    assert.is_false(preview.is_open(), "no preview open before the first show")

    local first = preview.show(buf, win)
    assert.is_not_nil(first)
    assert.is_true(preview.is_open())

    local second = preview.show(buf, win)
    assert.is_not_nil(second)
    assert.is_true(preview.is_open())
    assert.is_false(vim.api.nvim_win_is_valid(first),
      "the previous float must be closed when the preview is re-shown")
    assert.is_true(vim.api.nvim_win_is_valid(second))

    vim.api.nvim_win_close(second, true)
    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- The bug behind "]c still closes the preview": gitsigns' async nav_hunk sets
  -- the cursor and then emits trailing CursorMoved events AT THE NEW POSITION. A
  -- dismissal that closed on the first CursorMoved unconditionally killed the
  -- float a re-show had just opened at that position. The float must survive a
  -- CursorMoved that lands on its own anchor, and only close on a real move away.
  it("survives a CursorMoved that stays on the anchor, closes on a real move", function()
    local overlay = require("difftsigns.overlay")
    config.setup({})
    local buf = buf_with({ "const a = 1;", "const b = 2;", "const c = 3;", "const d = 4;",
      "const e = 5;", "  return x * 3;", "}" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 60, height = 10,
    })
    local set = verdict.compute({
      { type = "change", added = { start = 6, count = 1 }, removed = { start = 6, count = 1 } },
    }, fixture("single_token"))
    overlay.apply(buf, set, {}, { "a", "b", "c", "d", "e", "  return x * 2;", "}" })
    vim.api.nvim_win_set_cursor(win, { 6, 0 })

    local float = preview.show(buf, win)
    assert.is_not_nil(float)

    -- A CursorMoved fired without the cursor actually moving (the spurious one).
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert.is_true(vim.api.nvim_win_is_valid(float),
      "a CursorMoved on the anchor line must NOT dismiss the preview")

    -- Now a genuine move off the hunk.
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert.is_false(vim.api.nvim_win_is_valid(float),
      "a real move off the anchor must dismiss the preview")
    assert.is_false(preview.is_open())

    overlay.forget(buf)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
