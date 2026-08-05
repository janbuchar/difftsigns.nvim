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
--- Three things are drawn that gitsigns alone cannot draw:
---   1. changed TOKENS highlighted within their lines (difft's byte ranges);
---   2. reflow-only lines DIMMED, matching the gutter's verdict;
---   3. a header stating the split, so "3 of 5 lines are noise" is legible at a
---      glance rather than inferred.

local config = require("difftsigns.config")
local overlay = require("difftsigns.overlay")
local verdict = require("difftsigns.verdict")

local M = {}

M.ns = vim.api.nvim_create_namespace("difftsigns_preview")

--- @class DifftSigns.PreviewLine
--- @field text      string
--- @field hl        string|nil  -- whole-line highlight; nil when tokens carry the meaning
--- @field prefix_hl string|nil  -- highlight for the leading -/+ marker
--- @field token_hl  string|nil  -- directional group for this line's token ranges
--- @field tokens    { from: integer, to: integer }[]|nil  -- byte ranges to emphasise
--- @field offset    integer     -- byte offset the text was shifted by (the prefix)

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
  out[#out + 1] = { text = header, hl = "Title", offset = 0 }

  --- Emit one source line.
  ---
  --- WHERE THE COLOUR GOES, and why. When difftastic gives us token detail, the
  --- tokens carry the whole meaning and a whole-line wash is worse than
  --- redundant: it competes with the tokens for attention and dilutes the one
  --- thing the preview exists to show. So a line with tokens gets NO line
  --- highlight — only its changed tokens, coloured by direction (green added,
  --- red removed) — plus its `-`/`+` marker, so the eye can still scan sides.
  ---
  --- Three cases, in order:
  ---   1. tokens present     -> tokens only. The precise answer.
  ---   2. no detail at all   -> whole line. Only for whole-file created/deleted,
  ---                            where difftastic omits chunks and we genuinely
  ---                            know nothing more specific.
  ---   3. significant, but no tokens on THIS side -> uncoloured. Happens via
  ---      cross-attribution: `doThing(alpha, beta)` -> `doThing(alpha)` is real,
  ---      but nothing was *added*, so the `+` line has no added token. Green
  ---      would lie; dim would deny it is part of a real change. Neutral is the
  ---      honest answer, and the `-` line above carries the red token.
  ---   4. otherwise          -> dimmed, matching the gutter's reflow verdict.
  ---
  --- @param prefix string       -- "-" or "+"
  --- @param text string
  --- @param dir_hl string       -- DifftSignsRemoved / DifftSignsAdded
  --- @param toks table[]|nil    -- token edits on this line, this side
  --- @param significant boolean
  --- @param no_detail boolean
  local function push(prefix, text, dir_hl, toks, significant, no_detail)
    local ranges, token_hl, line_hl, prefix_hl = nil, nil, nil, nil

    if toks ~= nil and #toks > 0 then
      ranges = {}
      for _, e in ipairs(toks) do
        ranges[#ranges + 1] = { from = #prefix + e.col_start, to = #prefix + e.col_end }
      end
      token_hl = dir_hl
      prefix_hl = dir_hl
    elseif no_detail and significant then
      line_hl = dir_hl
      prefix_hl = dir_hl
    elseif significant then
      prefix_hl = dir_hl -- part of a real change, but nothing changed on this side
    else
      line_hl = "DifftSignsContext"
      prefix_hl = "DifftSignsContext"
    end

    out[#out + 1] = {
      text = prefix .. text,
      hl = line_hl,
      prefix_hl = prefix_hl,
      token_hl = token_hl,
      tokens = ranges,
      offset = #prefix,
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
          push("-", src, "DifftSignsRemoved", by.lhs[lnum],
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
        push("+", src, "DifftSignsAdded", by.rhs[lnum],
          verdict.is_significant(owner, lnum), owner.no_token_detail)
      end
    end
  end

  if #out == 1 then
    out[#out + 1] = { text = "  (no line content to show)", hl = "Comment", offset = 0 }
  end

  return out
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

  -- Both priorities are set EXPLICITLY, and the ordering between them is the
  -- entire reason the structural highlight is visible at all.
  --
  -- nvim_buf_set_extmark defaults `priority` to 4096. An earlier version set the
  -- whole-line highlight with no priority (so: 4096) and the token highlight to
  -- 200, on the assumption that "placed later wins". It does not — extmark
  -- precedence is by priority alone. The line highlight therefore painted over
  -- every token highlight and the structural change, the one thing this preview
  -- exists to show, was invisible in every hunk.
  local PRIORITY_LINE = 100
  local PRIORITY_TOKEN = 200

  for i, l in ipairs(rendered) do
    local row = i - 1

    if l.hl ~= nil then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        end_row = row,
        end_col = #l.text,
        hl_group = l.hl,
        priority = PRIORITY_LINE,
      })
    end

    -- The leading -/+ marker, so sides remain scannable even when the line
    -- content itself is left uncoloured.
    if l.prefix_hl ~= nil and l.offset > 0 then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        end_row = row,
        end_col = math.min(l.offset, #l.text),
        hl_group = l.prefix_hl,
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
  vim.bo[buf].filetype = "difftsigns-preview"

  local width = 0
  for _, t in ipairs(texts) do
    width = math.max(width, vim.fn.strdisplaywidth(t))
  end

  local float = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.max(20, math.min(width + 1, math.floor(vim.o.columns * 0.85))),
    height = math.min(#texts, 24),
    style = "minimal",
    border = "rounded",
    title = " difftsigns ",
    title_pos = "left",
  })

  -- Dismiss on the next cursor move, like gitsigns' own preview.
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(float) then
        vim.api.nvim_win_close(float, true)
      end
    end,
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
