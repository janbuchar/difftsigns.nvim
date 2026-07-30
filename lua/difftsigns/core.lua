--- core.lua
---
--- The difftastic parse boundary (REDESIGN §4). ALL knowledge of difftastic's
--- JSON wire format lives here. Nothing above this file knows difft exists.
---
--- Note what this file does NOT produce: spans, regions, hunks, or any other
--- geometry. Geometry is gitsigns' job (REDESIGN §2 R2). difftastic's only
--- output here is a verdict expressed as *sets of lines that genuinely changed*,
--- plus the token ranges behind them for the preview. Demoting difftastic from
--- geometry provider to annotator is the entire point of iteration 2.
---
--- Empirically verified against Difftastic 0.69.0. Schema quirks that are easy
--- to get wrong (see REDESIGN §7):
---   * Line numbers are 0-BASED. Normalised to 1-based here, once.
---   * `unchanged` / `created` / `deleted` omit `chunks` (and `aligned_lines`)
---     entirely. Guard for absence; never assume presence.
---   * A chunk entry is `{ lhs?: Side, rhs?: Side }`; either side may be absent.
---     lhs-only means content that exists only in the reference (a deletion).
---   * A side with an EMPTY `changes` array is context, not a change. This
---     distinction is the whole plugin: it is how a reindented line is told
---     apart from an edited one.

local M = {}

--- @class DifftSigns.Edit
--- @field side      "lhs" | "rhs"
--- @field line      integer   -- 1-based line on that side
--- @field content   string    -- the changed token text
--- @field highlight string    -- difftastic's highlight class
--- @field col_start integer   -- 0-based BYTE column, inclusive
--- @field col_end   integer   -- 0-based BYTE column, exclusive

--- The complete structural verdict for one file pair.
--- @class DifftSigns.DiffResult
--- @field language        string
--- @field status          "changed"|"unchanged"|"created"|"deleted"
--- @field fallback        boolean  -- difft could not diff structurally
--- @field all_significant boolean  -- whole-file created/deleted: everything counts
--- @field changed_rhs     table<integer, true>  -- buffer-side lines that really changed
--- @field changed_lhs     table<integer, true>  -- reference-side lines that really changed
--- @field edits           DifftSigns.Edit[]

-- Languages difftastic reports when it has given up on a structural diff and
-- fallen back to a plain line diff. We must never present that as a structural
-- verdict: a line-diff fallback would mark reindented lines as changed, which is
-- precisely the noise this plugin exists to suppress. Treated as "no answer".
local FALLBACK_LANGUAGES = {
  ["Text"] = true,
  ["text"] = true,
}

--- @param n integer|nil  -- difftastic's 0-based line number
--- @return integer|nil   -- our 1-based line number
local function to_one_based(n)
  if n == nil then
    return nil
  end
  return n + 1
end

--- @return DifftSigns.DiffResult
local function empty_result(language, status)
  return {
    language = language,
    status = status,
    fallback = FALLBACK_LANGUAGES[language] == true,
    all_significant = false,
    changed_rhs = {},
    changed_lhs = {},
    edits = {},
  }
end

--- Parse one decoded difftastic file object into a DiffResult.
---
--- Pure: no Neovim API, no IO, no subprocess. Feed it `vim.json.decode(fixture)`
--- and assert on the line sets. This is deliberate — it is the cheapest possible
--- place to pin down schema behaviour.
---
--- @param decoded table
--- @return DifftSigns.DiffResult
function M.parse(decoded)
  if type(decoded) ~= "table" then
    return empty_result("unknown", "unchanged")
  end

  local status = decoded.status or "unchanged"
  local language = decoded.language or "unknown"
  local result = empty_result(language, status)

  -- `unchanged` is the most valuable answer this plugin ever receives: it means
  -- whatever the line differ found (a reformat, a rewrap, a reindent) contained
  -- no structural change at all, so EVERY marked line is noise. Verified: a
  -- prettier-style argument rewrap, trailing comma included, reports unchanged.
  if status == "unchanged" then
    return result
  end

  -- Whole-file add/remove. difft omits chunks for these, so there is no token
  -- detail to harvest and nothing to dim: it is all genuinely new or gone.
  if status == "created" or status == "deleted" then
    result.all_significant = true
    return result
  end

  local chunks = decoded.chunks
  if type(chunks) ~= "table" then
    -- Schema drift or an unexpected shape. Returning an empty verdict would
    -- claim "everything is noise" and wrongly dim real changes, so treat it as
    -- no answer instead (REDESIGN R6: place nothing, stay out of the way).
    result.fallback = true
    return result
  end

  for _, chunk in ipairs(chunks) do
    if type(chunk) == "table" then
      for _, entry in ipairs(chunk) do
        if type(entry) == "table" then
          M._harvest_entry(result, entry)
        end
      end
    end
  end

  return result
