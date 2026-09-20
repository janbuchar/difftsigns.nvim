--- Renders the verdict: for every gutter cell gitsigns drew on a line difftastic
--- considers formatting noise, place our own sign in the SAME cell at a HIGHER
--- extmark priority, with gitsigns' glyph but a dim highlight.
---
--- Two rules:
---   1. We subtract emphasis, never add it. We never place a sign on a line
---      that had none.
---   2. When in doubt, do nothing. A wrong overlay hides a real change; an
---      absent one leaves plain gitsigns.
---
--- Signs are REAL extmarks: ephemeral extmarks silently do not render `sign_text`.

local config = require("difftsigns.config")
local verdict = require("difftsigns.verdict")

local M = {}

M.ns = vim.api.nvim_create_namespace("difftsigns_overlay")

--- @class DifftSigns.BufState
--- @field set      DifftSigns.VerdictSet|nil
--- @field ref      string[]|nil   -- reference text, retained for the preview
--- @field enabled  boolean
--- @field reason   string|nil     -- why there is no overlay (for the status fn)
local state = {}

function M.setup_highlights()
  local function ensure(name, link)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
  end
  ensure("DifftSignsNoise", "NonText")
  ensure("DifftSignsContext", "Comment")

  -- Preview -/+ markers link `Added`/`Removed` (`:h hl-Added`), not
  -- DiffAdd/DiffDelete: those are background-only in most colourschemes and
  -- indistinguishable from each other as sign colours.
  ensure("DifftSignsAdded", "Added")
  ensure("DifftSignsRemoved", "Removed")

  -- Token washes are backgrounds so the buffer's syntax foreground stays legible.
  ensure("DifftSignsAddedBg", "DiffAdd")
  ensure("DifftSignsRemovedBg", "DiffDelete")
end

--- Per-buffer state is keyed by real buffer number, so 0 must be resolved.
--- @param bufnr integer|nil
--- @return integer
local function resolve(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

--- @param bufnr integer
--- @return DifftSigns.BufState
local function get_state(bufnr)
  state[bufnr] = state[bufnr] or { enabled = true }
  return state[bufnr]
end

--- Install a verdict set for a buffer and redraw the overlay.
---
--- @param bufnr integer
--- @param set DifftSigns.VerdictSet
--- @param signs table[]|nil  -- gitsigns' sign descriptors: { lnum, type, hunk_index }
--- @param ref string[]|nil   -- reference text, retained for the preview
function M.apply(bufnr, set, signs, ref)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local st = get_state(bufnr)
  st.set = set
  st.ref = ref
  st.signs = signs
  st.reason = nil
  M.render(bufnr)
end

--- Record that no structural answer is available, and remove any stale overlay.
--- @param bufnr integer
--- @param reason string
function M.unavailable(bufnr, reason)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local st = get_state(bufnr)
  st.set = nil
  st.signs = nil
  st.reason = reason
  M.clear(bufnr)
end

--- @param bufnr integer
function M.render(bufnr)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local st = state[bufnr]
  if st == nil or st.set == nil or not st.enabled then
    return
  end
  if st.set.unavailable or st.signs == nil then
    return
  end

  local cfg = config.values
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local priority = require("difftsigns.gitsigns").sign_priority() + cfg.priority_offset

  for _, sign in ipairs(st.signs) do
    local v = st.set.verdicts[sign.hunk_index]
    -- No verdict for this hunk => leave gitsigns' cell alone (rule 2).
    if v ~= nil and not verdict.is_significant(v, sign.lnum) then
      local row = sign.lnum - 1
      if row >= 0 and row < line_count then
        local text = cfg.noise_text or require("difftsigns.gitsigns").sign_text(sign.type)
        if text ~= nil and text ~= "" then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
            sign_text = text,
            sign_hl_group = cfg.noise_hl,
            priority = priority,
          })
        end
      end
    end
  end
end

--- @param bufnr integer
function M.clear(bufnr)
  bufnr = resolve(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- @param bufnr integer
function M.forget(bufnr)
  bufnr = resolve(bufnr)
  M.clear(bufnr)
  state[bufnr] = nil
end

--- @param bufnr integer
--- @return boolean enabled
function M.toggle(bufnr)
  bufnr = resolve(bufnr)
  local st = get_state(bufnr)
  st.enabled = not st.enabled
  M.render(bufnr)
  return st.enabled
end

--- @param bufnr integer
--- @return DifftSigns.VerdictSet|nil
function M.verdicts(bufnr)
  bufnr = resolve(bufnr)
  local st = state[bufnr]
  return st and st.set or nil
end

--- Retained reference text, for the preview's "before" side.
--- @param bufnr integer
--- @return string[]|nil
function M.reference(bufnr)
  bufnr = resolve(bufnr)
  local st = state[bufnr]
  return st and st.ref or nil
end

--- One-line statusline summary; nil when there is nothing to say.
--- @param bufnr integer|nil
--- @return string|nil
function M.status(bufnr)
  bufnr = resolve(bufnr)
  local st = state[bufnr]
  if st == nil then
    return nil
  end
  if st.reason ~= nil then
    return "difft: " .. st.reason
  end
  if st.set == nil then
    return nil
  end
  local s = verdict.summary(st.set)
  if s.noise == 0 then
    return nil
  end
  return ("difft: %d noise / %d real"):format(s.noise, s.significant)
end

--- Test/introspection helper.
--- @param bufnr integer
function M._state(bufnr)
  bufnr = resolve(bufnr)
  return state[bufnr]
end

return M
