--- Tests for signs.lua region indexing, layer bookkeeping, and ACTUAL rendering.
--- Most tests validate the internal lookup tables, but there is also a
--- screenstring-based test that reads the real gutter grid — because "the
--- indexing is right" does NOT imply "the sign renders" (ephemeral signs index
--- fine and draw nothing; that regression is what this guards against).

local signs = require("dft-signs.signs")
local config = require("dft-signs.config")

local function make_buf(nlines)
  local buf = vim.api.nvim_create_buf(true, false)
  local lines = {}
  for i = 1, nlines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("signs.set_regions", function()
  before_each(function()
    config.setup({})
  end)

  it("indexes span across all lines but changed only on changed lines", function()
    local buf = make_buf(10)
    signs.set_regions(buf, {
      {
        span = { from = 3, to = 6 },
        changed = { 4, 5 },
        deletions = {},
        kind = "change",
      },
    })

    local st = signs._state(buf)
    -- Layer 2 covers the whole span, context lines included.
    for line = 3, 6 do
      assert.is_not_nil(st.span_by_line[line], "span should cover line " .. line)
    end
    assert.is_nil(st.span_by_line[2])
    assert.is_nil(st.span_by_line[7])

    -- Layer 1 only on genuinely changed lines.
    assert.is_true(st.changed_by_line[4])
    assert.is_true(st.changed_by_line[5])
    assert.is_nil(st.changed_by_line[3]) -- context inside span, not changed
    assert.is_nil(st.changed_by_line[6])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("resolves the created-file whole-buffer sentinel against buffer length", function()
    local buf = make_buf(7)
    signs.set_regions(buf, {
      { span = { from = 1, to = -1 }, changed = {}, deletions = {}, kind = "add" },
    })
    local st = signs._state(buf)
    for line = 1, 7 do
      assert.is_not_nil(st.span_by_line[line])
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("accumulates deletion counts per anchor", function()
    local buf = make_buf(5)
    signs.set_regions(buf, {
      {
        span = { from = 2, to = 2 },
        changed = {},
        deletions = { { anchor = 2, count = 3 } },
        kind = "delete",
      },
    })
    local st = signs._state(buf)
    assert.are.equal(3, st.deletion_by_line[2])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("toggles spans without touching changed layer", function()
    local buf = make_buf(5)
    signs.set_regions(buf, {
      { span = { from = 1, to = 3 }, changed = { 2 }, deletions = {}, kind = "change" },
    })
    local st = signs._state(buf)
    assert.is_true(st.show_spans)
    signs.toggle_spans(buf)
    assert.is_false(st.show_spans)
    assert.is_true(st.show_changes) -- untouched
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clear() drops all region data", function()
    local buf = make_buf(5)
    signs.set_regions(buf, {
      { span = { from = 1, to = 3 }, changed = { 2 }, deletions = {}, kind = "change" },
    })
    signs.clear(buf)
    local st = signs._state(buf)
    assert.are.same({}, st.span_by_line)
    assert.are.same({}, st.changed_by_line)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("region_at finds the region whose span contains a line", function()
    local buf = make_buf(10)
    local region = {
      span = { from = 3, to = 6 },
      changed = { 4 },
      deletions = {},
      edits = { { side = "rhs", line = 4, content = "y", highlight = "normal" } },
      kind = "change",
    }
    signs.set_regions(buf, { region })

    assert.are.equal(region, signs.region_at(buf, 4)) -- inside span
    assert.are.equal(region, signs.region_at(buf, 3)) -- span edge
    assert.is_nil(signs.region_at(buf, 2)) -- outside
    assert.is_nil(signs.region_at(buf, 7))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("preview_span shows real source lines with changed tokens, not bare tokens", function()
    local buf = vim.api.nvim_create_buf(true, false)
    -- Buffer (rhs / now): line 3 is `let x = 2;` with the `2` at byte col 8-9.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "fn main() {",
      "    // ctx",
      "    let x = 2;",
      "}",
    })
    -- Reference (lhs / was): the same line had `1` instead of `2`.
    local ref_lines = {
      "fn main() {",
      "    // ctx",
      "    let x = 1;",
      "}",
    }

    signs.set_regions(buf, {
      {
        span = { from = 2, to = 3 },
        changed = { 3 },
        deletions = {},
        edits = {
          -- The `1` on reference line 3, byte col 12-13.
          { side = "lhs", line = 3, content = "1", highlight = "keyword", col_start = 12, col_end = 13 },
          -- The `2` on buffer line 3, byte col 12-13.
          { side = "rhs", line = 3, content = "2", highlight = "keyword", col_start = 12, col_end = 13 },
        },
        kind = "change",
      },
    }, ref_lines)

    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 60, height = 10,
    })
    vim.api.nvim_win_set_cursor(win, { 3, 0 })

    local before = #vim.api.nvim_list_wins()
    signs.preview_span(buf, win)
    assert.is_true(#vim.api.nvim_list_wins() > before, "expected a preview float to open")

    local float
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= win then float = w end
    end
    assert.is_not_nil(float)
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")

    assert.is_truthy(text:find("reference"))
    assert.is_truthy(text:find("buffer"))
    -- The KEY improvement: the full source line appears, not just the token.
    assert.is_truthy(text:find("let x = 1;"), "reference source line should appear verbatim")
    assert.is_truthy(text:find("let x = 2;"), "buffer source line should appear verbatim")

    vim.api.nvim_win_close(float, true)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("preview_span includes surrounding context lines (for reorders)", function()
    config.setup({ preview_context = 1 })

    local lines = {}
    for i = 1, 10 do
      lines[i] = "code line " .. i
    end
    lines[5] = "    changed_here"
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    signs.set_regions(buf, {
      {
        span = { from = 5, to = 5 },
        changed = { 5 },
        deletions = {},
        edits = {
          { side = "rhs", line = 5, content = "changed_here", highlight = "normal", col_start = 4, col_end = 16 },
        },
        kind = "change",
      },
    }, lines)

    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", row = 0, col = 0, width = 60, height = 12,
    })
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    signs.preview_span(buf, win)

    local float
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= win then float = w end
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")

    -- With context=1, lines 4 and 6 (the neighbours) must appear alongside 5.
    assert.is_truthy(text:find("code line 4"), "context line above should appear")
    assert.is_truthy(text:find("changed_here"), "the changed line should appear")
    assert.is_truthy(text:find("code line 6"), "context line below should appear")
    -- The changed line is marked with '>', context lines are not.
    assert.is_truthy(text:find("> 5:"), "changed line should be marked with >")

    vim.api.nvim_win_close(float, true)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.setup({}) -- reset
  end)

  it("actually renders sign glyphs into the gutter (not just state)", function()
    -- Regression: ephemeral decoration-provider signs indexed correctly but
    -- never drew. Read the real screen grid to prove the glyphs appear.
    config.setup({
      layers = {
        changed = { enable = true, text = "C", hl = "DftSignsChange" },
        span = { enable = true, text = "S", hl = "DftSignsSpan" },
      },
    })

    local buf = make_buf(6)
    vim.api.nvim_win_set_buf(0, buf)
    vim.o.signcolumn = "yes:2"
    vim.o.number = false

    signs.set_regions(buf, {
      {
        span = { from = 2, to = 4 },
        changed = { 3 },
        deletions = {},
        edits = {},
        kind = "change",
      },
    })

    -- Line 3 (changed): expect the change glyph in the gutter.
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("normal! zt")
    vim.cmd("redraw!")
    local gutter = vim.fn.screenstring(1, 1) .. vim.fn.screenstring(1, 2)
    assert.is_truthy(gutter:find("C"), "expected change glyph 'C' in gutter, got [" .. gutter .. "]")

    -- Line 2 (span-only context): expect the span glyph, no change glyph.
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! zt")
    vim.cmd("redraw!")
    local gutter2 = vim.fn.screenstring(1, 1) .. vim.fn.screenstring(1, 2)
    assert.is_truthy(gutter2:find("S"), "expected span glyph 'S' on context line, got [" .. gutter2 .. "]")
    assert.is_nil(gutter2:find("C"), "context line must not have a change glyph")

    config.setup({}) -- reset
  end)
end)
