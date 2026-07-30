--- Tests for overlay.lua — does the dim override actually reach the screen?
---
--- These read the real screen grid via screenstring(). That is deliberate and
--- non-negotiable: the PoC spent days on signs whose internal state was perfect
--- and which drew absolutely nothing, because ephemeral extmarks silently do not
--- render sign_text. "The state is right" does not imply "the user can see it".
---
--- The overlay's job is to WIN A CELL that another plugin already owns, so the
--- tests place a stand-in gitsigns sign at gitsigns' real default priority (6)
--- and then assert on which glyph survives. A distinct noise glyph is configured
--- so the winner is identifiable on screen; in production the glyph is mirrored
--- from gitsigns and only the highlight differs.

local config = require("difftsigns.config")
local overlay = require("difftsigns.overlay")

local GITSIGNS_PRIORITY = 6 -- gitsigns' documented default
local foreign_ns = vim.api.nvim_create_namespace("test_pretend_gitsigns")

local function make_buf(nlines)
  local buf = vim.api.nvim_create_buf(true, false)
  local lines = {}
  for i = 1, nlines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  vim.o.signcolumn = "yes:1"
  vim.o.number = false
  vim.o.relativenumber = false
  return buf
end

--- Place a stand-in for a gitsigns sign.
local function place_foreign(buf, lnum, text)
  vim.api.nvim_buf_set_extmark(buf, foreign_ns, lnum - 1, 0, {
    sign_text = text,
    sign_hl_group = "GitSignsChange",
    priority = GITSIGNS_PRIORITY,
  })
end

