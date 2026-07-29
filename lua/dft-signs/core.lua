--- core.lua
---
--- The single parse boundary (spec §3). ALL knowledge of difftastic's JSON wire
--- format lives here. Everything above this file speaks only the internal
--- `DftSigns.Region` type. When the upstream schema shifts, this file — and only
--- this file — changes.
---
--- Empirically verified against Difftastic 0.69.0. Note the schema quirks that
--- the spec text got wrong or omitted:
---   * Line numbers in the JSON are 0-BASED (spec claimed 1-based). We normalize
---     everything to 1-based at the boundary so the rest of the plugin never has
---     to think about it.
---   * `unchanged` / `created` / `deleted` statuses omit `aligned_lines` AND
---     `chunks` entirely. Guard for absence, do not assume presence.
---   * A "Line" inside a chunk is `{ lhs?: Side, rhs?: Side }` where a side may
---     be absent. rhs-only => addition/change on buffer side; lhs-only =>
---     deletion (no buffer line of its own).

local M = {}

--- @class DftSigns.Region
--- @field span       { from: integer, to: integer }  -- buffer (rhs) line range, 1-based inclusive
--- @field changed    integer[]              -- buffer lines with real changes (layer 1), 1-based
--- @field deletions  DftSigns.Deletion[]    -- lhs-only lines, anchored to a buffer line
--- @field edits      DftSigns.Edit[]        -- token-level changes in this span (for span preview)
--- @field kind       "add" | "change" | "delete"

--- @class DftSigns.Deletion
--- @field anchor integer   -- buffer line the deleted ref lines sit above/below (1-based)
--- @field count  integer

--- A single token-level change reported by difftastic. Unlike a line hunk, this
--- is the *actual* structural granularity: which side changed, on which line,
--- and the exact token content. Kept so the span preview can show what really
--- changed instead of faking a line block (there is no honest line block for a
--- structural chunk — see §2/§9).
--- @class DftSigns.Edit
--- @field side      "lhs" | "rhs"  -- reference side or buffer side
--- @field line      integer        -- 1-based line on that side
--- @field content   string         -- the changed token text
--- @field highlight string         -- difft's highlight class (keyword/string/normal/...)
--- @field col_start integer        -- 0-based BYTE column of the token start (for in-line highlight)
--- @field col_end   integer        -- 0-based BYTE column of the token end (exclusive)

--- @class DftSigns.Side
--- @field line_number integer
--- @field changes table[]

--- @class DftSigns.DiffResult
--- @field language string
--- @field status "changed" | "unchanged" | "created" | "deleted"
--- @field regions DftSigns.Region[]
--- @field fallback boolean  -- true when difft could not diff structurally (line-diff fallback)

-- difft reports these languages when it has fallen back to a plain line diff
-- rather than a structural (tree-sitter) diff. The spec (§9.4) wants us to be
-- able to badge/suppress these so the user knows they aren't getting the real
-- thing.
local FALLBACK_LANGUAGES = {
  ["Text"] = true,
  ["text"] = true,
}

--- Convert difft's 0-based line number to our 1-based convention.
--- @param n integer|nil
--- @return integer|nil
local function to_one_based(n)
  if n == nil then
    return nil
  end
  return n + 1
end

--- Parse a single decoded difftastic JSON object into a DiffResult.
---
--- This is separated from `run_diff` so it is unit-testable with zero Neovim and
--- zero subprocess involvement — feed it `vim.json.decode(fixture)` and assert
--- on the Regions. This is the §11 build-order priority: nail the parser first.
---
--- @param decoded table  -- result of vim.json.decode on one difft file object
--- @return DftSigns.DiffResult
function M.parse(decoded)
  local status = decoded.status or "unchanged"
  local language = decoded.language or "unknown"

  local result = {
    language = language,
    status = status,
    regions = {},
    fallback = FALLBACK_LANGUAGES[language] == true,
  }

  -- Short-circuit paths (spec §3): these statuses carry no chunk data at all.
  if status == "unchanged" then
    return result
  end

  if status == "created" then
    -- Whole file is new. We cannot know the line count from the JSON alone
    -- (difft omits chunks for created), so we emit a sentinel add-region that
    -- the caller resolves against the actual buffer length. from=1, to=-1 means
    -- "to end of buffer".
    result.regions = {
      {
        span = { from = 1, to = -1 },
        changed = {},
        deletions = {},
        edits = {},
        kind = "add",
      },
    }
    return result
  end

  if status == "deleted" then
    -- Whole file removed. Nothing to mark on the (empty) buffer side beyond a
    -- single deletion cap anchored at line 1.
    result.regions = {
      {
        span = { from = 1, to = 1 },
        changed = {},
        deletions = { { anchor = 1, count = -1 } },
        edits = {},
        kind = "delete",
      },
    }
    return result
  end

  -- status == "changed": walk chunks.
  local chunks = decoded.chunks
  if type(chunks) ~= "table" then
    -- Defensive: schema drift or unexpected shape. Emit nothing rather than
    -- crash the whole update loop.
    return result
  end

  for _, chunk in ipairs(chunks) do
    local region = M._parse_chunk(chunk)
    if region ~= nil then
      table.insert(result.regions, region)
    end
  end

  return result
