--- signs.lua
---
--- The two-layer gutter (spec §6). Speaks ONLY the internal Region type; has no
--- idea difftastic or git exist.
---
--- Two separate namespaces so each layer toggles/recolors/clears independently:
---   * ns_change (layer 1): one sign per genuinely-changed buffer line, plus a
---     topdelete-style cap for deletions. Higher priority.
---   * ns_span   (layer 2): a subdued sign on EVERY line of a chunk span,
---     including unchanged context lines. Lower priority, so where the layers
---     collide the changed-line marker wins the cell.
---
--- Signs are placed as REAL (non-ephemeral) extmarks in M.render. The spec (§6)
--- originally proposed ephemeral placement from a decoration provider's on_line
--- to avoid marking off-screen lines, but ephemeral extmarks silently do not
--- render `sign_text` (the gutter sign type is unsupported ephemerally), so that
--- approach placed nothing. We place real extmarks for exactly the changed /
--- span / deletion lines instead — a small, bounded count (never the whole
--- file), so it stays cheap even on large buffers.

local config = require("dft-signs.config")

local M = {}

M.ns_change = vim.api.nvim_create_namespace("dft_signs_change")
M.ns_span = vim.api.nvim_create_namespace("dft_signs_span")

-- Per-buffer state. Keyed by bufnr.
--- @class DftSigns.BufState
--- @field regions DftSigns.Region[]
--- @field span_by_line table<integer, DftSigns.Region>  -- buffer line -> owning region (layer 2 lookup)
--- @field changed_by_line table<integer, boolean>       -- buffer line -> is genuinely changed (layer 1)
--- @field deletion_by_line table<integer, integer>      -- anchor line -> deletion count
--- @field show_spans boolean
--- @field show_changes boolean
local state = {}

-- Priorities: layer 1 must win the cell over layer 2 (spec §6).
local PRIORITY_SPAN = 8
local PRIORITY_CHANGE = 20

--- Highlight group setup, linking to sensible diff defaults so the plugin looks
--- reasonable with zero theme support, while staying overridable.
function M.setup_highlights()
  local function ensure(name, link)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
  end
  ensure("DftSignsChange", "DiffChange")
  ensure("DftSignsSpan", "Comment")
  ensure("DftSignsDelete", "DiffDelete")
end

--- Build the per-line lookup tables from a region list. Doing this once on
--- update keeps the hot on_line callback O(1) per line instead of scanning
--- every region on every redraw.
--- @param bufnr integer
--- @param regions DftSigns.Region[]
local function index_regions(bufnr, regions)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local span_by_line = {}
  local changed_by_line = {}
  local deletion_by_line = {}

  for _, region in ipairs(regions) do
    local from = region.span.from
    local to = region.span.to
    if to == -1 then -- created-file sentinel: whole buffer
      to = line_count
    end
    for line = from, to do
      span_by_line[line] = region
    end
    for _, line in ipairs(region.changed) do
      changed_by_line[line] = true
    end
    for _, d in ipairs(region.deletions) do
      -- count -1 is the whole-file-deleted sentinel; treat as a single cap.
      deletion_by_line[d.anchor] = (deletion_by_line[d.anchor] or 0) + (d.count < 0 and 1 or d.count)
    end
  end

  local st = state[bufnr] or {}
  st.regions = regions
  st.span_by_line = span_by_line
  st.changed_by_line = changed_by_line
  st.deletion_by_line = deletion_by_line
  if st.show_spans == nil then
    st.show_spans = config.values.layers.span.enable
  end
  if st.show_changes == nil then
    st.show_changes = config.values.layers.changed.enable
  end
  state[bufnr] = st
end