--- What glyph is actually rendered in the sign column for a buffer line?
local function gutter_at(lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! zt")
  vim.cmd("redraw!")
  return vim.fn.screenstring(1, 1)
end

--- A verdict set marking `noise` lines as noise and `sig` lines as significant,
--- all within one synthetic hunk.
local function verdict_set(from, count, noise)
  local lines = {}
  for lnum = from, from + count - 1 do
    lines[lnum] = not noise[lnum]
  end
  return {
    unavailable = false,
    verdicts = {
      {
        hunk = { type = "change", added = { start = from, count = count }, removed = { start = from, count = count } },
        significant = true,
        lines = lines,
        anchor_significant = false,
        delete_marker_line = nil,
        edits = {},
      },
    },
  }
end

local function signs_for(from, count)
  local out = {}
  for lnum = from, from + count - 1 do
    out[#out + 1] = { lnum = lnum, type = "change", hunk_index = 1 }
  end
  return out
end

describe("overlay rendering", function()
  before_each(function()
    config.setup({ noise_text = "N" })
    overlay.setup_highlights()
  end)

  after_each(function()
    config.setup({})
  end)

  it("wins the sign cell on a noise line", function()
    local buf = make_buf(8)
    for lnum = 2, 4 do
      place_foreign(buf, lnum, "G")
    end

    overlay.apply(buf, verdict_set(2, 3, { [3] = true }), signs_for(2, 3), nil)

    assert.are.equal("N", gutter_at(3),
      "the overlay must override gitsigns' glyph on a formatting-only line")
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("leaves gitsigns' glyph alone on a significant line", function()
    local buf = make_buf(8)
    for lnum = 2, 4 do
      place_foreign(buf, lnum, "G")
    end

    overlay.apply(buf, verdict_set(2, 3, { [3] = true }), signs_for(2, 3), nil)

    assert.are.equal("G", gutter_at(2), "a real change must keep gitsigns' own sign")
    assert.are.equal("G", gutter_at(4), "a real change must keep gitsigns' own sign")
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("never adds a cell where gitsigns drew nothing", function()
    -- The scope rule: we subtract emphasis, we never add it. Line 6 is noise per
    -- the verdict but carries no gitsigns sign, so nothing may appear there.
    local buf = make_buf(8)
    place_foreign(buf, 2, "G")

    -- Verdict covers 2..6, but the sign list (what gitsigns actually drew) has
    -- only line 2.
    overlay.apply(buf, verdict_set(2, 5, { [3] = true, [6] = true }), { { lnum = 2, type = "change", hunk_index = 1 } }, nil)

    assert.are.equal(" ", gutter_at(6), "no sign may be invented on an unmarked line")
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("places nothing at all when the verdict is unavailable", function()
    local buf = make_buf(6)
    place_foreign(buf, 2, "G")

    overlay.apply(buf, { verdicts = {}, unavailable = true }, signs_for(2, 1), nil)

    assert.are.equal("G", gutter_at(2),
      "an unavailable verdict must leave plain gitsigns untouched")
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {}))
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("removes the overlay on unavailable(), leaving gitsigns visible", function()
    local buf = make_buf(6)
    place_foreign(buf, 3, "G")
    overlay.apply(buf, verdict_set(3, 1, { [3] = true }), signs_for(3, 1), nil)
    assert.are.equal("N", gutter_at(3))

    overlay.unavailable(buf, "difft exploded")
    assert.are.equal("G", gutter_at(3), "falling back must restore plain gitsigns")
    assert.is_truthy(overlay.status(buf):find("difft exploded"))
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("toggles off to reveal plain gitsigns, and back on again", function()
    local buf = make_buf(6)
    place_foreign(buf, 3, "G")
    overlay.apply(buf, verdict_set(3, 1, { [3] = true }), signs_for(3, 1), nil)
    assert.are.equal("N", gutter_at(3))

    assert.is_false(overlay.toggle(buf))
    assert.are.equal("G", gutter_at(3), "toggled off shows everything again")

    assert.is_true(overlay.toggle(buf))
    assert.are.equal("N", gutter_at(3))
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("mirrors gitsigns' glyph when noise_text is unset", function()
    -- Both branches of the mirror are tested explicitly by stubbing the
    -- quarantine module, rather than depending on whether gitsigns happens to be
    -- loaded and configured in the test process.
    local gsmod = require("difftsigns.gitsigns")
    local real = gsmod.sign_text
    config.setup({})

    local buf = make_buf(6)
    place_foreign(buf, 3, "G")

    -- (a) A glyph is available: mirror it, so only the colour of the cell changes.
    gsmod.sign_text = function()
      return "M"
    end
    overlay.apply(buf, verdict_set(3, 1, { [3] = true }), signs_for(3, 1), nil)
    assert.are.equal("M", gutter_at(3), "the overlay should reuse gitsigns' own glyph")

    -- (b) Nothing to mirror: leave the cell alone rather than place a blank or
    -- garbage sign. Doing nothing is always the safe direction.
    gsmod.sign_text = function()
      return nil
    end
    overlay.apply(buf, verdict_set(3, 1, { [3] = true }), signs_for(3, 1), nil)
    assert.are.equal("G", gutter_at(3), "with no glyph to mirror, leave gitsigns' cell intact")

    gsmod.sign_text = real
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clamps to the buffer so a shrunken buffer cannot error", function()
    local buf = make_buf(4)
    place_foreign(buf, 3, "G")
    assert.has_no.errors(function()
      overlay.apply(buf, verdict_set(3, 20, { [3] = true, [15] = true }), signs_for(3, 20), nil)
    end)
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("overlay.status", function()
  it("reports the noise/real split", function()
    config.setup({ noise_text = "N" })
    local buf = make_buf(8)
    overlay.apply(buf, verdict_set(2, 4, { [3] = true, [4] = true }), signs_for(2, 4), nil)
    local s = overlay.status(buf)
    assert.is_truthy(s:find("2 noise"))
    assert.is_truthy(s:find("2 real"))
    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.setup({})
  end)

  it("returns nil when there is nothing to say", function()
    local buf = make_buf(4)
    assert.is_nil(overlay.status(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("treats bufnr 0 as the current buffer", function()
    -- Regression: every Neovim API accepts 0 for "current buffer", so callers
    -- pass it. Our state is a plain table where 0 is simply a different key, so
    -- an unresolved 0 reported "no overlay" while one was visibly on screen.
    -- Found by driving the plugin in a real session, not by any unit test.
    config.setup({ noise_text = "N" })
    local buf = make_buf(6)
    vim.api.nvim_win_set_buf(0, buf)
    overlay.apply(buf, verdict_set(2, 2, { [3] = true }), signs_for(2, 2), nil)

    assert.is_not_nil(overlay.verdicts(0), "verdicts(0) must resolve to the current buffer")
    assert.is_not_nil(overlay.status(0), "status(0) must resolve to the current buffer")
    assert.are.equal(overlay.status(buf), overlay.status(0))
    assert.are.equal(overlay.verdicts(buf), overlay.verdicts(0))

    overlay.forget(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.setup({})
  end)
end)
