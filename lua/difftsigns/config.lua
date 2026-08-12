--- config.lua
---
--- Defaults + validation. The config is the public contract, so validation is
--- loud: a typo'd key or wrong type fails at setup() time rather than three
--- debounce ticks later inside an async callback.
---
--- Note how small this is compared with the PoC's. There are no layers, no sign
--- glyph definitions, no compare_base, and no version-pinned reference
--- resolution — because geometry, base, and glyphs are all borrowed from
--- gitsigns now (REDESIGN §4). A shrinking config surface is the clearest
--- evidence the redesign moved responsibility to the right place.

local M = {}

--- @class DifftSigns.Config
--- @field difft_cmd              string   -- path to / wrapper around difftastic
--- @field debounce_ms            integer  -- trailing debounce before re-diffing
--- @field max_filesize           integer  -- skip beyond this; difft falls back past it anyway
--- @field graph_limit            integer|nil -- difft --graph-limit; nil = difft's default
--- @field noise_hl               string   -- highlight for demoted (noise) cells
--- @field noise_text             string|nil -- glyph override; nil = mirror gitsigns'
--- @field priority_offset        integer  -- added to gitsigns' sign_priority
--- @field preview_context        integer  -- context lines around each change in the preview
--- @field language_overrides     table<string,string>  -- glob:lang for difft --override
--- @field difft_version_expected string   -- pin; warn on mismatch
--- @field on_attach              fun(bufnr: integer)|nil

--- @type DifftSigns.Config
M.defaults = {
  difft_cmd = "difft",

  -- DERIVED, not asserted. Measured with Difftastic 0.69.0: a realistic
  -- single-token edit costs ~41 ms on a 1145-line TypeScript file and
  -- ~200-330 ms on a 6045-line one. 400 ms keeps the common case imperceptible
  -- while leaving even a large-file worst case settled well inside a second of
  -- pausing. The PoC's 1500 ms default was ~4x more pessimistic than reality.
  debounce_ms = 400,

  -- Matches difftastic's own --byte-limit. Past it difft silently degrades to a
  -- line diff, which we must never present as a structural verdict, so we stop
  -- asking rather than mislabel the answer.
  max_filesize = 1024 * 1024,

  -- Passed to difftastic as --graph-limit. nil leaves difftastic's own default
  -- (3,000,000) alone.
  --
  -- This is the knob for "why does the plugin do nothing on this file". difftastic
  -- abandons the structural diff when its internal graph exceeds this many
  -- vertices and returns a line diff, which we refuse to render. Measured on a
  -- 708-line TypeScript test file with ~50 changed lines:
  --
  --     limit        outcome                    time
  --     100,000      gave up                    0.4 s
  --     1,000,000    gave up                    2.6 s
  --     3,000,000    gave up (difft default)    7.9 s
  --     5,000,000    STRUCTURAL DIFF            7.7 s
  --
  -- Note the shape of that table: at the default, difftastic spends eight seconds
  -- and then tells you nothing. Raising the limit buys real answers on
  -- heavily-changed files at no extra cost over failing slowly; LOWERING it makes
  -- hopeless cases fail fast and cheap. Both are defensible, which is why this is
  -- a knob and not a decision baked in on your behalf.
  graph_limit = nil,

  -- The entire visual design of the plugin is this one highlight group.
  noise_hl = "DifftSignsNoise",

  -- nil means "mirror gitsigns' own glyph for that sign type", so only the
  -- colour of the cell changes and a dimmed hunk still reads as the same KIND of
  -- change. Set a string to use one distinct glyph for all noise instead.
  noise_text = nil,

  -- We must outrank gitsigns to win the shared cell, but stay below diagnostics
  -- (conventionally 10+). gitsigns defaults to 6, so +1 lands at 7.
  priority_offset = 1,

  preview_context = 2,

  language_overrides = {},

  -- difftastic's JSON is explicitly unstable; the only honest way to cope is to
  -- fail loudly rather than silently mis-parse.
  difft_version_expected = "0.70.0",

  on_attach = nil,
}

--- @type DifftSigns.Config
M.values = vim.deepcopy(M.defaults)

--- Validate a merged config. Uses the modern per-field vim.validate signature.
--- @param cfg table
--- @return boolean ok
--- @return string|nil err
local function validate(cfg)
  local ok, err = pcall(function()
    vim.validate("difft_cmd", cfg.difft_cmd, "string")
    vim.validate("debounce_ms", cfg.debounce_ms, "number")
    vim.validate("max_filesize", cfg.max_filesize, "number")
    vim.validate("graph_limit", cfg.graph_limit, "number", true)
    vim.validate("noise_hl", cfg.noise_hl, "string")
    vim.validate("noise_text", cfg.noise_text, "string", true)
    vim.validate("priority_offset", cfg.priority_offset, "number")
    vim.validate("preview_context", cfg.preview_context, "number")
    vim.validate("language_overrides", cfg.language_overrides, "table")
    vim.validate("difft_version_expected", cfg.difft_version_expected, "string")
    vim.validate("on_attach", cfg.on_attach, "function", true)

    if cfg.debounce_ms < 0 then
      error("debounce_ms must be >= 0")
    end
    if cfg.max_filesize < 0 then
      error("max_filesize must be >= 0")
    end
    if cfg.graph_limit ~= nil and cfg.graph_limit < 1 then
      error("graph_limit must be >= 1")
    end
    if cfg.preview_context < 0 then
      error("preview_context must be >= 0")
    end
    -- A non-positive offset would tie or lose against gitsigns, and extmark
    -- tie-breaking is not something to leave to chance: the overlay would
    -- appear or not depending on placement order.
    if cfg.priority_offset < 1 then
      error("priority_offset must be >= 1 so the overlay outranks gitsigns")
    end

    for glob, lang in pairs(cfg.language_overrides) do
      if type(glob) ~= "string" or type(lang) ~= "string" then
        error("language_overrides must map string globs to string languages")
      end
    end
  end)

  if not ok then
    return false, "difftsigns: invalid config: " .. tostring(err)
  end
  return true, nil
end

--- Reject unknown keys outright. A silently-ignored typo in a config table is
--- among the most annoying bugs a plugin can inflict.
--- @param opts table
--- @return boolean ok
--- @return string|nil err
local function check_unknown(opts)
  for k in pairs(opts) do
    local nil_defaults = { noise_text = true, on_attach = true, graph_limit = true }
    if M.defaults[k] == nil and not nil_defaults[k] then
      local known = vim.tbl_keys(M.defaults)
      table.sort(known)
      return false,
        ("difftsigns: unknown config key '%s' (known: %s)"):format(k, table.concat(known, ", "))
    end
  end
  return true, nil
end

--- Merge user opts over defaults, validate, store.
--- @param opts table|nil
--- @return boolean ok
--- @return string|nil err
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    return false, "difftsigns: setup() expects a table"
  end

  local ok, err = check_unknown(opts)
  if not ok then
    return false, err
  end

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

  ok, err = validate(merged)
  if not ok then
    return false, err
  end

  M.values = merged
  return true, nil
end

return M
