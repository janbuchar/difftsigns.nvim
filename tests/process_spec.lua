--- End-to-end test of process.lua + core.run_diff against the REAL difft binary.
---
--- Covers the spawn -> JSON -> parse path that fixtures cannot: the DFT_UNSTABLE
--- gate, exit-code handling, tempfile extensions (difft infers the language from
--- the path, so a tempfile without one degrades to a line diff), and cancellation.
---
--- Skipped automatically when difft is absent so the suite stays green.

local core = require("difftsigns.core")

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
  vim.wait(timeout_ms or 10000, function()
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

  it("flags the genuinely changed line and not its neighbours", function()
    local old_text = { "fn main() {", "    let x = 1;", '    println!("{}", x);', "}" }
    local new_text = { "fn main() {", "    let x = 2;", '    println!("{}", x);', "}" }

    local err, result = unpack(await(function(cb)
      core.run_diff(old_text, new_text, { lang = "rust", filename = "t.rs" }, cb)
    end))

    assert.is_nil(err)
    assert.are.equal("changed", result.status)
    assert.is_true(result.changed_rhs[2], "the mutated line must be flagged")
    assert.is_nil(result.changed_rhs[1], "an untouched line must not be flagged")
    assert.is_nil(result.changed_rhs[3])
    assert.is_false(result.fallback)
  end)

  it("reports unchanged for identical text", function()
    local text = { "fn main() {}", "" }
    local err, result = unpack(await(function(cb)
      core.run_diff(text, text, { lang = "rust", filename = "t.rs" }, cb)
    end))
    assert.is_nil(err)
    assert.are.equal("unchanged", result.status)
    assert.are.same({}, result.changed_rhs)
  end)

  it("reports unchanged for a whitespace-only reformat (the whole point)", function()
    -- The end-to-end proof that DFT_UNSTABLE, the tempfile extension, and the
    -- parse all line up: a reindent must survive the round trip as `unchanged`.
    local old_text = { "fn main() {", "    let x = 1;", "}" }
    local new_text = { "fn main() {", "        let x = 1;", "}" }
    local err, result = unpack(await(function(cb)
      core.run_diff(old_text, new_text, { lang = "rust", filename = "t.rs" }, cb)
    end))
    assert.is_nil(err)
    assert.are.equal("unchanged", result.status)
  end)

  it("infers the language from the filename extension alone", function()
    -- No explicit `lang`: difft must still parse structurally, which only works
    -- because the tempfile carries the source extension.
    local err, result = unpack(await(function(cb)
      core.run_diff(
        { "const a = 1;", "const b = 2;" },
        { "const a = 1;", "const b = 3;" },
        { filename = "thing.ts" },
        cb
      )
    end))
    assert.is_nil(err)
    assert.is_false(result.fallback, "expected a structural diff, got a line-diff fallback")
    assert.are.equal("TypeScript", result.language)
  end)

  it("flags a line-diff fallback for content it cannot parse", function()
    local err, result = unpack(await(function(cb)
      core.run_diff({ "alpha", "beta" }, { "alpha", "BETA" }, { filename = "x.unknownext" }, cb)
    end))
    assert.is_nil(err)
    assert.is_true(result.fallback, "unparseable content must be reported as a fallback")
  end)

  it("surfaces an error when difft cannot be executed", function()
    local err = unpack(await(function(cb)
      core.run_diff({ "a" }, { "b" }, { difft_cmd = "difft-does-not-exist", filename = "x.ts" }, cb)
    end))
    assert.is_not_nil(err, "a missing binary must produce an error, not silence")
  end)

  it("suppresses the callback of a cancelled run", function()
    local called = false
    local job = core.run_diff(
      { "const a = 1;" },
      { "const a = 2;" },
      { filename = "x.ts" },
      function()
        called = true
      end
    )
    assert.is_not_nil(job, "expected a cancellation handle")
    job.cancel()
    vim.wait(1500, function()
      return called
    end, 20)
    assert.is_false(called, "a cancelled run must not deliver a stale verdict")
  end)
end)
