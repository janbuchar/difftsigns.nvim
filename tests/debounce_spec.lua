--- Tests for debounce_trailing and throttle_by_id (spec §5).

local debounce = require("difftsigns.debounce")

describe("debounce_trailing", function()
  it("fires once after a burst, with the last args", function()
    local calls = {}
    local fn, timer = debounce.debounce_trailing(30, function(x)
      table.insert(calls, x)
    end)

    fn(1)
    fn(2)
    fn(3)

    -- Nothing yet (window not elapsed).
    assert.are.equal(0, #calls)

    vim.wait(120, function()
      return #calls > 0
    end, 10)

    assert.are.equal(1, #calls)
    assert.are.equal(3, calls[1]) -- last args win

    timer:stop()
    timer:close()
  end)
end)

describe("throttle_by_id", function()
  it("does not run the same id concurrently, queues at most one", function()
    local order = {}
    local resolvers = {}

    local run = debounce.throttle_by_id(function(id, tag, done)
      table.insert(order, "start:" .. tag)
      -- Simulate async: stash the done callback to resolve manually.
      resolvers[tag] = function()
        table.insert(order, "end:" .. tag)
        done()
      end
    end)

    run("buf", "a")
    -- While 'a' is in flight, fire two more; only the LAST should be queued.
    run("buf", "b")
    run("buf", "c")

    assert.are.same({ "start:a" }, order)

    resolvers["a"]() -- finishing 'a' should trigger the queued 'c' (b dropped)
    assert.are.same({ "start:a", "end:a", "start:c" }, order)

    resolvers["c"]()
    assert.are.same({ "start:a", "end:a", "start:c", "end:c" }, order)

    -- 'b' was stale and correctly dropped.
    assert.is_nil(resolvers["b"])
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
