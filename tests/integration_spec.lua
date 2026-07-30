--- End-to-end tests: real git repo, real gitsigns, real difftastic.
---
--- This is the suite that matters. Everything else validates a layer in
--- isolation; this validates the only claim the plugin actually makes, against
--- all three real dependencies at once.
---
--- It exists because the PoC's stated lesson ("test the observable outcome, not
--- the intermediate bookkeeping") was written down and then not applied to the
--- lifecycle module, which shipped untested and silently swallowed every error.

local overlay = require("difftsigns.overlay")
local attach = require("difftsigns.attach")
local config = require("difftsigns.config")
local gs = require("difftsigns.gitsigns")

--- @return string repo_root
local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(...)
    local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
    assert(res.code == 0, "git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(res.stderr))
  end
  git("init", "-q")
  git("config", "user.email", "tests@example.invalid")
  git("config", "user.name", "difftsigns tests")
  return dir
end

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

local function commit(dir, msg)
  vim.system({ "git", "-C", dir, "add", "-A" }, { text = true }):wait()
  local res = vim.system({ "git", "-C", dir, "commit", "-q", "-m", msg }, { text = true }):wait()
  assert(res.code == 0, "commit failed: " .. tostring(res.stderr))
end

--- Open a file and wait until gitsigns has attached and produced a reference.
--- @return integer bufnr
local function open_and_wait(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  local okwait = vim.wait(10000, function()
    return gs.attached(bufnr) and gs.reference_text(bufnr) ~= nil
  end, 50)
  assert(okwait, "gitsigns never attached / never produced compare_text")
  return bufnr
end

--- Wait until gitsigns has recomputed hunks for the buffer.
local function wait_for_hunks(bufnr, expected_min)
  local okwait = vim.wait(10000, function()
    local h = gs.hunks(bufnr)
    return h ~= nil and #h >= expected_min
  end, 50)
  assert(okwait, "gitsigns never produced the expected hunks")
  return gs.hunks(bufnr)
end

--- Force one full difftsigns pass and wait for the verdict to land.
local function run_pass(bufnr)
  overlay.forget(bufnr)
  attach.detach(bufnr)
  attach.attach(bufnr)
  local okwait = vim.wait(15000, function()
    return overlay.verdicts(bufnr) ~= nil or (overlay._state(bufnr) or {}).reason ~= nil
  end, 50)
  assert(okwait, "difftsigns never produced a verdict or a reason")
end

--- Lines carrying an overlay (i.e. demoted as formatting noise).
--- @return table<integer, true>
local function dimmed(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, overlay.ns, 0, -1, {})) do
    out[m[2] + 1] = true
  end
  return out
end

describe("difftsigns end to end", function()
  local dir
  local initialised = false

  before_each(function()
    if not initialised then
      -- attach_to_untracked defaults to false; the new-file case needs it on.
      require("gitsigns").setup({ signcolumn = true, attach_to_untracked = true })
      initialised = true
    end
    config.setup({ debounce_ms = 0 })
    dir = make_repo()
  end)

  after_each(function()
    attach.detach_all()
    vim.cmd("silent! %bwipeout!")
  end)

  it("ACCEPTANCE: dims reindented lines and keeps the new ones lit", function()
    -- The headline case. Wrapping a block in a conditional makes a line differ
    -- flag 5 lines; only 2 of them are real. If this does not work, nothing else
    -- about this plugin matters.
    local path = dir .. "/run.ts"
    write(path, {
      "function run() {",
      "  doThing();",
      "  doOther();",
      "  return 1;",
      "}",
    })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "function run() {",
      "  if (enabled) {",
      "    doThing();",
      "    doOther();",
      "    return 1;",
      "  }",
      "}",
    })
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    local dim = dimmed(bufnr)
    -- Reindented body: pure noise, must be demoted.
    assert.is_true(dim[3], "reindented `doThing();` should be dimmed")
    assert.is_true(dim[4], "reindented `doOther();` should be dimmed")
    assert.is_true(dim[5], "reindented `return 1;` should be dimmed")
    -- Genuinely new structure: must stay lit.
    assert.is_nil(dim[2], "the new `if (enabled) {` must NOT be dimmed")
    assert.is_nil(dim[6], "the new `}` must NOT be dimmed")
  end)

  it("dims an entire hunk that is nothing but a reformat", function()
    local path = dir .. "/fmt.ts"
    write(path, {
      "function greet(name: string) {",
      '  console.log("hello " + name);',
      "  return name.length;",
      "}",
    })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "function greet(",
      "      name: string",
      ") {",
      "      console.log(",
      '            "hello " + name',
      "      );",
      "      return name.length;",
      "}",
    })
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    local dim = dimmed(bufnr)
    local count = 0
    for _ in pairs(dim) do
      count = count + 1
    end
    assert.is_true(count > 0, "a pure reformat must produce dimmed lines")

    -- Nothing in this buffer is a real change, so no gitsigns-marked line may
    -- survive undimmed.
    local signs = gs.signs_for(bufnr)
    for _, s in ipairs(signs or {}) do
      assert.is_true(dim[s.lnum],
        ("line %d is marked by gitsigns but not dimmed, despite no structural change"):format(s.lnum))
    end
  end)

  it("REGRESSION: does not dim a token removed from a reindented line", function()
    -- The bug: reindenting a line AND removing a call argument made difftastic
    -- report the deletion on the lhs only, with the rhs line as pure context
    -- (nothing was *added* there, only whitespace moved). Reading the buffer side
    -- alone concluded "reflow" and dimmed a line from which a real token had
    -- vanished — actively hiding a change, the worst outcome available.
    local path = dir .. "/args.ts"
    write(path, {
      "function f() {",
      "  doThing(alpha, beta);",
      "  const keep = 1;",
      "  const val = 10;",
      "}",
    })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "function f() {",
      "      doThing(alpha);", -- reindent + argument REMOVED
      "      const keep = 1;", -- reindent only
      "      const val = 20;", -- reindent + value changed
      "}",
    })
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    local dim = dimmed(bufnr)
    assert.is_nil(dim[2], "a line with a REMOVED token must not be dimmed as reflow")
    assert.is_nil(dim[4], "a line with a changed value must not be dimmed")
    assert.is_true(dim[3], "the purely reindented line must still be dimmed")
  end)

  it("does NOT dim a genuine edit", function()
    local path = dir .. "/edit.ts"
    write(path, { "const a = 1;", "const b = 2;", "const c = 3;" })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "const b = 99;" })
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    assert.is_nil(dimmed(bufnr)[2], "a real value change must never be dimmed")
  end)

  it("keeps a whole new file lit", function()
    write(dir .. "/base.ts", { "const x = 1;" })
    commit(dir, "initial")

    local path = dir .. "/fresh.ts"
    write(path, { "const brand = 1;", "const shiny = 2;" })

    local bufnr = open_and_wait(path)
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    local dim = dimmed(bufnr)
    assert.is_nil(dim[1], "a brand new file is entirely significant")
    assert.is_nil(dim[2])
  end)

  it("stays inert on a language difftastic cannot parse structurally", function()
    local path = dir .. "/notes.sometextthing"
    write(path, { "alpha", "beta", "gamma" })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "BETA" })
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    -- Must place nothing rather than present a line diff as a structural verdict.
    assert.are.same({}, dimmed(bufnr))
    local st = overlay._state(bufnr)
    assert.is_not_nil(st.reason, "the reason for standing down must be queryable")
  end)

  it("reports a reason instead of failing silently when it cannot help", function()
    local path = dir .. "/guard.ts"
    write(path, { "const a = 1;" })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "const a = 2;" })
    wait_for_hunks(bufnr, 1)

    -- Force the filesize guard to trip.
    config.setup({ debounce_ms = 0, max_filesize = 1 })
    run_pass(bufnr)
    config.setup({ debounce_ms = 0 })

    local st = overlay._state(bufnr)
    assert.is_not_nil(st.reason)
    assert.is_truthy(st.reason:find("max_filesize"))
    assert.are.same({}, dimmed(bufnr), "no overlay when we declined to answer")
  end)

  it("survives detach and leaves no marks behind", function()
    local path = dir .. "/detach.ts"
    write(path, { "function f() {", "  return 1;", "}" })
    commit(dir, "initial")

    local bufnr = open_and_wait(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "function f() {", "  if (x) {", "    return 1;", "  }", "}",
    })
    wait_for_hunks(bufnr, 1)
    run_pass(bufnr)

    attach.detach(bufnr)
    assert.are.same({}, dimmed(bufnr), "detach must remove every overlay mark")
    assert.is_false(attach.is_attached(bufnr))
  end)
end)