end

--- Parse one chunk (a list of Line objects) into a single Region.
--- @param chunk table[]
--- @return DftSigns.Region|nil
function M._parse_chunk(chunk)
  if type(chunk) ~= "table" or #chunk == 0 then
    return nil
  end

  local changed = {}
  local deletions = {}
  local edits = {}
  local span_from, span_to = nil, nil

  --- Harvest token-level changes from one side into `edits`.
  --- @param side "lhs"|"rhs"
  --- @param sd table|nil  -- a Side object
  local function harvest(side, sd)
    if sd == nil or type(sd.changes) ~= "table" then
      return
    end
    local line = to_one_based(sd.line_number) or 1
    for _, ch in ipairs(sd.changes) do
      if type(ch) == "table" and ch.content ~= nil then
        table.insert(edits, {
          side = side,
          line = line,
          content = ch.content,
          highlight = ch.highlight or "normal",
          -- difft's start/end are 0-based byte offsets into the line — exactly
          -- what nvim_buf_add_highlight wants, so keep them for in-line marking.
          col_start = ch.start or 0,
          col_end = ch["end"] or 0,
        })
      end
    end
  end

  -- Track consecutive lhs-only runs so a block of deleted lines collapses into
  -- one Deletion with a count, anchored to the nearest following buffer line
  -- (or the last seen buffer line if the deletion trails the chunk).
  local pending_del_count = 0
  local last_rhs_line = nil

  --- @param line integer  -- 1-based buffer line
  local function extend_span(line)
    if span_from == nil or line < span_from then
      span_from = line
    end
    if span_to == nil or line > span_to then
      span_to = line
    end
  end

  local function flush_deletions(anchor)
    if pending_del_count > 0 then
      table.insert(deletions, { anchor = anchor, count = pending_del_count })
      pending_del_count = 0
    end
  end

  for _, entry in ipairs(chunk) do
    local rhs = entry.rhs
    local lhs = entry.lhs

    -- Harvest token changes from both sides for the span preview. This does not
    -- affect the layer-1/deletion bookkeeping below; it just retains detail we
    -- would otherwise throw away.
    harvest("lhs", lhs)
    harvest("rhs", rhs)

    if rhs ~= nil and rhs.line_number ~= nil then
      local buf_line = to_one_based(rhs.line_number)
      last_rhs_line = buf_line
      extend_span(buf_line)

      -- A pending deletion block sits directly *above* this buffer line.
      flush_deletions(buf_line)

      -- rhs.changes non-empty => this buffer line genuinely changed (layer 1).
      if type(rhs.changes) == "table" and #rhs.changes > 0 then
        table.insert(changed, buf_line)
      end
    elseif lhs ~= nil and lhs.line_number ~= nil and rhs == nil then
      -- lhs-only line: a deletion with no buffer line of its own.
      pending_del_count = pending_del_count + 1
    end
  end

  -- Any deletions trailing the chunk anchor to the last buffer line we saw, or
  -- line 1 if the chunk was pure-deletion with no rhs at all.
  if pending_del_count > 0 then
    flush_deletions(last_rhs_line or 1)
  end

  -- A chunk with no rhs lines at all is a pure deletion region. Give it a span
  -- at the anchor so layer 2 still has something to mark.
  if span_from == nil then
    local anchor = 1
    if #deletions > 0 then
      anchor = deletions[1].anchor
    end
    span_from, span_to = anchor, anchor
  end

  local kind
  if #changed == 0 and #deletions > 0 then
    kind = "delete"
  elseif #deletions > 0 and #changed > 0 then
    kind = "change"
  else
    kind = "change"
  end

  return {
    span = { from = span_from, to = span_to },
    changed = changed,
    deletions = deletions,
    edits = edits,
    kind = kind,
  }
end

--- @async
--- Run a structural diff of two texts and return the parsed DiffResult.
---
--- Knows nothing about git, buffers, or octo (spec §7). Callers (adapters)
--- decide what `old_text` and `new_text` are.
---
--- @param old_text string[]   -- reference side (lhs)
--- @param new_text string[]   -- comparison side (rhs)
--- @param opts { lang?: string, filename?: string }
--- @param callback fun(err: string|nil, result: DftSigns.DiffResult|nil)
function M.run_diff(old_text, new_text, opts, callback)
  opts = opts or {}
  local process = require("dft-signs.process")

  process.run(old_text, new_text, opts, function(err, json_str)
    if err ~= nil then
      callback(err, nil)
      return
    end

    local ok, decoded = pcall(vim.json.decode, json_str)
    if not ok or type(decoded) ~= "table" then
      callback("dft-signs: failed to decode difft JSON: " .. tostring(decoded), nil)
      return
    end

    local parse_ok, result = pcall(M.parse, decoded)
    if not parse_ok then
      callback("dft-signs: failed to parse difft output: " .. tostring(result), nil)
      return
    end

    callback(nil, result)
  end)
end

return M
