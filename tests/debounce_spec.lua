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

describe("throttle_by_id", function()
  it("does not run the same id concurrently, queues at most one", function()
    local starts = 0
    local dones = {}

    local run = debounce.throttle_by_id(function(_, done)
      starts = starts + 1
      -- Simulate async: stash the done callback to resolve manually.
      table.insert(dones, done)
    end)

    run("buf")
    run("buf")
    run("buf")
    assert.are.equal(1, starts)

    dones[1]() -- finishing the first triggers exactly one queued run
    assert.are.equal(2, starts)

    dones[2]()
    assert.are.equal(2, starts)
  end)

  it("runs sequentially for different ids without blocking each other", function()
    local started = {}
    local run = debounce.throttle_by_id(function(id, done)
      table.insert(started, id)
      done()
    end)
    run("x")
    run("y")
    assert.are.same({ "x", "y" }, started)
  end)
end)
