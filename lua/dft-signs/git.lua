--- git.lua
---
--- Git as a CONTENT STORE ONLY (spec §7). We fetch reference text via
--- `git show <rev>:<path>` and never touch git's own diff output — difftastic
--- does 100% of the diffing. This keeps us cleanly independent of git plumbing;
--- if git's diff format changes tomorrow, we don't care.
---
--- Reference text is cached and invalidated by a watcher on `.git/index` and
--- `.git/HEAD`, because the reference only changes on commit/checkout/stage, and
--- re-running `git show` on every 1.5s debounce tick would be wasteful (spec §7).

local uv = vim.uv or vim.loop

local M = {}

-- cache key = repo_root .. "\0" .. rev .. "\0" .. rel_path  ->  string[]
local cache = {}
-- repo_root -> uv_fs_event_t
local watchers = {}
-- containing-dir -> { root = string, prefix = string } | false (not a repo)
local repo_info_cache = {}

--- Resolve the git repo root and index-relative path for a file.
---
--- We ASK GIT rather than hand-rolling `.git` discovery with vim.fs.find. That
--- earlier approach walked up to the FIRST `.git` it found and, in a git
--- worktree (where `.git` is a file pointing elsewhere AND a parent repo may
--- have a real `.git` dir), it latched onto the WRONG repo — producing a path
--- prefixed with the worktree subdir that `git show :<path>` rejects with
--- exit 128 ("exists on disk, but not in the index"). git rev-parse handles
--- worktrees, submodules, symlinks, and bare-repo edge cases correctly; we
--- don't. Cached per directory so we don't spawn on every debounce tick.
---
--- @param path string
--- @return string|nil root   -- git toplevel (worktree-correct)
--- @return string|nil rel    -- path relative to the toplevel (git's convention)
local function repo_info(path)
  local dir = vim.fs.dirname(path)

  local cached = repo_info_cache[dir]
  if cached ~= nil then
    if cached == false then
      return nil, nil
    end
    -- rel = prefix (dir relative to root) + basename
    local rel = cached.prefix .. vim.fs.basename(path)
    return cached.root, rel
  end

  -- --show-toplevel gives the worktree root; --show-prefix gives `dir`
  -- relative to that root (with a trailing slash, or empty at root).
  local res = vim.system(
    { "git", "-C", dir, "rev-parse", "--show-toplevel", "--show-prefix" },
    { text = true }
  ):wait()

  if res.code ~= 0 or res.stdout == nil or res.stdout == "" then
    repo_info_cache[dir] = false
    return nil, nil
  end

  local out = vim.split(res.stdout, "\n", { plain = true })
  local root = out[1]
  local prefix = out[2] or ""
  if root == nil or root == "" then
    repo_info_cache[dir] = false
    return nil, nil
  end

  repo_info_cache[dir] = { root = root, prefix = prefix }
  local rel = prefix .. vim.fs.basename(path)
  return root, rel
end

--- Run a git command asynchronously, capturing stdout.
--- @param args string[]
--- @param cwd string
--- @param callback fun(err: string|nil, stdout: string|nil)
local function git_run(args, cwd, callback)
  local stdout = assert(uv.new_pipe(false))
  local stderr = assert(uv.new_pipe(false))
  local out, errbuf = {}, {}
  local handle

  handle = uv.spawn("git", { args = args, cwd = cwd, stdio = { nil, stdout, stderr } }, function(code)
    stdout:close()
    stderr:close()
    if handle and not handle:is_closing() then
      handle:close()
    end
    vim.schedule(function()
      if code ~= 0 then
        callback("git " .. table.concat(args, " ") .. " failed: " .. table.concat(errbuf), nil)
      else
        callback(nil, table.concat(out))
      end
    end)
  end)

  if handle == nil then
    stdout:close()
    stderr:close()
    callback("dft-signs: failed to spawn git", nil)
    return
  end

  stdout:read_start(function(_, data)
    if data then
      table.insert(out, data)
    end
  end)
  stderr:read_start(function(_, data)
    if data then
      table.insert(errbuf, data)
    end
  end)
end

--- Watch a repo's `.git` for index/HEAD changes and flush the cache for it.
--- @param root string
local function ensure_watcher(root)
  if watchers[root] ~= nil then
    return
  end
  local git_dir = root .. "/.git"
  -- If .git is a file (worktree/submodule), skip watching; correctness still
  -- holds (we just won't auto-invalidate). Cheap and safe.
  local stat = uv.fs_stat(git_dir)
  if stat == nil or stat.type ~= "directory" then
    return
  end

  local ev = uv.new_fs_event()
  if ev == nil then
    return
  end
  ev:start(git_dir, { recursive = false }, function(err, filename)
    if err then
      return
    end
    if filename == "index" or filename == "HEAD" or filename == "ORIG_HEAD" then
      -- Invalidate every cache entry belonging to this repo.
      vim.schedule(function()
        for key in pairs(cache) do
          if key:sub(1, #root + 1) == root .. "\0" then
            cache[key] = nil
          end
        end
      end)
    end
  end)
  watchers[root] = ev
end

--- Fetch reference text for a file at a given revision.
---
--- `rev` is one of the compare_base values: 'index' (=> `:<path>`), 'HEAD', or
--- an arbitrary revision string. 'save' is handled by the attach adapter (it
--- reads the file from disk, not git) and never reaches here.
---
--- @param path string   -- absolute path of the working file
--- @param rev string    -- 'index' | 'HEAD' | <revision>
--- @param callback fun(err: string|nil, lines: string[]|nil, meta: {language?: string}|nil)
function M.reference_text(path, rev, callback)
  local root, rel = repo_info(path)
  if root == nil then
    callback("dft-signs: not inside a git repository", nil)
    return
  end

  ensure_watcher(root)

  local spec
  if rev == "index" then
    spec = ":" .. rel -- staged content
  else
    spec = rev .. ":" .. rel
  end

  local key = root .. "\0" .. spec
  local cached = cache[key]
  if cached ~= nil then
    callback(nil, cached)
    return
  end

  git_run({ "--no-pager", "show", spec }, root, function(err, stdout)
    if err ~= nil then
      -- Distinguish two very different cases that both make `git show` fail:
      --   1. The file is genuinely NEW (untracked / not in the index yet) — a
      --      legitimate empty reference, so difft reports 'created'. Correct.
      --   2. Any OTHER failure (a path-resolution bug, a bad rev, a corrupt
      --      repo) — returning empty here would silently render a real error as
      --      a bogus "whole file added" region. That is exactly the nonsense we
      --      are fixing. Surface it instead.
      -- We tell them apart by asking git whether it tracks the path at all.
      local tracked = vim.system(
        { "git", "-C", root, "ls-files", "--error-unmatch", "--", rel },
        { text = true }
      ):wait()
      if tracked.code == 0 then
        -- Tracked but `show` still failed => a real error, not a new file.
        callback("dft-signs: git show failed for a tracked file: " .. tostring(err), nil)
      else
        -- Not tracked => genuinely new; empty reference is correct.
        callback(nil, {})
      end
      return
    end
    local lines = vim.split(stdout, "\n", { plain = true })
    -- git show emits a trailing newline; drop the resulting empty last element.
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    cache[key] = lines
    callback(nil, lines)
  end)
end

--- Tear down all watchers (on plugin teardown / tests).
function M.stop()
  for root, ev in pairs(watchers) do
    pcall(function()
      ev:stop()
      ev:close()
    end)
    watchers[root] = nil
  end
  cache = {}
  repo_info_cache = {}
end

--- Test helper: is a path inside a git repo?
--- @param path string
--- @return boolean
function M.in_repo(path)
  local root = repo_info(path)
  return root ~= nil
end

return M
