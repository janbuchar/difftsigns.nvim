--- preview.lua
---
--- The unified hunk preview (REDESIGN §2 R5): one float showing the line hunk in
--- gitsigns' familiar shape, with difftastic's structural detail layered on top.
---
--- Why this is honest now, when the PoC's preview was not. The PoC previewed a
--- *structural chunk* and had to concede there was "no honest line block" for
--- one, so it invented a layout nobody asked for. Iteration 2 previews a *line
--- hunk*, which is an entirely honest line block — removed lines, then added
--- lines — and difftastic's token ranges become annotation INSIDE it. Same
--- philosophy as the gutter: don't build a parallel UI, enrich the existing one.
---
--- The source lines are shown VERBATIM and syntax-highlighted like the buffer
--- they came from: the float's filetype is set to the source buffer's, so
--- treesitter/syntax colours them exactly as you'd read them in place. The -/+
--- markers live in the SIGN COLUMN (not inline), so the source text starts at
--- column 0 and the highlighter parses clean lines rather than diff-prefixed
--- ones. Change emphasis is therefore a red/green BACKGROUND, not a foreground
--- colour, so it stands out without fighting the syntax colours underneath.
---
--- Three things are drawn that syntax highlighting alone cannot:
---   1. changed TOKENS washed with a directional background (difft's byte ranges);
---   2. reflow-only lines DIMMED, matching the gutter's verdict;
---   3. a header stating the split, so "3 of 5 lines are noise" is legible at a
---      glance rather than inferred.

local config = require("difftsigns.config")
local overlay = require("difftsigns.overlay")
local verdict = require("difftsigns.verdict")

local M = {}

M.ns = vim.api.nvim_create_namespace("difftsigns_preview")

--- The float currently on screen, so a `]c`/`[c` mapping can ask whether a
--- preview is open and re-show it after moving, instead of gitsigns-style
--- navigation just dismissing it on the cursor move it causes.
--- @type integer|nil
local open_float = nil

--- Whether a preview float is currently on screen.
--- @return boolean
function M.is_open()
  return open_float ~= nil and vim.api.nvim_win_is_valid(open_float)
end

--- @class DifftSigns.PreviewLine
--- @field text      string
--- @field hl        string|nil  -- whole-line highlight; nil when syntax/tokens carry the meaning
--- @field sign      string|nil  -- the sign-column marker: "-", "+", or nil for the header
--- @field sign_hl   string|nil  -- directional colour for the sign marker
--- @field token_hl  string|nil  -- directional BACKGROUND group for this line's token ranges
--- @field tokens    { from: integer, to: integer }[]|nil  -- byte ranges to emphasise

--- Group a whole verdict group's edits by side and line, so each source line can
--- be drawn once with every changed token on it marked.
--- @param group DifftSigns.Verdict[]
local function edits_by_side(group)
  local by = { lhs = {}, rhs = {} }
  for _, v in ipairs(group) do
    for _, e in ipairs(v.edits or {}) do
      local bucket = by[e.side]
      if bucket ~= nil then
        bucket[e.line] = bucket[e.line] or {}
        table.insert(bucket[e.line], e)
      end
    end
  end
  return by
end

--- Build the float's contents for a group of contiguous verdicts.
---
--- Takes a GROUP rather than a single verdict because gitsigns can split one
--- logical edit into several adjacent hunks (see verdict.group_at_line). Keying
--- the preview to a single hunk made it show different content on different lines
--- of one visually contiguous block of signs.
---
--- @param bufnr integer
--- @param group DifftSigns.Verdict[]  -- contiguous, sorted by buffer position
--- @param ref string[]|nil
--- @return DifftSigns.PreviewLine[]
local function build(bufnr, group, ref)
  local out = {}
  local by = edits_by_side(group)

  -- ONE-SIDED CHANGES SHOW ONE SIDE.
  --
  -- If every token difftastic reported lives on one side, the other side has
  -- nothing to say and printing it is pure dead weight — you get a column of
  -- lines with no colour on them, and have to work out for yourself that none of
  -- them is the point. Observed in crawlee: adding an argument rendered the old
  -- line in full underneath, entirely uncoloured, purely to be ignored.
  --
  -- Note this is decided by TOKEN DETAIL, not by line counts: gitsigns calls a
  -- hunk a `change` whenever both sides have lines, but a change can be
  -- semantically pure-addition (a wrapped block, an added argument) or
  -- pure-deletion (a removed argument) with the opposite side merely reindented.
  --
  -- When NEITHER side has tokens the hunk is formatting-only, and then both sides
  -- ARE the information — that is the one case where seeing the reflow matters.
  local has_lhs = next(by.lhs) ~= nil
  local has_rhs = next(by.rhs) ~= nil
  local show_removed = has_lhs or not has_rhs
  local show_added = has_rhs or not has_lhs

  -- Aggregate the group into one unified-diff-style range, and one verdict
  -- lookup per buffer line.
  local summary_sig, summary_noise = 0, 0
  local rem_start, rem_count, add_start, add_count = nil, 0, nil, 0
  local kinds, seen_kind = {}, {}
  local verdict_for_line = {}

  -- A zero-count side reports an insertion *point*, not a real line: an `add`
  -- hunk's `removed.start` is "the line after which this was inserted". Letting
  -- it into the range minimum shifts the header by one (observed: `-362,1` for a
  -- hunk that actually removed line 363). So only counted sides set the start,
  -- and the anchors are kept separately as a fallback for a group that adds or
  -- removes nothing at all.
  local rem_anchor, add_anchor = nil, nil

  for _, v in ipairs(group) do
    local a, r = v.hunk.added, v.hunk.removed
    if r.count > 0 then
      rem_start = math.min(rem_start or r.start, r.start)
      rem_count = rem_count + r.count
    else
      rem_anchor = rem_anchor or r.start
    end
    if a.count > 0 then
      add_start = math.min(add_start or a.start, a.start)
      add_count = add_count + a.count
    else
      add_anchor = add_anchor or a.start
    end
    if not seen_kind[v.hunk.type] then
      seen_kind[v.hunk.type] = true
      kinds[#kinds + 1] = v.hunk.type
    end
    for lnum, sig in pairs(v.lines) do
      verdict_for_line[lnum] = v
      if sig then
        summary_sig = summary_sig + 1
      else
        summary_noise = summary_noise + 1
      end
    end
  end

  local kind = table.concat(kinds, "+")
  local range = ("@@ -%d,%d +%d,%d @@"):format(
    rem_start or rem_anchor or 0, rem_count,
    add_start or add_anchor or 0, add_count
  )

  -- Say so when a side is suppressed, but only when its absence would be
  -- surprising — i.e. the hunk really does have lines there and we chose not to
  -- print them. For an `add`/`delete` hunk the one-sidedness is already obvious.
  local trimmed = ""
  if not show_removed and rem_count > 0 then
    trimmed = " · additions only"
  elseif not show_added and add_count > 0 then
    trimmed = " · deletions only"
  end
  -- Make it explicit when several gitsigns hunks were merged, so the aggregated
  -- range is not mistaken for a single hunk gitsigns would stage as a unit.
  local merged = #group > 1 and (" (%d hunks)"):format(#group) or ""

  -- Header: the one line that makes the plugin's judgement explicit.
  local header
  if summary_noise > 0 and summary_sig > 0 then
    header = ("%s %s%s%s  %d real, %d formatting-only")
      :format(kind, range, merged, trimmed, summary_sig, summary_noise)
  elseif summary_noise > 0 and summary_sig == 0 then
    header = ("%s %s%s%s  formatting only — no structural change")
      :format(kind, range, merged, trimmed)
  else
    header = ("%s %s%s%s"):format(kind, range, merged, trimmed)
  end
  out[#out + 1] = { text = header, hl = "Title" }

  --- Emit one source line.
  ---
  --- WHERE THE COLOUR GOES, and why. The line itself is drawn with the source
  --- buffer's own syntax highlighting, so change emphasis must sit ON TOP of that
  --- rather than replace it: changed tokens get a directional BACKGROUND wash
  --- (green added, red removed) that leaves the syntax foreground legible, plus a
  --- `-`/`+` marker in the sign column so sides stay scannable.
  ---
  --- Four cases, in order:
  ---   1. tokens present     -> token backgrounds only, over syntax. The precise
  ---                            answer.
  ---   2. no detail at all   -> whole-line background wash, NO syntax. Only for
  ---                            whole-file created/deleted, where difftastic omits
  ---                            chunks and we know nothing more specific.
  ---   3. significant, but no tokens on THIS side -> syntax only, no wash. Happens
  ---      via cross-attribution: `doThing(alpha, beta)` -> `doThing(alpha)` is
  ---      real, but nothing was *added*, so the `+` line has no added token. A
  ---      wash would lie; dimming would deny it is part of a real change. The
  ---      marker carries the side, and the `-` line above carries the red wash.
  ---   4. otherwise          -> dimmed, matching the gutter's reflow verdict. The
  ---      dim intentionally overrides syntax: "this is noise" is the point.
  ---
  --- @param prefix string       -- "-" or "+"
  --- @param text string
  --- @param dir_bg string       -- DifftSignsRemovedBg / DifftSignsAddedBg
  --- @param dir_hl string       -- DifftSignsRemoved / DifftSignsAdded (the marker)
  --- @param toks table[]|nil    -- token edits on this line, this side
  --- @param significant boolean
  --- @param no_detail boolean
  local function push(prefix, text, dir_bg, dir_hl, toks, significant, no_detail)
    local ranges, token_hl, line_hl = nil, nil, nil

    if toks ~= nil and #toks > 0 then
      ranges = {}
      for _, e in ipairs(toks) do
        ranges[#ranges + 1] = { from = e.col_start, to = e.col_end }
      end
      token_hl = dir_bg
    elseif no_detail and significant then
      line_hl = dir_bg
    elseif significant then
      -- syntax only; the marker carries the side
    else
      line_hl = "DifftSignsContext"
    end

    out[#out + 1] = {
      text = text,
      hl = line_hl,
      sign = prefix,
      sign_hl = dir_hl,
      token_hl = token_hl,
      tokens = ranges,
    }
  end

  -- Removed side, from the retained reference text, in buffer order across the
  -- whole group.
  if ref ~= nil and show_removed then
    for _, v in ipairs(group) do
      local r = v.hunk.removed
      for lnum = r.start, r.start + r.count - 1 do
        local src = ref[lnum]
        if src ~= nil then
          -- A removed line is judged by the REFERENCE side: it has no buffer line
          -- of its own to consult.
          push("-", src, "DifftSignsRemovedBg", "DifftSignsRemoved", by.lhs[lnum],
            v.anchor_significant, v.no_token_detail)
        end
      end
    end
  end

  -- Added side, read live from the buffer, in buffer order across the group.
  for _, v in ipairs(show_added and group or {}) do
    local a = v.hunk.added
    if a.count > 0 then
      local lines = vim.api.nvim_buf_get_lines(bufnr, a.start - 1, a.start - 1 + a.count, false)
      for i, src in ipairs(lines) do
        local lnum = a.start + i - 1
        local owner = verdict_for_line[lnum] or v
        push("+", src, "DifftSignsAddedBg", "DifftSignsAdded", by.rhs[lnum],
          verdict.is_significant(owner, lnum), owner.no_token_detail)
      end
    end
  end

  if #out == 1 then
    out[#out + 1] = { text = "  (no line content to show)", hl = "Comment" }
  end

  return out
end

--- Give the float the source buffer's own syntax highlighting.
---
--- Prefer treesitter (it parses the real language and is what colours a modern
--- buffer); fall back to legacy `:syntax` via a filetype only when no treesitter
--- parser is installed. Failures are swallowed: a preview with no syntax colour
--- is a mild downgrade, not a reason to refuse to open.
---
--- Only source lines are meant to be highlighted, but the highlighter parses the
--- whole buffer (header included). That is harmless: every non-source line
--- carries a whole-line extmark (Title/Comment/dim) placed above the syntax
--- layer, so it paints over any stray syntax colour on those rows.
---
--- @param buf integer            -- the float's scratch buffer
--- @param src_ft string          -- the source buffer's filetype
local function apply_source_syntax(buf, src_ft)
  if src_ft == nil or src_ft == "" then
    return
  end

  local lang = vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(src_ft) or src_ft
  local ok = pcall(vim.treesitter.start, buf, lang)
  if ok then
    return
  end

  -- No parser: fall back to legacy syntax. Setting `syntax` (not `filetype`)
  -- loads the highlighter without firing filetype autocmds — no LSP or plugins
  -- attach to this throwaway buffer.
  pcall(function()
    vim.bo[buf].syntax = src_ft
  end)
end

--- Show the preview for the hunk under the cursor.
--- @param bufnr integer|nil
--- @param winid integer|nil
--- @return integer|nil float_win
function M.show(bufnr, winid)
  -- Resolve the "0 means current" convention: our per-buffer state is keyed by
  -- real buffer number, so an unresolved 0 would look like an unknown buffer.
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if winid == nil or winid == 0 then
    winid = vim.api.nvim_get_current_win()
  end

  -- Re-showing (e.g. from a `]c` that advanced to the next hunk): drop the old
  -- float first, otherwise its still-pending CursorMoved autocmd would close the
  -- new one the moment the cursor settles.
  if M.is_open() then
    vim.api.nvim_win_close(open_float, true)
    open_float = nil
  end

  local set = overlay.verdicts(bufnr)
  if set == nil then
    local reason = overlay.status(bufnr)
    vim.notify(reason or "difftsigns: no structural verdict for this buffer", vim.log.levels.INFO)
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)[1]
  -- The whole contiguous run, not one hunk: gitsigns may have split a single
  -- logical edit, and previewing only part of it gave different results on
  -- different lines of one unbroken block of signs.
  local group = verdict.group_at_line(set, cursor)
  if #group == 0 then
    vim.notify("difftsigns: no hunk under the cursor", vim.log.levels.INFO)
    return nil
  end

  local rendered = build(bufnr, group, overlay.reference(bufnr))

  local buf = vim.api.nvim_create_buf(false, true)
  local texts = {}
  for i, l in ipairs(rendered) do
    texts[i] = l.text
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)

  -- The source buffer's syntax highlighting is applied to the source lines, so
  -- they read exactly as they do in place. This sits UNDERNEATH our extmarks:
  -- treesitter/syntax highlights are low priority (treesitter defaults to 100),
  -- and our token/whole-line washes only touch the background, so the syntax
  -- foreground stays legible through them. The one group that DOES override
  -- syntax is DifftSignsContext (the dim), which is the point: a reflow-only line
  -- should recede, colour and all. It also paints the header/no-content rows,
  -- which are not source and would otherwise be mis-highlighted by the parser.
  local src_ft = vim.bo[bufnr].filetype
  apply_source_syntax(buf, src_ft)

  -- Both priorities are set EXPLICITLY, and the ordering between them relative to
  -- the syntax layer is what makes the structural highlight visible at all.
  --
  -- nvim_buf_set_extmark defaults `priority` to 4096. An earlier version set the
  -- whole-line highlight with no priority (so: 4096) and the token highlight to
  -- 200, on the assumption that "placed later wins". It does not — extmark
  -- precedence is by priority alone. The line highlight therefore painted over
  -- every token highlight and the structural change, the one thing this preview
  -- exists to show, was invisible in every hunk. Both must also sit ABOVE the
  -- treesitter layer (priority 100) so the token wash and the dim actually show.
  local PRIORITY_LINE = 150
  local PRIORITY_TOKEN = 200

  for i, l in ipairs(rendered) do
    local row = i - 1

    if l.hl ~= nil then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        end_row = row,
        end_col = #l.text,
        hl_group = l.hl,
        -- Extend the wash/dim across the full row so a reformatted line reads as
        -- one continuous block, like a real diff. Sits above the syntax layer so
        -- the dim actually shows (a dimmed noise line must beat syntax colours).
        hl_eol = true,
        priority = PRIORITY_LINE,
      })
    end

    -- The leading -/+ marker, in the sign column, so sides stay scannable while
    -- the source text starts at column 0 and highlights cleanly.
    if l.sign ~= nil then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        sign_text = l.sign,
        sign_hl_group = l.sign_hl,
        priority = PRIORITY_TOKEN,
      })
    end

    for _, r in ipairs(l.tokens or {}) do
      local from = math.min(r.from, #l.text)
      local to = math.min(r.to, #l.text)
      if to > from and l.token_hl ~= nil then
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, from, {
          end_row = row,
          end_col = to,
          hl_group = l.token_hl,
          priority = PRIORITY_TOKEN,
        })
      end
    end
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 0
  for _, t in ipairs(texts) do
    width = math.max(width, vim.fn.strdisplaywidth(t))
  end

  -- Pin the float to the start of the text rather than the cursor column, so it
  -- always lands in the same place regardless of where the cursor sits on the
  -- line. `textoff` is the gutter width (number + sign + fold columns), so the
  -- float clears them and the gutter stays visible. Vertically it tracks the
  -- cursor's screen row (accounting for wrap/folds via screenpos), just below it.
  local win_top = vim.api.nvim_win_get_position(winid)[1]
  local cursor_screen = vim.fn.screenpos(winid, vim.api.nvim_win_get_cursor(winid)[1], 1)
  local row = (cursor_screen.row > 0) and (cursor_screen.row - win_top) or 0
  local gutter = vim.fn.getwininfo(winid)[1].textoff

  -- Widen by 2 for the sign column that carries the -/+ markers: `style=minimal`
  -- suppresses it by default, so we turn it back on below and must leave room.
  local SIGN_WIDTH = 2
  local float = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = winid,
    row = row + 1,
    col = gutter,
    width = math.max(20, math.min(width + SIGN_WIDTH, math.floor(vim.o.columns * 0.85))),
    height = math.min(#texts, 24),
    style = "minimal",
    border = "rounded",
    title = " difftsigns ",
    title_pos = "left",
  })

  -- `style=minimal` sets signcolumn=no; the -/+ markers live there, so re-enable
  -- it, pinned to one cell so the source text stays aligned with the header.
  vim.wo[float].signcolumn = "yes:1"

  open_float = float

  -- Dismiss when the cursor genuinely LEAVES the hunk, like gitsigns' own
  -- preview — not on the first CursorMoved unconditionally. gitsigns' async
  -- nav_hunk sets the cursor and then emits trailing CursorMoved/redraw events at
  -- the new position; a `once` autocmd fired on one of those and closed the float
  -- a `]c` re-show had just opened, so the preview never survived a jump. Anchor
  -- on the position we opened at and only close on a real move away from it.
  local anchor_win = winid
  local anchor_pos = vim.api.nvim_win_get_cursor(winid)

  local function dismiss()
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    if open_float == float then
      open_float = nil
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      -- Gone once the float is closed (by us, a re-show, or the user).
      if not vim.api.nvim_win_is_valid(float) then
        return true
      end
      if not vim.api.nvim_win_is_valid(anchor_win) then
        dismiss()
        return true
      end
      local cur = vim.api.nvim_win_get_cursor(anchor_win)
      if cur[1] ~= anchor_pos[1] or cur[2] ~= anchor_pos[2] then
        dismiss()
        return true
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertEnter", "BufLeave" }, {
    once = true,
    callback = dismiss,
  })

  return float
end

--- Expose the builder for tests, so the layout can be asserted without opening
--- a window.
--- @param bufnr integer
--- @param group DifftSigns.Verdict[]  -- contiguous verdict group
--- @param ref string[]|nil
function M._build(bufnr, group, ref)
  return build(bufnr, group, ref)
end

return M
