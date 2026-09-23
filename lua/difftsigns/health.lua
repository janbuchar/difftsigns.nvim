--- `:checkhealth difftsigns`. "Why is nothing dimmed?" is the only support
--- question this plugin will ever get; every cause is reported here.

local config = require("difftsigns.config")
local gs = require("difftsigns.gitsigns")

local M = {}

local health = vim.health
local start, ok, warn, error_, info = health.start, health.ok, health.warn, health.error, health.info

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
  local versions = config.values.difft_versions

  if ver == nil then
    warn("could not parse a version from `difft --version`")
  elseif vim.list_contains(versions, ver) then
    ok(("version %s is validated"):format(ver))
  else
    warn(("version %s found, validated: %s"):format(ver, table.concat(versions, ", ")), {
      "difftastic's JSON output is explicitly unstable.",
      "Verify the overlay looks correct, then add '" .. ver .. "' to difft_versions.",
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

  info("difftastic has no move detection: a reordered block reads as a real change.")
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

  -- Two of the four things read from gitsigns are internal.
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
