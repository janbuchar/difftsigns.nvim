--- health.lua — `:checkhealth difftsigns`
---
--- This plugin has two hard external dependencies and one explicitly unstable
--- wire format, so "why is nothing dimmed?" will be the only support question
--- anyone ever asks. Every way that can happen is reported here:
---   * difftastic missing, or a version whose JSON we have not validated;
---   * the DFT_UNSTABLE gate on --display json;
---   * gitsigns missing, or its internals moved under us;
---   * gitsigns configured without a sign column, so overrides are invisible.

local config = require("difftsigns.config")
local gs = require("difftsigns.gitsigns")

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error
local info = health.info or health.report_info

local function check_difft()
  start("difftsigns: difftastic")

  local cmd = config.values.difft_cmd
  if vim.fn.executable(cmd) ~= 1 then
    error_(("difftastic ('%s') not found on PATH"):format(cmd), {
      "Install difftastic: https://github.com/Wilfred/difftastic",
      "Or set difft_cmd to an absolute path in setup().",
    })
    return
  end
  ok(("difftastic found: %s"):format(cmd))

  local res = vim.system({ cmd, "--version" }, { text = true }):wait()
  local ver = res.stdout and res.stdout:match("Difftastic%s+([%d%.]+)")
  local expected = config.values.difft_version_expected

  if ver == nil then
    warn("could not parse a version from `difft --version`")
  elseif ver == expected then
    ok(("version %s matches the validated pin"):format(ver))
  else
    warn(("version %s found, %s validated"):format(ver, expected), {
      "difftastic's JSON output is explicitly unstable.",
      "Verify the overlay looks correct, then set difft_version_expected = '" .. ver .. "'.",
    })
  end

  local probe = vim.system(
    { cmd, "--display", "json", "--color", "never", "/dev/null", "/dev/null" },
    { text = true, env = { DFT_UNSTABLE = "yes" } }
  ):wait()
  if probe.code == 0 or probe.code == 1 then
    ok("`--display json` works (DFT_UNSTABLE gate satisfied)")
  else
    error_("`difft --display json` failed", { "stderr: " .. tostring(probe.stderr) })
  end

  info("difftastic 0.69 has no move detection: a reordered block reads as a real change.")
end

local function check_gitsigns()
  start("difftsigns: gitsigns")

  local available, reason = gs.available()
  if not available then
    error_(tostring(reason), {
      "difftsigns annotates gitsigns' gutter; it does nothing on its own.",
      "Install gitsigns.nvim: https://github.com/lewis6991/gitsigns.nvim",
    })
    return
  end
  ok("gitsigns is present and its API is readable")
  info("gitsigns version: " .. tostring(gs.version()))

  if gs.signcolumn_enabled() then
    ok(("sign priority %d; overlay places at %d"):format(
      gs.sign_priority(), gs.sign_priority() + config.values.priority_offset
    ))
  else
    warn("gitsigns has signcolumn disabled", {
      "difftsigns dims sign-column cells, so it will have nothing to act on.",
      "Enable gitsigns' signcolumn, or accept that the overlay is inert.",
    })
  end

  -- The one genuinely fragile dependency: two of the four things we read from
  -- gitsigns are internal. Report it plainly rather than pretending otherwise.
  local cache_ok = pcall(function()
    return require("gitsigns.cache").cache
  end)
  if cache_ok then
    ok("gitsigns.cache is readable (reference text + hunk geometry)")
  else
    error_("gitsigns.cache is not readable; the overlay will stay inert")
  end
end

local function check_buffer()
  start("difftsigns: current buffer")

  local bufnr = vim.api.nvim_get_current_buf()
  if not gs.attached(bufnr) then
    info("gitsigns is not attached to this buffer; nothing to annotate")
    return
  end
  ok("gitsigns is attached")

  local status = require("difftsigns.overlay").status(bufnr)
  if status ~= nil then
    info(status)
  else
    info("no verdict yet, or nothing to demote")
  end
end

function M.check()
  check_difft()
  check_gitsigns()
  check_buffer()
end

return M