end

--- Inspect one side of a chunk entry.
---
--- The `#changes > 0` test is the load-bearing comparison of this file.
--- difftastic includes context lines inside chunks carrying an EMPTY `changes`
--- array; counting those as changed would reintroduce line-diff semantics and
--- defeat the plugin entirely.
---
--- @param sd table|nil
--- @return integer|nil line     -- 1-based line number on that side
--- @return boolean has_changes  -- true only for a genuine token change
local function side_info(sd)
  if type(sd) ~= "table" then
    return nil, false
  end
  local line = to_one_based(sd.line_number)
  if line == nil then
    return nil, false
  end
  return line, type(sd.changes) == "table" and #sd.changes > 0
end

--- @param result DifftSigns.DiffResult
--- @param side "lhs"|"rhs"
--- @param sd table|nil
--- @param line integer|nil
local function collect_edits(result, side, sd, line)
  if line == nil or type(sd) ~= "table" or type(sd.changes) ~= "table" then
    return
  end
  for _, ch in ipairs(sd.changes) do
    if type(ch) == "table" and ch.content ~= nil then
      result.edits[#result.edits + 1] = {
        side = side,
        line = line,
        content = ch.content,
        highlight = ch.highlight or "normal",
        -- difftastic's start/end are 0-based byte offsets into the line, which
        -- is exactly what nvim_buf_set_extmark wants for an inline highlight.
        col_start = ch.start or 0,
        col_end = ch["end"] or 0,
      }
    end
  end
end

--- Record one chunk entry (an aligned lhs/rhs line pair) into the result.
---
--- CROSS-ATTRIBUTION, and why it is required.
---
--- A chunk entry is difftastic's own statement that these two lines correspond.
--- Crucially, a real structural change at that position can be visible on only
--- ONE side. Removing a call argument is the canonical case:
---
---     before:  doThing(alpha, beta);      after:  doThing(alpha);
---     lhs: changes = [',', 'beta']        rhs: changes = []   (context!)
---
--- The rhs line's own difference is purely whitespace, so difftastic correctly
--- reports it as context — nothing was *added* there. Reading only the rhs side
--- therefore concludes "this buffer line did not really change" and DIMS a line
--- from which a token was genuinely deleted. That is the worst failure this
--- plugin can produce: actively hiding a real change.
---
--- So a change on either side marks the aligned line on BOTH sides. This is safe
--- because difftastic never reports whitespace as a change — a pure reindent
--- yields `status: unchanged` with no chunks at all — so the mere presence of a
--- `changes` entry always means a real token moved, appeared, or vanished.
---
--- @param result DifftSigns.DiffResult
--- @param entry table  -- { lhs?: Side, rhs?: Side }
function M._harvest_entry(result, entry)
  local lhs_line, lhs_changed = side_info(entry.lhs)
  local rhs_line, rhs_changed = side_info(entry.rhs)

  -- A real change at this aligned position, seen from either side.
  local changed_here = lhs_changed or rhs_changed

  if changed_here then
    if lhs_line ~= nil then
      result.changed_lhs[lhs_line] = true
    end
    if rhs_line ~= nil then
      result.changed_rhs[rhs_line] = true
    end
  end

  collect_edits(result, "lhs", entry.lhs, lhs_line)
  collect_edits(result, "rhs", entry.rhs, rhs_line)
end

--- @async
--- Run difftastic over two texts and return the parsed verdict.
---
--- Knows nothing about gitsigns, git, or buffers. Callers decide what the two
--- sides are.
---
--- @param old_text string[]  -- reference side (lhs)
--- @param new_text string[]  -- comparison side (rhs)
--- @param opts { lang?: string, filename?: string, difft_cmd?: string, language_overrides?: table }
--- @param callback fun(err: string|nil, result: DifftSigns.DiffResult|nil)
--- @return DifftSigns.Job|nil  -- cancellation handle, nil if spawn failed
function M.run_diff(old_text, new_text, opts, callback)
  opts = opts or {}
  local process = require("difftsigns.process")

  return process.run(old_text, new_text, opts, function(err, json_str)
    if err ~= nil then
      callback(err, nil)
      return
    end

    local ok, decoded = pcall(vim.json.decode, json_str)
    if not ok or type(decoded) ~= "table" then
      callback("difftsigns: could not decode difft JSON: " .. tostring(decoded), nil)
      return
    end

    local parse_ok, result = pcall(M.parse, decoded)
    if not parse_ok then
      callback("difftsigns: could not parse difft output: " .. tostring(result), nil)
      return
    end

    callback(nil, result)
  end)
end

return M
