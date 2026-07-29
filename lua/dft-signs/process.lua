--- process.lua
---
--- libuv spawn of difftastic with cancellation and temp-file writing (spec §5).
--- Together with core.lua this is the only place that knows difft exists as a
--- subprocess. Everything is quarantined here so the schema/CLI can change in
--- exactly two files.

local uv = vim.uv or vim.loop

local M = {}

--- Handle to an in-flight difft run so the caller can cancel it (spec §5:
--- "kill the in-flight job rather than queue a stale result").
--- @class DftSigns.Job
--- @field cancel fun()

--- Write an array of lines to a fresh temp file. Returns the path.
--- Mirrors gitsigns' diff_ext.lua approach: difft diffs files, not strings.
---
--- We preserve the original file's EXTENSION on the tempfile. difftastic infers
--- the language from the path; a bare `tempname()` has no extension, so difft
--- detects "Text" and silently falls back to a line diff — exactly the mislabel
--- we refuse to render (spec §5/§9.4). Suffixing with the real extension lets
--- difft's own detection work even when the caller supplies no explicit `lang`
--- (e.g. filetype not set yet).
--- @param lines string[]
--- @param ext string|nil  -- extension WITHOUT the dot, e.g. "rs"
--- @return string|nil path
--- @return string|nil err
local function write_tempfile(lines, ext)
  local path = vim.fn.tempname()
  if ext ~= nil and ext ~= "" then
    path = path .. "." .. ext
  end
  local fd, open_err = uv.fs_open(path, "w", 384) -- 0600
  if fd == nil then
    return nil, "dft-signs: could not open tempfile: " .. tostring(open_err)
  end

  local data = table.concat(lines, "\n")
  -- difft, like most line tools, is happier with a trailing newline.
  if #lines > 0 then
    data = data .. "\n"
  end

  local ok_write, write_err = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if ok_write == nil then
    return nil, "dft-signs: could not write tempfile: " .. tostring(write_err)
  end

  return path, nil
end

--- Build the argv for difft. Language overrides use difft's --override glob
--- syntax: '<glob>:<lang>'.
--- @param old_path string
--- @param new_path string
--- @param opts table
--- @return string[]
local function build_args(old_path, new_path, opts)
  local args = {
    "--display", "json",
    "--color", "never",
  }

  if opts.lang ~= nil and opts.lang ~= "" then
    -- Force a language for both temp paths. We match on the tempfile basenames.
    -- A blanket '*:<lang>' override is simplest and unambiguous here since these
    -- are throwaway files.
    table.insert(args, "--override=*:" .. opts.lang)
  end

  if type(opts.language_overrides) == "table" then
    for glob, lang in pairs(opts.language_overrides) do
      table.insert(args, "--override=" .. glob .. ":" .. lang)
    end
  end

  table.insert(args, old_path)
  table.insert(args, new_path)
  return args
end

--- Spawn difft asynchronously.
---
--- @param old_text string[]
--- @param new_text string[]
--- @param opts { lang?: string, filename?: string, difft_cmd?: string, language_overrides?: table }
--- @param callback fun(err: string|nil, json_str: string|nil)
--- @return DftSigns.Job|nil job  -- handle for cancellation, nil if spawn failed synchronously
function M.run(old_text, new_text, opts, callback)
  opts = opts or {}
  local cmd = opts.difft_cmd or "difft"

  -- Derive an extension from the caller's filename so difft's own language
  -- detection works without an explicit --override (spec §5/§9.4).
  local ext = nil
  if opts.filename ~= nil and opts.filename ~= "" then
    ext = opts.filename:match("%.([%w_]+)$")
  end

  local old_path, old_err = write_tempfile(old_text, ext)
  if old_path == nil then
    callback(old_err, nil)
    return nil
  end

  local new_path, new_err = write_tempfile(new_text, ext)
  if new_path == nil then
    uv.fs_unlink(old_path)
    callback(new_err, nil)
    return nil
  end

  local args = build_args(old_path, new_path, opts)

  local stdout = assert(uv.new_pipe(false))
  local stderr = assert(uv.new_pipe(false))
  local stdout_chunks = {}
  local stderr_chunks = {}

  local handle
  local cancelled = false
  local finished = false

  local function cleanup()
    uv.fs_unlink(old_path)
    uv.fs_unlink(new_path)
  end

  local function finish(err, json_str)
    if finished then
      return
    end
    finished = true
    cleanup()
    -- Hop back onto the main loop; libuv exit callbacks run in a fast context
    -- where most Neovim API calls are forbidden.
    vim.schedule(function()
      if cancelled then
        return
      end
      callback(err, json_str)
    end)
  end

  local spawn_opts = {
    args = args,
    stdio = { nil, stdout, stderr },
    -- --display json is gated behind DFT_UNSTABLE=yes; we set it ourselves so
    -- the user never has to (spec §3).
    env = (function()
      local env = {}
      for k, v in pairs(uv.os_environ and uv.os_environ() or {}) do
        table.insert(env, k .. "=" .. v)
      end
      table.insert(env, "DFT_UNSTABLE=yes")
      return env
    end)(),
  }

  handle = uv.spawn(cmd, spawn_opts, function(code, _signal)
    if not stdout:is_closing() then
      stdout:close()
    end
    if not stderr:is_closing() then
      stderr:close()
    end
    if handle ~= nil and not handle:is_closing() then
      handle:close()
    end

    if cancelled then
      cleanup()
      finished = true
      return
    end

    -- difft exits non-zero for its own reasons; code 1 simply means "files
    -- differ" in some modes, but with --display json a successful run is 0 or 1.
    -- Anything else (notably 2 = the DFT_UNSTABLE gate, or a crash) is an error.
    if code ~= 0 and code ~= 1 then
      finish("dft-signs: difft exited with code " .. code .. ": " .. table.concat(stderr_chunks), nil)
      return
    end

    finish(nil, table.concat(stdout_chunks))
  end)

  if handle == nil then
    stdout:close()
    stderr:close()
    cleanup()
    callback("dft-signs: failed to spawn '" .. cmd .. "' (is difftastic installed?)", nil)
    return nil
  end

  stdout:read_start(function(err, data)
    if err then
      return
    end
    if data then
      table.insert(stdout_chunks, data)
    end
  end)

  stderr:read_start(function(err, data)
    if err then
      return
    end
    if data then
      table.insert(stderr_chunks, data)
    end
  end)

  return {
    cancel = function()
      if finished or cancelled then
        return
      end
      cancelled = true
      if handle ~= nil and not handle:is_closing() then
        -- SIGTERM the in-flight difft; stale structural diffs are worse than
        -- absent ones (spec §5).
        pcall(function()
          handle:kill("sigterm")
        end)
      end
    end,
  }
end

return M
