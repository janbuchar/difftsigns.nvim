--- octo.lua
---
--- The endgame adapter (spec §7, §11 step 4): octo.nvim review mode. Neither
--- side is the working file — it's blob@base vs blob@head. Because the core
--- (`core.run_diff`) takes two ARBITRARY text arrays and assumes nothing about
--- which side is the live buffer, this adapter is trivial: obtain both blobs,
--- feed them to the core, place the returned Regions on octo's review buffer.
---
--- This is the whole payoff of the revision-agnostic core (spec §7): octo
--- support is ~a page, not a fork. Contrast mini.diff, whose "one side IS the
--- attached buffer" assumption makes blob-vs-blob impossible.

local core = require("dft-signs.core")
local signs = require("dft-signs.signs")

local M = {}

--- Decorate an octo review buffer with structural signs for a blob-vs-blob diff.
---
--- The caller (octo integration glue) supplies both sides directly — octo
--- already has the blobs, or fetches them via the GitHub API. We do not reach
--- into octo internals here; we take text in and place signs out, keeping the
--- coupling to octo at the single call site.
---
--- @param bufnr integer        -- octo's review buffer to decorate
--- @param base_text string[]   -- blob@base (lhs / reference)
--- @param head_text string[]   -- blob@head (rhs / the reviewed side)
--- @param opts { lang?: string, filename?: string }|nil
--- @param callback fun(err: string|nil)|nil
function M.review(bufnr, base_text, head_text, opts, callback)
  opts = opts or {}
  callback = callback or function() end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback("dft-signs: invalid octo review buffer " .. tostring(bufnr))
    return
  end

  -- Ensure the decoration provider is tracking this buffer. We register a
  -- minimal state entry via set_regions (empty until the diff returns) so the
  -- provider's on_win short-circuit lets on_line through for it.
  signs.set_regions(bufnr, {})

  core.run_diff(base_text, head_text, {
    lang = opts.lang,
    filename = opts.filename,
  }, function(err, result)
    if err ~= nil then
      callback(err)
      return
    end

    if result.fallback then
      -- Non-structural fallback: clear rather than mislabel (spec §9.4).
      signs.clear(bufnr)
      callback(nil)
      return
    end

    if result.status == "unchanged" then
      signs.clear(bufnr)
    else
      -- base_text is the reference side; retain it for the span preview.
      signs.set_regions(bufnr, result.regions, base_text)
    end
    callback(nil)
  end)
end

--- Remove structural signs from an octo review buffer (on review close).
--- @param bufnr integer
function M.clear(bufnr)
  signs.clear(bufnr)
  signs.forget(bufnr)
end

return M
