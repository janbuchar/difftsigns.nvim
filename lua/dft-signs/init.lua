--- init.lua
---
--- Public entry point: setup(), config validation, command/keymap registration,
--- autocommands, and the version-pin warning (spec §3, §8).

local config = require("dft-signs.config")
local signs = require("dft-signs.signs")
local attach = require("dft-signs.attach")

local M = {}

local AUGROUP = "DftSigns"

--- Check the installed difft version against the pinned expectation and warn
--- ONCE on mismatch (spec §3: fail loudly, but best-effort — keep going).
local function check_version()
  local expected = config.values.difft_version_expected
  if expected == nil or expected == "" then
    return
  end
  local cmd = config.values.difft_cmd

  vim.system({ cmd, "--version" }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or res.stdout == nil then
        vim.notify(
          "dft-signs: could not run '" .. cmd .. " --version' (is difftastic installed?)",
          vim.log.levels.WARN
        )
        return
      end
      -- First line looks like: "Difftastic 0.69.0"
      local ver = res.stdout:match("Difftastic%s+([%d%.]+)")
      if ver ~= nil and ver ~= expected then
        vim.notify(
          ("dft-signs: difftastic version mismatch (found %s, validated against %s). "
            .. "The JSON schema is unstable; parsing may misbehave. Update difft_version_expected once verified.")
            :format(ver, expected),
          vim.log.levels.WARN
        )
      end
    end)
  end)
end

--- Register :DftSigns subcommands.
local function register_commands()
  local subcommands = {
    attach = function()
      attach.attach(vim.api.nvim_get_current_buf())
    end,
    detach = function()
      attach.detach(vim.api.nvim_get_current_buf())
    end,
    toggle_spans = function()
      signs.toggle_spans(vim.api.nvim_get_current_buf())
    end,
    toggle_changes = function()
      signs.toggle_changes(vim.api.nvim_get_current_buf())
    end,
    preview_span = function()
      signs.preview_span(vim.api.nvim_get_current_buf())
    end,
    refresh = function()
      attach.update(vim.api.nvim_get_current_buf())
    end,
    change_base = function(rev)
      if rev == nil or rev == "" then
        vim.notify("dft-signs: change_base requires a revision", vim.log.levels.ERROR)
        return
      end
      attach.change_base(vim.api.nvim_get_current_buf(), rev)
    end,
  }

  vim.api.nvim_create_user_command("DftSigns", function(opts)
    local sub = opts.fargs[1]
    local handler = subcommands[sub]
    if handler == nil then
      vim.notify("dft-signs: unknown subcommand '" .. tostring(sub) .. "'", vim.log.levels.ERROR)
      return
    end
    handler(opts.fargs[2])
  end, {
    nargs = "+",
    complete = function(_, line)
      local keys = vim.tbl_keys(subcommands)
      table.sort(keys)
      -- Only complete the first arg.
      if select(2, line:gsub("%s+", " ")) <= 1 then
        return keys
      end
      return {}
    end,
    desc = "dft-signs structural gutter commands",
  })
end

--- Autocommands: auto-attach to normal file buffers, flush hidden buffers on
--- entry, re-resolve reference on save (for compare_base = 'save').
local function register_autocmds()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(args)
      -- Defer slightly so filetype is set before we attach.
      vim.schedule(function()
        attach.attach(args.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "TabEnter" }, {
    group = group,
    callback = function(args)
      attach.flush_if_dirty(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      -- On save the 'save' reference changes; refresh so signs re-baseline.
      attach.update(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      signs.setup_highlights()
    end,
  })
end

--- Public setup.
--- @param opts table|nil
function M.setup(opts)
  local ok, err = config.setup(opts)
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  signs.setup_highlights()
  signs.install_provider()
  register_commands()
  register_autocmds()
  check_version()

  -- Attach to any already-open eligible buffers (e.g. lazy setup after files
  -- are open).
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.schedule(function()
        attach.attach(bufnr)
      end)
    end
  end
end

-- Re-export the octo adapter lazily so `require('dft-signs').octo` works without
-- loading octo machinery until asked.
M.octo = setmetatable({}, {
  __index = function(_, k)
    return require("dft-signs.octo")[k]
  end,
})

return M
