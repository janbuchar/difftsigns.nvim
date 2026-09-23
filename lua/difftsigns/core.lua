--- The difftastic parse boundary. All knowledge of difftastic's JSON lives here;
--- nothing above this file knows difft exists.
---
--- Produces no geometry (that is gitsigns' job), only the sets of lines that
--- genuinely changed plus the token ranges behind them for the preview.
---
--- Verified against every version in `config.defaults.difft_versions`. Schema quirks:
---   * Line numbers are 0-BASED. Normalised to 1-based here, once.
---   * `unchanged` / `created` / `deleted` omit `chunks` entirely.
---   * A chunk entry is `{ lhs?: Side, rhs?: Side }`; either side may be absent.
---   * A side with an EMPTY `changes` array is context, not a change. This is
---     how a reindented line is told apart from an edited one.

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
--- @field fallback_reason string|nil -- why, in words, for the status line
--- @field all_significant boolean  -- whole-file created/deleted: everything counts
--- @field changed_rhs     table<integer, true>  -- buffer-side lines that really changed
--- @field changed_lhs     table<integer, true>  -- reference-side lines that really changed
--- @field edits           DifftSigns.Edit[]

--- Has difftastic given up on structural diffing and returned a line diff?
---
--- Signalled through `language`, but not with one fixed string. Known forms:
---
---   "Text"                             -- no tree-sitter parser for this type
---   "Text (exceeded DFT_GRAPH_LIMIT)"
---   "Text (13 B exceeded DFT_BYTE_LIMIT)"
---   "Text (4 JavaScript parse errors, exceeded DFT_PARSE_ERROR_LIMIT, first at 3:0)"
---
--- The parenthesised part is prose and has already grown between versions, so
--- match on the "exceeded DFT_*" substring, never the whole string.
---
--- @param language string|nil
--- @return boolean fallback
--- @return string|nil reason  -- human-readable, for the status line
local function classify_language(language)
  if type(language) ~= "string" or language == "" then
    return true, "difftastic reported no language"
  end
  if language:lower():find("exceeded dft_graph_limit", 1, true) then
    return true, "difftastic hit its graph limit (raise graph_limit to diff this file)"
  end
  if language:lower():find("exceeded dft_byte_limit", 1, true) then
    return true, "difftastic hit its byte limit (file too large)"
  end
  -- Usually the buffer's fault (mid-edit code does not parse), so say where.
  if language:lower():find("exceeded dft_parse_error_limit", 1, true) then
    local at = language:match("first at ([%d:]+)")
    if at ~= nil then
      return true, ("difftastic could not parse this file (syntax error at %s)"):format(at)
    end
    return true, "difftastic could not parse this file"
  end
  if language:lower():find("exceeded", 1, true) then
    return true, "difftastic gave up: " .. language
  end
  if language == "Text" or language == "text" or language:match("^[Tt]ext%s*%(") then
    return true, "no structural parser for this file type"
  end
  return false, nil
end

--- @return DifftSigns.DiffResult
local function empty_result(language, status)
  local fallback, reason = classify_language(language)
  return {
    language = language,
    status = status,
    fallback = fallback,
    fallback_reason = reason,
    all_significant = false,
    changed_rhs = {},
    changed_lhs = {},
    edits = {},
  }
end

--- Highlight classes whose atoms difftastic word-diffs INTERNALLY: rewording a
--- comment or string reports its inter-word spaces as changed tokens, so
--- whitespace in one of these is genuine structural output. Verified on 0.70.0.
local WORD_DIFFED_ATOMS = { comment = true, string = true }

--- Parse one decoded difftastic file object into a DiffResult. Pure: feed it
--- `vim.json.decode(fixture)`.
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

  -- `unchanged` means every line the line differ marked is noise. Verified: a
  -- prettier-style rewrap, trailing comma included, reports unchanged.
  if status == "unchanged" then
    return result
  end

  -- difft omits chunks for these, so there is no token detail and nothing to dim.
  if status == "created" or status == "deleted" then
    result.all_significant = true
    return result
  end

  local chunks = decoded.chunks
  if type(chunks) ~= "table" then
    -- An empty verdict would claim "everything is noise" and dim real changes;
    -- schema drift must read as no answer instead.
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

  -- Safety net independent of the unstable `language` string: a line-diff
  -- fallback marks every token on the line, spaces included, all `normal`.
  -- Whitespace inside a word-diffed atom is not that (see WORD_DIFFED_ATOMS).
  if not result.fallback then
    for _, e in ipairs(result.edits) do
      if e.content:match("^%s+$") ~= nil and not WORD_DIFFED_ATOMS[e.highlight] then
        result.fallback = true
        result.fallback_reason =
          "difftastic returned a line diff, not a structural one (whitespace reported as changed)"
        break
      end
    end
  end

  return result
end

--- Inspect one side of a chunk entry. `#changes > 0` is the load-bearing test:
--- context lines appear inside chunks with an EMPTY `changes` array.
---
--- @param sd table|nil
--- @return integer|nil line     -- 1-based line number on that side
--- @return boolean has_changes  -- true only for a genuine token change
local function side_info(sd)
  if type(sd) ~= "table" then
    return nil, false
  end
  if sd.line_number == nil then
    return nil, false
  end
  local line = sd.line_number + 1 -- difftastic is 0-based
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
        -- 0-based byte offsets, which is what nvim_buf_set_extmark wants.
        col_start = ch.start or 0,
        col_end = ch["end"] or 0,
      }
    end
  end
end

--- Record one chunk entry (an aligned lhs/rhs line pair) into the result.
---
--- A change on EITHER side marks the aligned line on BOTH sides. A real change
--- can be visible on only one side — removing a call argument:
---
---     before:  doThing(alpha, beta);      after:  doThing(alpha);
---     lhs: changes = [',', 'beta']        rhs: changes = []   (context!)
---
--- Reading only the rhs would dim a line from which a token was genuinely
--- deleted. Cross-attribution is safe because difftastic never reports
--- whitespace as a change (a pure reindent yields `status: unchanged`), so any
--- `changes` entry means a real token moved, appeared, or vanished.
---
--- @param result DifftSigns.DiffResult
--- @param entry table  -- { lhs?: Side, rhs?: Side }
function M._harvest_entry(result, entry)
  local lhs_line, lhs_changed = side_info(entry.lhs)
  local rhs_line, rhs_changed = side_info(entry.rhs)

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
