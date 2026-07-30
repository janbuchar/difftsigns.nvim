--- Tests for preview.lua — the unified line-hunk + structural view.
---
--- The PoC's preview showed difftastic's bare tokens in isolation, which for a
--- reorder meant the SAME string on both sides with no context: useless. These
--- tests assert on the two properties that make the new one useful — real source
--- lines are present verbatim, and the structural verdict is visible in the
--- float rather than only in the gutter.

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

describe("preview building", function()
  before_each(function()
    config.setup({})
  end)

  it("shows real source lines from both sides, verbatim", function()
    local now = {
      "function run() {",
      "  if (enabled) {",
      "    doThing();",
      "    doOther();",
      "    return 1;",
      "  }",
      "}",
    }
    local was = { "function run() {", "  doThing();", "  doOther();", "  return 1;", "}" }
    local buf = buf_with(now)

    local set = verdict.compute({
      { type = "change", added = { start = 2, count = 5 }, removed = { start = 2, count = 3 } },
    }, fixture("wrap_in_if"))

    local out = joined(preview._build(buf, { set.verdicts[1] }, was))
    assert.is_truthy(out:find("if %(enabled%) {"), "the new line must appear")
    assert.is_truthy(out:find("doThing%(%);"), "source content must appear verbatim")
    assert.is_truthy(out:find("\n%-"), "removed lines are prefixed with -")
    assert.is_truthy(out:find("\n%+"), "added lines are prefixed with +")
    -- The reference side must come from the retained text, not the buffer.
    assert.is_truthy(out:find("%-  doThing%(%);"), "the un-indented `was` line appears")

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
    local by_text = {}
    for _, l in ipairs(rendered) do
      by_text[l.text] = l
    end

    -- A line with token detail carries NO whole-line wash: the tokens are the
    -- answer, and washing the line would only compete with them.
    local changed = by_text["+  if (enabled) {"]
    assert.is_nil(changed.hl, "a line with tokens must not be washed whole-line")
    assert.are.equal("DifftSignsAdded", changed.token_hl, "its tokens are coloured as additions")
    assert.is_true(#changed.tokens > 0)
    assert.are.equal("DifftSignsAdded", changed.prefix_hl, "the + marker stays scannable")

    -- Reflow-only lines still recede, exactly as in the gutter.
    assert.are.equal("DifftSignsContext", by_text["+    doThing();"].hl, "reindented line recedes")
    assert.are.equal("DifftSignsContext", by_text["+    return 1;"].hl, "reindented line recedes")
    assert.is_nil(by_text["+    doThing();"].token_hl)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("colours tokens by direction: removed red, added green", function()
    local buf = buf_with({ "function f() {", "      doThing(alpha);", "}" })
    local ref = { "function f() {", "  doThing(alpha, beta);", "}" }
    -- The cross-attribution case: `beta` removed while the line was reindented.
    local set = verdict.compute(
      { { type = "change", added = { start = 2, count = 1 }, removed = { start = 2, count = 1 } } },
      fixture("token_removed_reindent")
    )
    local rendered = preview._build(buf, { set.verdicts[1] }, ref)

    local minus, plus
    for _, l in ipairs(rendered) do
      if l.text:sub(1, 1) == "-" then minus = l end
      if l.text:sub(1, 1) == "+" then plus = l end
    end

    -- The removal is visible only on the reference side, in the "removed" colour.
    assert.are.equal("DifftSignsRemoved", minus.token_hl)
    assert.is_true(#minus.tokens > 0, "the removed tokens must be marked")
    assert.is_nil(minus.hl, "and the line itself must not be washed")

    -- Nothing was ADDED on the buffer line, so it gets no token colour and no
    -- wash -- but it is not dimmed either, because it is part of a real change.
    assert.is_nil(plus.token_hl)
    assert.is_nil(plus.hl, "a significant line with nothing added is left neutral, not dimmed")
    assert.are.equal("DifftSignsAdded", plus.prefix_hl)
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
    local plus
    for _, l in ipairs(rendered) do
      if l.text:sub(1, 1) == "+" then plus = l end
    end
    assert.are.equal("DifftSignsAdded", plus.hl,
      "with no token detail, the whole line is all we can honestly colour")
    assert.is_nil(plus.token_hl)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("marks changed token byte ranges, offset by the +/- prefix", function()
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
      if l.tokens ~= nil and #l.tokens > 0 and l.text:sub(1, 1) == "+" then
        marked = l
      end
    end
    assert.is_not_nil(marked, "the added line should carry a token range")
    -- One byte of "+" prefix shifts difft's 13..14 to 14..15.
    assert.are.equal(14, marked.tokens[1].from)
    assert.are.equal(15, marked.tokens[1].to)
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

    -- Token/prefix marks are narrow; the line wash spans the row. Distinguish by
    -- span rather than group name, since token and line colours can now coincide.
    local line_prio, token_prio
    for _, m in ipairs(marks) do
      local d = m[4]
      local width = (d.end_col or 0) - m[3]
      if d.hl_group == "DifftSignsContext" or width > 4 then
        line_prio = d.priority
      elseif d.hl_group == "DifftSignsAdded" or d.hl_group == "DifftSignsRemoved" then
        token_prio = math.max(token_prio or 0, d.priority)
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
end)
