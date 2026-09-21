--- The hunk preview: one float showing the line hunk in gitsigns' familiar
--- shape (removed lines, then added), with difftastic's token ranges as
--- annotation inside it.
---
--- Source lines are shown verbatim with the source buffer's syntax highlighting.
--- The -/+ markers live in the SIGN COLUMN so the highlighter parses clean
--- lines, and change emphasis is a red/green BACKGROUND so it does not fight
--- the syntax foreground.

local config = require("difftsigns.config")
local overlay = require("difftsigns.overlay")
local verdict = require("difftsigns.verdict")
local gs = require("difftsigns.gitsigns")

local M = {}

M.ns = vim.api.nvim_create_namespace("difftsigns_preview")

--- @type { win: integer, close: fun() }|nil
local open_preview = nil

--- @return boolean
function M.is_open()
  return open_preview ~= nil and vim.api.nvim_win_is_valid(open_preview.win)
end

--- @class DifftSigns.PreviewLine
--- @field text      string
--- @field hl        string|nil  -- whole-line highlight; nil when syntax/tokens carry the meaning
--- @field sign      string|nil  -- the sign-column marker: "-", "+", or nil for the header
--- @field sign_hl   string|nil  -- directional colour for the sign marker
--- @field token_hl  string|nil  -- directional BACKGROUND group for this line's token ranges
--- @field tokens    { from: integer, to: integer }[]|nil  -- byte ranges to emphasise

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

