--- overlay.lua
---
--- Renders the verdict (REDESIGN §2 R4). Speaks only Verdicts; knows nothing
--- about difftastic, git, or gitsigns.
---
--- The mechanism: for every gutter cell gitsigns drew on a line difftastic
--- considers mere formatting noise, we place our own sign in the SAME cell at a
--- HIGHER extmark priority, using gitsigns' own glyph but a dim highlight. Ours
--- wins the cell; gitsigns shows through untouched everywhere else. One column,
--- one set of shapes, and "real changes pop" falls out for free because
--- everything around them recedes.
---
--- Two rules govern this file:
---
---   1. WE SUBTRACT EMPHASIS, WE NEVER ADD IT. Every cell we touch is a cell
---      gitsigns already drew. We never place a sign on a line that had none;
---      that would put us back in the business of owning a gutter, which is the
---      mistake iteration 2 exists to correct.
---
---   2. WHEN IN DOUBT, DO NOTHING. An absent overlay leaves plain gitsigns,
---      which is harmless. A wrong overlay hides a real change. All ambiguity
---      resolves toward leaving the cell alone.
---
--- Signs are placed as REAL (non-ephemeral) extmarks. Ephemeral extmarks
--- silently do not render `sign_text` — the call succeeds and draws nothing
--- (REDESIGN §7.3). That cost the PoC several days; it is not being rediscovered.

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

--- Define our highlight groups. `DifftSignsNoise` is the whole visual design of
--- the plugin, so its default matters: it must be clearly recessive without
--- vanishing. `NonText` is the closest stock group to "present but unimportant".
function M.setup_highlights()
  local function ensure(name, link)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
  end
  ensure("DifftSignsNoise", "NonText")
  ensure("DifftSignsContext", "Comment")

  -- Directional marker colours for the preview's -/+ signs, in the sign column.
  --
  -- These link `Added`/`Removed` rather than `DiffAdd`/`DiffDelete` deliberately.
  -- DiffAdd/DiffDelete are diff-MODE groups and are background-only in most
  -- colourschemes — measured in nightfox they are #3c4548 and #403843, two dark
  -- greys indistinguishable from each other, which is worthless for telling an
  -- addition from a removal. `Added`/`Removed`/`Changed` are the standard
  -- foreground groups (`:h hl-Added`) and give actual green and red.
  ensure("DifftSignsAdded", "Added")
  ensure("DifftSignsRemoved", "Removed")

  -- Directional BACKGROUNDS for changed tokens. The source line now carries the
  -- buffer's own syntax highlighting (treesitter/syntax), so the token emphasis
  -- must not fight it for the foreground — a green/red *wash behind* the token
  -- leaves the syntax colour legible while still making the change pop. This is
  -- exactly the one thing DiffAdd/DiffDelete are good for: background-only groups.
  ensure("DifftSignsAddedBg", "DiffAdd")
  ensure("DifftSignsRemovedBg", "DiffDelete")
end

--- Resolve Neovim's "0 means current buffer" convention to a real buffer number.
---
--- Every Neovim API accepts 0 for the current buffer, so callers reasonably pass
--- it. Our per-buffer state is a plain table, where 0 is just a different key
--- from the buffer's real number — so an unresolved 0 silently reports "no
--- overlay here" while the overlay is sitting right there on screen. Resolve
--- once, at every public entry point.
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
--- The user is left with unmodified gitsigns (REDESIGN R6).
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

--- Place the dim overrides.
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
        -- Mirror gitsigns' glyph so only the colour changes, unless the user
        -- explicitly configured a distinct noise glyph.
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

--- Remove the overlay from a buffer, leaving gitsigns untouched.
--- @param bufnr integer
function M.clear(bufnr)
  bufnr = resolve(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- Forget a buffer entirely (on detach/wipe).
--- @param bufnr integer
function M.forget(bufnr)
  bufnr = resolve(bufnr)
  M.clear(bufnr)
  state[bufnr] = nil
end

--- Toggle the overlay for a buffer. With it off the user sees plain gitsigns,
--- which is the point: "show me everything again" must be one keystroke away.
--- @param bufnr integer
--- @return boolean enabled
function M.toggle(bufnr)
  bufnr = resolve(bufnr)
  local st = get_state(bufnr)
  st.enabled = not st.enabled
  M.render(bufnr)
  return st.enabled
end

--- The verdict set for a buffer (for the preview and the status function).
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

--- A one-line summary for a statusline (REDESIGN R6: the failure reason must be
--- queryable). Returns nil when there is nothing to say.
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