--- Replace the regions for a buffer and trigger a redraw so the decoration
--- provider re-emits. This is the only entry point adapters use.
---
--- `ref_lines` is the reference (lhs) text as an array of lines. It is retained
--- purely so the span preview can show the ACTUAL reference source lines (not
--- difft's context-free tokens). Optional; when omitted the preview shows only
--- the buffer side.
--- @param bufnr integer
--- @param regions DftSigns.Region[]
--- @param ref_lines string[]|nil
function M.set_regions(bufnr, regions, ref_lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  index_regions(bufnr, regions or {})
  state[bufnr].ref_lines = ref_lines
  M.render(bufnr)
end

--- Place the actual gutter signs for a buffer as REAL (non-ephemeral) extmarks.
---
--- NB: signs must be placed with real extmarks. Ephemeral extmarks (as emitted
--- from a decoration provider's on_line) silently do NOT render `sign_text` —
--- the gutter sign type isn't supported ephemerally, so nothing appears even
--- though the call succeeds. (This bit us: the earlier decoration-provider
--- approach placed ephemeral signs that never drew.) We therefore place real
--- extmarks for the changed/span/deletion lines directly. The counts are small
--- (only changed lines + chunk-span lines, never the whole file), so this is
--- cheap even on large files.
--- @param bufnr integer
function M.render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local st = state[bufnr]
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_change, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_span, 0, -1)
  if st == nil then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  --- Clamp a 1-based line to a valid 0-based extmark row.
  local function row_of(line)
    if line < 1 then
      return nil
    end
    if line > line_count then
      return nil
    end
    return line - 1
  end

  -- Layer 2 (spans): a subdued sign on every line of each chunk span, context
  -- included. Lower priority so layer 1 wins shared cells.
  if st.show_spans then
    local layer = config.values.layers.span
    for line in pairs(st.span_by_line) do
      local row = row_of(line)
      if row ~= nil then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_span, row, 0, {
          sign_text = layer.text,
          sign_hl_group = layer.hl,
          priority = PRIORITY_SPAN,
        })
      end
    end
  end

  -- Layer 1 (changed lines) + deletion caps, higher priority.
  if st.show_changes then
    local layer = config.values.layers.changed
    for line in pairs(st.changed_by_line) do
      local row = row_of(line)
      if row ~= nil then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_change, row, 0, {
          sign_text = layer.text,
          sign_hl_group = layer.hl,
          priority = PRIORITY_CHANGE,
        })
      end
    end
    for line in pairs(st.deletion_by_line) do
      local row = row_of(line)
      if row ~= nil then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_change, row, 0, {
          sign_text = "‾",
          sign_hl_group = "DftSignsDelete",
          priority = PRIORITY_CHANGE + 1,
        })
      end
    end
  end
end

--- Clear all signs for a buffer (spec §5: unchanged / skipped / oversized).
--- @param bufnr integer
function M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_change, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_span, 0, -1)
  if state[bufnr] then
    state[bufnr].regions = {}
    state[bufnr].span_by_line = {}
    state[bufnr].changed_by_line = {}
    state[bufnr].deletion_by_line = {}
  end
end

--- Forget a buffer entirely (on detach/wipe).
--- @param bufnr integer
function M.forget(bufnr)
  state[bufnr] = nil
end

--- Toggle layer 2 (spans) for a buffer.
--- @param bufnr integer
function M.toggle_spans(bufnr)
  local st = state[bufnr]
  if st == nil then
    return
  end
  st.show_spans = not st.show_spans
  M.render(bufnr)
end

--- Toggle layer 1 (changed-line markers) for a buffer.
--- @param bufnr integer
function M.toggle_changes(bufnr)
  local st = state[bufnr]
  if st == nil then
    return
  end
  st.show_changes = not st.show_changes
  M.render(bufnr)
end

--- Return the region whose span contains a given buffer line (or nil).
--- @param bufnr integer
--- @param line integer  -- 1-based
--- @return DftSigns.Region|nil
function M.region_at(bufnr, line)
  local st = state[bufnr]
  if st == nil then
    return nil
  end
  return st.span_by_line[line]
end

--- Fetch the source line for a given side/line-number.
--- rhs => the live buffer; lhs => the retained reference text.
--- @param bufnr integer
--- @param st table
--- @param side "lhs"|"rhs"
--- @param lnum integer  -- 1-based
--- @return string|nil
local function source_line(bufnr, st, side, lnum)
  if side == "rhs" then
    local ls = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    return ls[1]
  end
  local ref = st.ref_lines
  if ref == nil then
    return nil
  end
  return ref[lnum]
end

