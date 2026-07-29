--- End-to-end test of process.lua + core.run_diff against the REAL difft binary.
--- Skipped automatically if difft is not on PATH so the suite stays green on
--- machines without it.

local core = require("dft-signs.core")

local function have_difft()
  return vim.fn.executable("difft") == 1
end

--- Drive an async callback to completion inside a headless run.
local function await(fn, timeout_ms)
  local done, result = false, nil
  fn(function(...)
    result = { ... }
    done = true
  end)
  vim.wait(timeout_ms or 5000, function()
    return done
  end, 20)
  assert.is_true(done, "async operation timed out")
  return result
end

describe("core.run_diff (real difft)", function()
  if not have_difft() then
    it("is skipped because difft is not installed", function()
      pending("difft not on PATH")
    end)
    return
  end

  it("diffs two Rust snippets and reports the changed line", function()
    local old_text = { "fn main() {", "    let x = 1;", "    println!(\"{}\", x);", "}" }
    local new_text = { "fn main() {", "    let x = 2;", "    let y = 3;", "    println!(\"{} {}\", x, y);", "}" }

    local res = await(function(cb)
      core.run_diff(old_text, new_text, { lang = "rust" }, cb)
    end)

    local err, result = res[1], res[2]
    assert.is_nil(err)
    assert.are.equal("changed", result.status)
    assert.is_true(#result.regions >= 1)

    -- The mutation on buffer line 2 (let x = 1 -> 2) must be flagged, and the
    -- untouched `fn main() {` on line 1 must not be.
    local changed = {}
    for _, region in ipairs(result.regions) do
      for _, l in ipairs(region.changed) do
        changed[l] = true
      end
    end
    assert.is_true(changed[2])
    assert.is_nil(changed[1])
  end)

  it("reports unchanged for identical text", function()
    local text = { "fn main() {}", "" }
    local res = await(function(cb)
      core.run_diff(text, text, { lang = "rust" }, cb)
    end)
    assert.is_nil(res[1])
    assert.are.equal("unchanged", res[2].status)
  end)
end)
