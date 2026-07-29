--- Tests for the octo review adapter (spec §7 endgame).
--- Proves the revision-agnostic core works for blob-vs-blob on a scratch buffer
--- that is NOT a file and is NOT the "live" side of anything — exactly the case
--- mini.diff cannot express.

local octo = require("dft-signs.octo")
local signs = require("dft-signs.signs")
local config = require("dft-signs.config")

local function have_difft()
  return vim.fn.executable("difft") == 1
end

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

describe("octo.review (blob vs blob)", function()
  before_each(function()
    config.setup({})
  end)

  if not have_difft() then
    it("is skipped because difft is not installed", function()
      pending("difft not on PATH")
    end)
    return
  end

  it("decorates a scratch review buffer from two blobs, neither being a file", function()
    -- A scratch buffer standing in for octo's review buffer. It is not backed by
    -- any file; both diff sides are supplied text.
    local buf = vim.api.nvim_create_buf(false, true)
    local head = { "fn main() {", "    let x = 2;", "    let y = 3;", "}" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, head)

    local base = { "fn main() {", "    let x = 1;", "}" }

    local res = await(function(cb)
      octo.review(buf, base, head, { lang = "rust" }, function(err)
        cb(err)
      end)
    end)

    assert.is_nil(res[1])

    local st = signs._state(buf)
    assert.is_not_nil(st)
    -- At least one buffer line must be flagged as changed on the head side.
    local any_changed = false
    for _ in pairs(st.changed_by_line) do
      any_changed = true
      break
    end
    assert.is_true(any_changed, "expected structural changes on the review buffer")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
