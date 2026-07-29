--- config.lua
---
--- Defaults + validation, in the gitsigns/mini.diff style (spec §8). The config
--- is the public contract, so validation is loud: a typo'd key or wrong type
--- fails at setup() time, not three debounce ticks later inside a decoration
--- provider callback where it is undebuggable.

local M = {}

--- @class DftSigns.LayerConfig
--- @field enable boolean
--- @field text string
--- @field hl string

--- @class DftSigns.Config
--- @field difft_cmd string
--- @field debounce_ms integer
--- @field max_filesize integer
--- @field compare_base string
--- @field layers { changed: DftSigns.LayerConfig, span: DftSigns.LayerConfig }
--- @field language_overrides table<string,string>
--- @field difft_version_expected string
--- @field preview_context integer
--- @field on_attach fun(bufnr: integer)|nil

--- @type DftSigns.Config
M.defaults = {
  difft_cmd = "difft",
  debounce_ms = 1500, -- large by design (spec §5)
  max_filesize = 1024 * 1024, -- match difft's --byte-limit; skip beyond (spec §5)
  compare_base = "index", -- 'index'|'HEAD'|'save'|<revision>
  layers = {
    changed = { enable = true, text = "▌", hl = "DftSignsChange" },
    span = { enable = true, text = "▏", hl = "DftSignsSpan" },
  },
  language_overrides = {},
  difft_version_expected = "0.69.0", -- pin; warn on mismatch (spec §3)
  preview_context = 2, -- unchanged lines shown around each change in the span preview
  on_attach = nil,
}

--- @type DftSigns.Config
M.values = vim.deepcopy(M.defaults)

--- Validate a candidate config table. Returns (ok, err). Uses vim.validate for
--- type checks so error messages match Neovim's own conventions.
--- @param cfg table
--- @return boolean ok
--- @return string|nil err
local function validate(cfg)
  local ok, err = pcall(function()
    vim.validate({
      difft_cmd = { cfg.difft_cmd, "string" },
      debounce_ms = { cfg.debounce_ms, "number" },
      max_filesize = { cfg.max_filesize, "number" },
      compare_base = { cfg.compare_base, "string" },
      preview_context = { cfg.preview_context, "number" },
      layers = { cfg.layers, "table" },
      language_overrides = { cfg.language_overrides, "table" },
      difft_version_expected = { cfg.difft_version_expected, "string" },
      on_attach = { cfg.on_attach, "function", true },
    })

    for _, name in ipairs({ "changed", "span" }) do
      local layer = cfg.layers[name]
      vim.validate({
        [name] = { layer, "table" },
      })
      vim.validate({
        [name .. ".enable"] = { layer.enable, "boolean" },
        [name .. ".text"] = { layer.text, "string" },
        [name .. ".hl"] = { layer.hl, "string" },
      })
    end

    if cfg.debounce_ms < 0 then
      error("debounce_ms must be >= 0")
    end
    if cfg.max_filesize < 0 then
      error("max_filesize must be >= 0")
    end
    if cfg.preview_context < 0 then
      error("preview_context must be >= 0")
    end
  end)

  if not ok then
    return false, "dft-signs: invalid config: " .. tostring(err)
  end
  return true, nil
end

--- Merge user opts over defaults, validate, and store.
--- @param opts table|nil
--- @return boolean ok
--- @return string|nil err
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  local ok, err = validate(merged)
  if not ok then
    return false, err
  end

  M.values = merged
  return true, nil
end

return M
