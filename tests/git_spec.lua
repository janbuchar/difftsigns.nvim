--- Regression tests for git.lua reference resolution.
---
--- The bug these guard against: in a git WORKTREE (`.git` is a file, and a
--- parent directory may hold the main repo's real `.git` dir), the old
--- vim.fs.find-based repo detection latched onto the wrong repo and produced a
--- path prefixed with the worktree subdir. `git show :<that>` then failed with
--- exit 128, the error was swallowed, an empty reference was returned, and
--- difft reported the whole file as "created" — the "whole file add/delete"
--- nonsense. We assert reference resolution works in both a plain repo and a
--- worktree.

local git = require("dft-signs.git")

local function have_git()
  return vim.fn.executable("git") == 1
end

--- Run a git command synchronously in a dir; assert success.
local function run_git(dir, ...)
  local args = { "git", "-C", dir, ... }
  local res = vim.system(args, { text = true }):wait()
  assert.are.equal(0, res.code, "git failed: " .. table.concat(args, " ") .. "\n" .. tostring(res.stderr))
  return res.stdout
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
  assert.is_true(done, "async git op timed out")
  return result
end

describe("git.reference_text", function()
  if not have_git() then
    it("skipped (no git)", function()
      pending("git not on PATH")
    end)
    return
  end

  local tmp, repo, nested_file

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    repo = tmp .. "/repo"
    vim.fn.mkdir(repo .. "/pkg/src", "p")
    run_git(vim.fn.getcwd(), "init", "-q", repo)
    run_git(repo, "config", "user.email", "t@t.co")
    run_git(repo, "config", "user.name", "t")

    nested_file = repo .. "/pkg/src/mod.ts"
    local fd = assert(io.open(nested_file, "w"))
    fd:write("export const a = 1;\nexport const b = 2;\n")
    fd:close()
    run_git(repo, "add", ".")
    run_git(repo, "commit", "-qm", "init")
  end)

  after_each(function()
    git.stop()
    vim.fn.delete(tmp, "rf")
  end)

  it("resolves the index reference for a nested file in a plain repo", function()
    local res = await(function(cb)
      git.reference_text(nested_file, "index", cb)
    end)
    local err, lines = res[1], res[2]
    assert.is_nil(err)
    assert.are.equal(2, #lines) -- two committed lines, NOT empty
    assert.are.equal("export const a = 1;", lines[1])
  end)

  it("resolves the reference correctly inside a git WORKTREE", function()
    -- Create a worktree on a new branch. `.git` in the worktree is a FILE.
    local wt = tmp .. "/wt"
    run_git(repo, "worktree", "add", "-q", "-b", "feature", wt)

    local wt_file = wt .. "/pkg/src/mod.ts"
    -- Sanity: the worktree's .git is a file, and a sibling real .git dir exists
    -- in the main repo (the exact trap the old code fell into).
    local stat = (vim.uv or vim.loop).fs_stat(wt .. "/.git")
    assert.are.equal("file", stat.type)

    -- Modify the worktree file so there IS a diff to reference.
    local fd = assert(io.open(wt_file, "w"))
    fd:write("export const a = 999;\nexport const b = 2;\n")
    fd:close()

    local res = await(function(cb)
      git.reference_text(wt_file, "index", cb)
    end)
    local err, lines = res[1], res[2]

    -- The whole point: we get the REAL 2-line reference, not an empty one that
    -- would make difft cry "created".
    assert.is_nil(err)
    assert.are.equal(2, #lines)
    assert.are.equal("export const a = 1;", lines[1])
  end)

  it("returns empty (no error) for a genuinely untracked new file", function()
    local newf = repo .. "/pkg/src/brand_new.ts"
    local fd = assert(io.open(newf, "w"))
    fd:write("export const c = 3;\n")
    fd:close()

    local res = await(function(cb)
      git.reference_text(newf, "index", cb)
    end)
    local err, lines = res[1], res[2]
    assert.is_nil(err) -- new file is not a hard error
    assert.are.equal(0, #lines) -- empty reference => difft reports 'created', correctly
  end)
end)
