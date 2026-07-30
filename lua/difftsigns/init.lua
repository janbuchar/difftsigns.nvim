--- init.lua
---
--- Public entry point: setup(), commands, autocommands, version check.
---
--- The whole user-facing surface is deliberately tiny (REDESIGN §1): the plugin
--- draws no column of its own, defines no regions, resolves no revisions, and
--- adds no navigation. `]c` remains gitsigns'. The only command worth binding is
--- the preview, and that REPLACES a gitsigns binding rather than adding one.

local config = require("difftsigns.config")
local attach = require("difftsigns.attach")
local overlay = require("difftsigns.overlay")
local gs = require("difftsigns.gitsigns")

local M = {}

local AUGROUP = "DifftSigns"

--- Warn once if the installed difftastic is not the version whose JSON we
--- validated against. The schema is explicitly unstable; the only honest
--- response is to be loud rather than silently mis-parse.
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
          ("difftsigns: could not run '%s --version' (is difftastic installed?)"):format(cmd),
          vim.log.levels.WARN
        )
        return
      end
      local ver = res.stdout:match("Difftastic%s+([%d%.]+)")
      if ver ~= nil and ver ~= expected then
        vim.notify(
          ("difftsigns: difftastic %s found, %s validated. The JSON schema is unstable; "
            .. "verify the overlay looks right, then set difft_version_expected = '%s'.")
            :format(ver, expected, ver),
          vim.log.levels.WARN
        )
      end
    end)
  end)
end

local function register_commands()
  local subcommands = {
    preview = function()
      require("difftsigns.preview").show()
    end,
    refresh = function()
      attach.update(vim.api.nvim_get_current_buf())
    end,
    toggle = function()
      local on = overlay.toggle(vim.api.nvim_get_current_buf())
      vim.notify("difftsigns: overlay " .. (on and "on" or "off"), vim.log.levels.INFO)
    end,
    attach = function()
      attach.attach(vim.api.nvim_get_current_buf())
    end,
    detach = function()
      attach.detach(vim.api.nvim_get_current_buf())
    end,
    status = function()
      vim.notify(overlay.status() or "difftsigns: nothing to report", vim.log.levels.INFO)
    end,
  }

  vim.api.nvim_create_user_command("DifftSigns", function(opts)
    local sub = opts.fargs[1]
    local handler = subcommands[sub]
    if handler == nil then
      local keys = vim.tbl_keys(subcommands)
      table.sort(keys)
      vim.notify(
        ("difftsigns: unknown subcommand '%s' (try: %s)"):format(tostring(sub), table.concat(keys, ", ")),
        vim.log.levels.ERROR
      )
      return
    end
    handler()
  end, {
    nargs = 1,
    complete = function()
      local keys = vim.tbl_keys(subcommands)
      table.sort(keys)
      return keys
    end,
    desc = "difftsigns structural overlay commands",
  })
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  -- The single trigger for everything. gitsigns fires this whenever its hunks
  -- change, which is precisely when our verdict could be stale. Driving off it
  -- means we never annotate hunks gitsigns has already superseded, and we get
  -- its buffer watching, its debounce, and its base changes for free.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "GitSignsUpdate",
    callback = function(args)
      local bufnr = args.data and args.data.buffer
      if bufnr == nil then
        -- A global update (HEAD changed): refresh every buffer we track.
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if attach.is_attached(b) then
            attach.schedule(b)
          end
        end
        return
      end
      if not attach.is_attached(bufnr) then
        attach.attach(bufnr)
      else
        attach.schedule(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      attach.detach(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      overlay.setup_highlights()
    end,
  })
end

--- @param opts table|nil
function M.setup(opts)
  local ok, err = config.setup(opts)
  if not ok then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  overlay.setup_highlights()
  register_commands()
  register_autocmds()
  check_version()

  -- gitsigns is not optional under this design: we only ever demote cells it
  -- drew, so without it there is nothing to annotate. Say so at setup() rather
  -- than leaving the user to wonder why nothing happens.
  local available, reason = gs.available()
  if not available then
    vim.notify(
      "difftsigns: " .. tostring(reason) .. ". This plugin annotates gitsigns' gutter and "
        .. "does nothing on its own.",
      vim.log.levels.WARN
    )
    return
  end

  -- Adopt buffers gitsigns is already tracking (setup order is not guaranteed).
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and gs.attached(bufnr) then
      attach.attach(bufnr)
    end
  end
end

--- Statusline helper (REDESIGN R6: the reason must be queryable).
--- @param bufnr integer|nil
--- @return string|nil
function M.status(bufnr)
  return overlay.status(bufnr)
end

--- Preview the hunk under the cursor. Bind this in place of
--- gitsigns' `preview_hunk`.
function M.preview()
  return require("difftsigns.preview").show()
end

--- Toggle the overlay for the current buffer.
function M.toggle()
  return overlay.toggle(vim.api.nvim_get_current_buf())
end

return M