--- Build the float's contents for a group of contiguous verdicts (a GROUP, not
--- one hunk: see verdict.group_at_line).
---
--- @param bufnr integer
--- @param group DifftSigns.Verdict[]  -- contiguous, sorted by buffer position
--- @param ref string[]|nil
--- @return DifftSigns.PreviewLine[]
local function build(bufnr, group, ref)
  local out = {}
  local by = edits_by_side(group)

  local summary_sig, summary_noise = 0, 0
  local rem_start, rem_count, add_start, add_count = nil, 0, nil, 0
  local kinds, seen_kind = {}, {}
  local verdict_for_line = {}

  -- The counters below see only BUFFER lines, so a merged `delete` hunk
  -- contributes nothing to them however much it removed.
  local any_real = false

  -- A zero-count side reports an insertion *point*, not a real line (an `add`
  -- hunk's `removed.start` is "the line after which this was inserted"), so it
  -- must not enter the range minimum. Kept separately as a fallback for a
  -- group that adds or removes nothing at all.
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
    if v.anchor_significant then
      any_real = true
    end
    for lnum, sig in pairs(v.lines) do
      verdict_for_line[lnum] = v
      if sig then
        summary_sig = summary_sig + 1
        any_real = true
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

  -- One-sided changes show one side, decided by TOKEN DETAIL rather than line
  -- counts: gitsigns calls a hunk `change` whenever both sides have lines, but
  -- it can be a pure addition or deletion with the other side merely reindented.
  -- With no tokens on either side the hunk is formatting-only and both sides
  -- ARE the information.
  --
  -- The added side is kept when the line counts differ: the result then cannot
  -- be read as "the shown line minus the red tokens", and a name surviving on
  -- an unprinted new line would read as deleted.
  local has_lhs = next(by.lhs) ~= nil
  local has_rhs = next(by.rhs) ~= nil
  local show_removed = has_lhs or not has_rhs
  local show_added = has_rhs or not has_lhs or rem_count ~= add_count

  -- Only when the hunk really has lines there; for an `add`/`delete` hunk the
  -- one-sidedness is already obvious.
  local trimmed = ""
  if not show_removed and rem_count > 0 then
    trimmed = " · additions only"
  elseif not show_added and add_count > 0 then
    trimmed = " · deletions only"
  end
  -- So the aggregated range is not mistaken for something gitsigns stages as a unit.
  local merged = #group > 1 and (" (%d hunks)"):format(#group) or ""

  local header
  if summary_noise > 0 and summary_sig > 0 then
    header = ("%s %s%s%s  %d real, %d formatting-only")
      :format(kind, range, merged, trimmed, summary_sig, summary_noise)
  elseif summary_noise > 0 and not any_real then
    header = ("%s %s%s%s  formatting only — no structural change")
      :format(kind, range, merged, trimmed)
  else
    header = ("%s %s%s%s"):format(kind, range, merged, trimmed)
  end
  out[#out + 1] = { text = header, hl = "Title" }

  --- Emit one source line. Four cases, in order:
  ---   1. whole line changed -> whole-line wash, no syntax. The line exists on
  ---      one side of the GROUP only, or difftastic supplied no chunks at all.
  ---      Group, not hunk: linematch can split one-sided-looking hunks out of a
  ---      run that has lines on both sides.
  ---   2. tokens present -> token backgrounds only, over syntax.
  ---   3. significant, no tokens on THIS side -> syntax only. Cross-attribution:
  ---      `doThing(alpha, beta)` -> `doThing(alpha)` is real but nothing was
  ---      *added*. A wash would lie; a dim would deny it is part of a real change.
  ---   4. otherwise -> dimmed, matching the gutter. Overrides syntax on purpose.
  ---
  --- @param prefix string       -- "-" or "+"
  --- @param text string
  --- @param dir_bg string       -- DifftSignsRemovedBg / DifftSignsAddedBg
  --- @param dir_hl string       -- DifftSignsRemoved / DifftSignsAdded (the marker)
  --- @param toks table[]|nil    -- token edits on this line, this side
  --- @param significant boolean
  --- @param whole_line boolean  -- the line itself, not a token in it, is the change
  local function push(prefix, text, dir_bg, dir_hl, toks, significant, whole_line)
    local ranges, token_hl, line_hl = nil, nil, nil

    if whole_line and significant then
      line_hl = dir_bg
    elseif toks ~= nil and #toks > 0 then
      ranges = {}
      for _, e in ipairs(toks) do
        ranges[#ranges + 1] = { from = e.col_start, to = e.col_end }
      end
      token_hl = dir_bg
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

  if ref ~= nil and show_removed then
    for _, v in ipairs(group) do
      local r = v.hunk.removed
      local whole_line = v.no_token_detail or add_count == 0
      for lnum = r.start, r.start + r.count - 1 do
        local src = ref[lnum]
        if src ~= nil then
          -- Judged by the REFERENCE side: no buffer line of its own to consult.
          push("-", src, "DifftSignsRemovedBg", "DifftSignsRemoved", by.lhs[lnum],
            v.anchor_significant, whole_line)
        end
      end
    end
  end

  for _, v in ipairs(show_added and group or {}) do
    local a = v.hunk.added
    if a.count > 0 then
      local lines = vim.api.nvim_buf_get_lines(bufnr, a.start - 1, a.start - 1 + a.count, false)
      for i, src in ipairs(lines) do
        local lnum = a.start + i - 1
        local owner = verdict_for_line[lnum] or v
        push("+", src, "DifftSignsAddedBg", "DifftSignsAdded", by.rhs[lnum],
          verdict.is_significant(owner, lnum),
          owner.no_token_detail or rem_count == 0)
      end
    end
  end

  if #out == 1 then
    out[#out + 1] = { text = "  (no line content to show)", hl = "Comment" }
  end

  return out
end

--- Treesitter first, legacy `:syntax` when no parser is installed. Failures
--- are swallowed: no syntax colour is a mild downgrade, not a reason to refuse.
--- The highlighter also parses the header row, which is harmless: every
--- non-source row carries a whole-line extmark above the syntax layer.
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

  -- `syntax`, not `filetype`: no filetype autocmds, so no LSP attaches to this
  -- throwaway buffer.
  pcall(function()
    vim.bo[buf].syntax = src_ft
  end)
end

--- Show the preview for the hunk under the cursor; focus an already-open one.
--- @param bufnr integer|nil
--- @param winid integer|nil
--- @return integer|nil float_win
function M.show(bufnr, winid)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if winid == nil or winid == 0 then
    winid = vim.api.nvim_get_current_win()
  end

  -- A repeated call focuses the float, like gitsigns' `preview_hunk` focusing
  -- its own popup: the only way to reach the tail of a hunk too tall for the
  -- screen, since the float cannot be scrolled unfocused.
  if M.is_open() then
    vim.api.nvim_set_current_win(open_preview.win)
    return open_preview.win
  end
  -- A float already gone from under us still has its <Esc> mapping to drop.
  if open_preview ~= nil then
    open_preview.close()
  end

  -- No structural answer here (inert buffer, or no hunk we know of): hand over
  -- to gitsigns' preview so a `<leader>hp` bound to us still previews something.
  local set = overlay.verdicts(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(winid)[1]
  local group = set and verdict.group_at_line(set, cursor) or {}
  if #group == 0 then
    gs.preview_hunk()
    return nil
  end

  local rendered = build(bufnr, group, overlay.reference(bufnr))

  local buf = vim.api.nvim_create_buf(false, true)
  local texts = {}
  for i, l in ipairs(rendered) do
    texts[i] = l.text
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)

  local src_ft = vim.bo[bufnr].filetype
  apply_source_syntax(buf, src_ft)

  -- Extmark precedence is by priority alone, not placement order, and
  -- nvim_buf_set_extmark defaults to 4096. Both must sit above treesitter (100)
  -- and the token wash must beat the line wash or the structural change is
  -- invisible under it.
  local PRIORITY_LINE = 150
  local PRIORITY_TOKEN = 200

  for i, l in ipairs(rendered) do
    local row = i - 1

    if l.hl ~= nil then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        end_row = row,
        end_col = #l.text,
        hl_group = l.hl,
        hl_eol = true,
        priority = PRIORITY_LINE,
      })
    end

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

  -- Anchored to the hunk line via `bufpos`, not a screen row computed at open:
  -- `zz`/`zt`/`zb` and CTRL-E/Y scroll without firing CursorMoved, and a fixed
  -- row would detach the float from the line it describes.
  --
  -- +2 for the sign column carrying the -/+ markers (`style=minimal` suppresses
  -- it; re-enabled below).
  local SIGN_WIDTH = 2
  local BORDER_ROWS = 2
  local MIN_HEIGHT = 3
  local float_width = math.max(20, math.min(width + SIGN_WIDTH, math.floor(vim.o.columns * 0.85)))

  -- Below the hunk line, or above when that side has more room: nvim clamps an
  -- overflowing float instead of flipping it, parking it mid-window. The height
  -- is whatever the chosen side actually offers — a fixed cap either wastes a
  -- tall terminal or silently eats the tail of a long hunk.
  --- @return "NW"|"SW" anchor, integer row, integer height
  local function geometry()
    local screen_row = vim.fn.screenpos(winid, cursor, 1).row
    local below = (vim.o.lines - vim.o.cmdheight) - screen_row - BORDER_ROWS
    local above = screen_row - 1 - BORDER_ROWS
    if screen_row > 0 and below < #texts and above > below then
      return "SW", 0, math.max(math.min(#texts, above), MIN_HEIGHT)
    end
    return "NW", 1, math.max(math.min(#texts, below), MIN_HEIGHT)
  end

  -- What is off the bottom has to be named: unfocused, the float cannot be
  -- scrolled at all. `last_visible` is the last row on show, then whatever the
  -- float scrolled to once focused, so the count stays true.
  --- @param last_visible integer
  --- @return string
  local function footer(last_visible)
    local hidden = #texts - last_visible
    return hidden > 0 and (" +%d more lines "):format(hidden) or ""
  end

  local anchor, row, float_height = geometry()
  local float = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = winid,
    bufpos = { cursor - 1, 0 },
    anchor = anchor,
    row = row,
    col = 0,
    width = float_width,
    height = float_height,
    style = "minimal",
    border = "rounded",
    title = " difftsigns ",
    title_pos = "left",
    footer = footer(float_height),
    footer_pos = "right",
  })

  vim.wo[float].signcolumn = "yes:1"
  -- A header wider than the float would wrap and push the last line out of view.
  vim.wo[float].wrap = false
  -- Regex syntax groups with no attributes (yats' `typescriptParenExp`) render
  -- with the global Normal background, boxing parenthesised text in schemes
  -- where NormalFloat differs from Normal.
  vim.wo[float].winhighlight = "Normal:NormalFloat"

  -- Ignore a CursorMoved that lands on the position we opened at: gitsigns'
  -- async nav_hunk emits trailing ones there, so closing on the first event
  -- unconditionally would kill a float a `]c` had just opened.
  local anchor_win = winid
  local anchor_pos = vim.api.nvim_win_get_cursor(winid)

  -- A jump sets the ' mark to where it left from (`]c` does it explicitly,
  -- `normal! m'`, as do a search and `G`); plain cursor motion does not touch
  -- it. So a jump that lands on another hunk re-shows there — gitsigns re-opens
  -- its own popup on nav for the same reason — and everything else dismisses.
  local mark_at_open = vim.fn.getpos("''")

  --- @return boolean
  local function jumped_from_anchor()
    local mark = vim.fn.getpos("''")
    if mark[2] == mark_at_open[2] and mark[3] == mark_at_open[3] then
      return false
    end
    return mark[2] == anchor_pos[1] and mark[3] - 1 == anchor_pos[2]
  end

  -- `<Esc>` also closes. The mapping is buffer-local and lives exactly as long
  -- as the float; a buffer-local one it shadowed is put back on the way out
  -- (a global one reappears by itself once ours is gone).
  local prev_esc = vim.fn.maparg("<Esc>", "n", false, true)

  local function close()
    if open_preview ~= nil and open_preview.win == float then
      open_preview = nil
    end
    if vim.api.nvim_win_is_valid(float) then
      vim.api.nvim_win_close(float, true)
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.keymap.del, "n", "<Esc>", { buffer = bufnr })
      if prev_esc.buffer == 1 then
        vim.fn.mapset("n", false, prev_esc)
      end
    end
  end

  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, nowait = true, desc = "close difftsigns preview" })
  -- Same keys once focused, plus `q` as gitsigns' popup has. The float's buffer
  -- is scratch and wiped with it, so these need no restoring.
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, desc = "close difftsigns preview" })
  end
  open_preview = { win = float, close = close }

  vim.api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      if not vim.api.nvim_win_is_valid(float) then
        return true
      end
      if vim.api.nvim_win_is_valid(anchor_win) then
        local cur = vim.api.nvim_win_get_cursor(anchor_win)
        if cur[1] == anchor_pos[1] and cur[2] == anchor_pos[2] then
          return
        end
        if jumped_from_anchor() then
          local now = overlay.verdicts(bufnr)
          if #(now and verdict.group_at_line(now, cur[1]) or {}) > 0 then
            close()
            M.show(bufnr, winid)
            return true
          end
        end
      end
      close()
      return true
    end,
  })

  -- The line stays put under `bufpos`; how much room each side of it has does not.
  vim.api.nvim_create_autocmd("WinScrolled", {
    callback = function()
      if not vim.api.nvim_win_is_valid(float) then
        return true
      end
      if not vim.api.nvim_win_is_valid(winid) then
        close()
        return true
      end
      -- Scrolling the float itself changes nothing but the footer's count.
      if vim.api.nvim_get_current_win() == float then
        local last = vim.api.nvim_win_call(float, function()
          return vim.fn.line("w$")
        end)
        vim.api.nvim_win_set_config(float, { footer = footer(last), footer_pos = "right" })
        return
      end
      local a, r, h = geometry()
      if a ~= anchor or h ~= float_height then
        anchor, float_height = a, h
        vim.api.nvim_win_set_config(float, {
          relative = "win",
          win = winid,
          bufpos = { cursor - 1, 0 },
          anchor = a,
          row = r,
          col = 0,
          width = float_width,
          height = h,
          border = "rounded",
          title = " difftsigns ",
          title_pos = "left",
          footer = footer(h),
          footer_pos = "right",
        })
      end
    end,
  })

  -- Entering the float is now a legitimate destination, so leaving is judged by
  -- where we ended up, not by the source buffer being left.
  vim.api.nvim_create_autocmd({ "InsertEnter", "BufEnter", "WinEnter" }, {
    callback = function(ev)
      if not vim.api.nvim_win_is_valid(float) then
        return true
      end
      local win = vim.api.nvim_get_current_win()
      if win == float then
        return
      end
      if ev.event ~= "InsertEnter" and win == anchor_win and vim.api.nvim_get_current_buf() == bufnr then
        return
      end
      close()
      return true
    end,
  })

  return float
end

--- Test hook: the layout without opening a window.
--- @param bufnr integer
--- @param group DifftSigns.Verdict[]  -- contiguous verdict group
--- @param ref string[]|nil
function M._build(bufnr, group, ref)
  return build(bufnr, group, ref)
end

return M
