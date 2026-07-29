--- health.lua — `:checkhealth dft-signs`
---
--- The #1 support question for a plugin built on an explicitly-unstable JSON
--- schema will be "why don't I see signs?" — usually a missing difft, a version
--- mismatch, or a language difft can't parse structurally. Surface all three.

local config = require("dft-signs.config")

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error

function M.check()
  start("dft-signs")

  local cmd = config.values.difft_cmd
  if vim.fn.executable(cmd) ~= 1 then
    error_(("difftastic ('%s') not found on PATH"):format(cmd), {
      "Install difftastic: https://github.com/Wilfred/difftastic",
      "Or set difft_cmd to its absolute path in setup().",
    })
    return
  end
  ok(("difftastic found: %s"):format(cmd))

  local res = vim.system({ cmd, "--version" }, { text = true }):wait()
  local ver = res.stdout and res.stdout:match("Difftastic%s+([%d%.]+)")
  local expected = config.values.difft_version_expected

  if ver == nil then
    warn("could not parse difftastic version from --version output")
  elseif ver == expected then
    ok(("difftastic version %s matches the validated pin"):format(ver))
  else
    warn(("difftastic version %s != validated %s"):format(ver, expected), {
      "The JSON schema is unstable; parsing may misbehave.",
      "Verify signs look right, then set difft_version_expected = '" .. ver .. "'.",
    })
  end

  -- JSON support gate.
  local probe = vim.system(
    { cmd, "--display", "json", "--color", "never", "/dev/null", "/dev/null" },
    { text = true, env = { DFT_UNSTABLE = "yes" } }
  ):wait()
  if probe.code == 0 or probe.code == 1 then
    ok("--display json works (DFT_UNSTABLE gate satisfied)")
  else
    error_("difftastic --display json failed", {
      "stderr: " .. tostring(probe.stderr),
    })
  end
end

return M
