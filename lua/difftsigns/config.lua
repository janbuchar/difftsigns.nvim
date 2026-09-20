--- Defaults + validation. Validation is loud: a typo'd key or wrong type fails
--- at setup() rather than later inside an async callback.

local M = {}

--- @class DifftSigns.Config
--- @field difft_cmd              string   -- path to / wrapper around difftastic
--- @field debounce_ms            integer  -- trailing debounce before re-diffing
--- @field max_filesize           integer  -- skip beyond this; difft falls back past it anyway
--- @field graph_limit            integer|nil -- difft --graph-limit; nil = difft's default
--- @field noise_hl               string   -- highlight for demoted (noise) cells
--- @field noise_text             string|nil -- glyph override; nil = mirror gitsigns'
--- @field priority_offset        integer  -- added to gitsigns' sign_priority
--- @field language_overrides     table<string,string>  -- glob:lang for difft --override
--- @field difft_version_expected string   -- pin; warn on mismatch
--- @field on_attach              fun(bufnr: integer)|nil

--- @type DifftSigns.Config
M.defaults = {
  difft_cmd = "difft",

  -- Measured with Difftastic 0.69.0: a single-token edit costs ~41 ms on a
  -- 1145-line TypeScript file and ~200-330 ms on a 6045-line one.
  debounce_ms = 400,

  -- Matches difftastic's own --byte-limit; past it difft degrades to a line
  -- diff, which we must never present as a structural verdict.
  max_filesize = 1024 * 1024,

  -- nil leaves difftastic's default (3,000,000) alone. Measured on a 708-line
  -- TypeScript file with ~50 changed lines:
  --
  --     limit        outcome                    time
  --     100,000      gave up                    0.4 s
  --     1,000,000    gave up                    2.6 s
  --     3,000,000    gave up (difft default)    7.9 s
  --     5,000,000    STRUCTURAL DIFF            7.7 s
  --
  -- Raising it buys answers on heavily-changed files; lowering it makes hopeless
  -- cases fail fast. Both are defensible, hence a knob.
  graph_limit = nil,

  noise_hl = "DifftSignsNoise",

  -- nil mirrors gitsigns' glyph per sign type, so only the colour changes and a
  -- dimmed hunk still reads as the same kind of change.
  noise_text = nil,

  -- Must outrank gitsigns (default 6) but stay below diagnostics (10+).
  priority_offset = 1,

  language_overrides = {},

  difft_version_expected = "0.70.0",

  on_attach = nil,
}

--- @type DifftSigns.Config
M.values = vim.deepcopy(M.defaults)

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
    -- A tie with gitsigns would leave the winning cell to extmark placement order.
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
