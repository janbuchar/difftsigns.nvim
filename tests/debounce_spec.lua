local debounce = require("difftsigns.debounce")

describe("debounce_trailing", function()
  it("fires once after a burst", function()
    local calls = 0
    local fn, timer = debounce.debounce_trailing(30, function()
      calls = calls + 1
    end)

    fn()
    fn()
    fn()

    -- Nothing yet (window not elapsed).
    assert.are.equal(0, calls)

    vim.wait(120, function()
      return calls > 0
    end, 10)

    assert.are.equal(1, calls)

    timer:stop()
    timer:close()
  end)
end)