--- Preview the structural changes of the SPAN under the cursor.
---
--- There is no honest "line hunk" to show for a structural chunk (§2/§9), and
--- difft's raw tokens in isolation are useless (a reorder shows the *same* token
--- on both sides with no context). So instead we show the ACTUAL source lines
--- from each side — reference (was) and buffer (now) — with the changed tokens
--- highlighted in place. That is what makes a reorder or an in-line edit
--- legible. Falls back to a notice when the cursor isn't inside a span.
--- @param bufnr integer
--- @param winid integer|nil  -- window whose cursor to read (default current)
function M.preview_span(bufnr, winid)
  winid = winid or vim.api.nvim_get_current_win()
  local st = state[bufnr]
  if st == nil then
    vim.notify("dft-signs: no structural diff for this buffer", vim.log.levels.INFO)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
  local region = st.span_by_line[cursor_line]
  if region == nil then
    vim.notify("dft-signs: cursor is not inside a changed span", vim.log.levels.INFO)
    return
  end

  -- Build the float contents. Header describes the span; body shows real lines.
  local lines = {}
  local highlights = {} -- { line_idx (0-based), hl_group, col_start, col_end }

  local span_to = region.span.to == -1 and vim.api.nvim_buf_line_count(bufnr) or region.span.to
  table.insert(lines, ("Structural change  [%s]  lines %d-%d")
    :format(region.kind, region.span.from, span_to))
  table.insert(highlights, { #lines - 1, "Title", 0, -1 })

  if #region.deletions > 0 then
    local total = 0
    for _, d in ipairs(region.deletions) do
      total = total + (d.count < 0 and 1 or d.count)
    end
    table.insert(lines, ("  %d deleted reference line(s)"):format(total))
    table.insert(highlights, { #lines - 1, "DiffDelete", 0, -1 })
  end

  if #region.edits == 0 then
    table.insert(lines, "  (whole-file add/delete; no token detail)")
  else
    -- Group edits by side then line so we can render each source line once and
    -- highlight every changed token on it.
    -- by_side[side][lnum] = list of edits (each with col_start/col_end/highlight)
    local by_side = { lhs = {}, rhs = {} }
    for _, e in ipairs(region.edits) do
      by_side[e.side][e.line] = by_side[e.side][e.line] or {}
      table.insert(by_side[e.side][e.line], e)
    end

    local ctx = config.values.preview_context or 0

    local labels = { { "lhs", "reference (was)", "DiffDelete" }, { "rhs", "buffer (now)", "DiffAdd" } }
    for _, entry in ipairs(labels) do
      local side, label, label_hl = entry[1], entry[2], entry[3]
      local changed_nums = vim.tbl_keys(by_side[side])
      table.sort(changed_nums)
      if #changed_nums > 0 then
        table.insert(lines, label .. ":")
        table.insert(highlights, { #lines - 1, label_hl, 0, -1 })

        -- Expand each changed line by ±ctx and merge into contiguous ranges, so
        -- a reorder shows the lines it swapped with rather than a lone line.
        local ranges = {}
        for _, lnum in ipairs(changed_nums) do
          local from = math.max(1, lnum - ctx)
          local to = lnum + ctx
          local last = ranges[#ranges]
          if last ~= nil and from <= last.to + 1 then
            last.to = math.max(last.to, to)
          else
            table.insert(ranges, { from = from, to = to })
          end
        end

        local prev_to = nil
        for _, range in ipairs(ranges) do
          -- Visually separate non-adjacent ranges with an ellipsis row.
          if prev_to ~= nil then
            table.insert(lines, "  ⋯")
            table.insert(highlights, { #lines - 1, "NonText", 0, -1 })
          end
          for lnum = range.from, range.to do
            local src = source_line(bufnr, st, side, lnum)
            if src ~= nil then
              local is_changed = by_side[side][lnum] ~= nil
              -- Mark changed lines with '>' and context lines with a space.
              local prefix = ("%s %d: "):format(is_changed and ">" or " ", lnum)
              local row = #lines -- 0-based index of the line we're adding
              table.insert(lines, prefix .. src)
              local off = #prefix
              if is_changed then
                for _, e in ipairs(by_side[side][lnum]) do
                  -- Highlight the CHANGED token with DiffText so it pops.
                  table.insert(highlights, { row, "DiffText", off + e.col_start, off + e.col_end })
                end
              else
                -- Dim the context lines so the eye lands on the change.
                table.insert(highlights, { row, "Comment", 0, -1 })
              end
            end
          end
          prev_to = range.to
        end
      end
    end
  end

  -- Render into a scratch buffer shown as a float near the cursor.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, h[2], h[1], h[3], h[4])
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end

  local float_win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width + 2, math.floor(vim.o.columns * 0.8)),
    height = math.min(#lines, 20),
    style = "minimal",
    border = "rounded",
    title = " dft-signs ",
    title_pos = "left",
  })

  -- Dismiss on the next cursor move / mode change, like gitsigns' preview.
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
    end,
  })
end

--- Retained for API compatibility with init.lua's setup(). Signs are now placed
--- as real extmarks in M.render (see the note there on why ephemeral signs from
--- a decoration provider don't render), so there is no decoration provider to
--- install. This is intentionally a no-op.
function M.install_provider()
  M._provider_installed = true
end

--- Expose state for tests.
--- @param bufnr integer
--- @return DftSigns.BufState|nil
function M._state(bufnr)
  return state[bufnr]
end

return M
