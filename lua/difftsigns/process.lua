--- Spawns difftastic with cancellation and temp-file writing.

local M = {}

--- Handle to an in-flight difft run so the caller can cancel it.
--- @class DifftSigns.Job
--- @field cancel fun()

--- difft infers the language from the path: a bare `tempname()` has no
--- extension, so it would detect "Text" and silently fall back to a line diff.
--- @param lines string[]
--- @param ext string|nil  -- extension WITHOUT the dot, e.g. "rs"
--- @return string|nil path
--- @return string|nil err
local function write_tempfile(lines, ext)
  local path = vim.fn.tempname()
  if ext ~= nil and ext ~= "" then
    path = path .. "." .. ext
  end
  if vim.fn.writefile(lines, path) ~= 0 then
    return nil, "difftsigns: could not write tempfile " .. path
  end
  return path, nil
end

--- @param old_path string
--- @param new_path string
--- @param opts table
--- @return string[]
local function build_cmd(cmd, old_path, new_path, opts)
  local args = { cmd, "--display", "json", "--color", "never" }

  if opts.lang ~= nil and opts.lang ~= "" then
    -- Blanket override: both paths are throwaway tempfiles.
    table.insert(args, "--override=*:" .. opts.lang)
  end

  if type(opts.graph_limit) == "number" then
    table.insert(args, "--graph-limit")
    table.insert(args, tostring(math.floor(opts.graph_limit)))
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
--- @param opts { lang?: string, filename?: string, difft_cmd?: string, language_overrides?: table, graph_limit?: number }
--- @param callback fun(err: string|nil, json_str: string|nil)
--- @return DifftSigns.Job|nil job  -- nil if spawn failed synchronously
function M.run(old_text, new_text, opts, callback)
  opts = opts or {}
  local cmd = opts.difft_cmd or "difft"

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
    vim.fn.delete(old_path)
    callback(new_err, nil)
    return nil
  end

  local function cleanup()
    vim.fn.delete(old_path)
    vim.fn.delete(new_path)
  end

  local cancelled = false
  local ok, proc = pcall(vim.system, build_cmd(cmd, old_path, new_path, opts), {
    text = true,
    -- --display json is gated behind DFT_UNSTABLE=yes.
    env = { DFT_UNSTABLE = "yes" },
  }, function(res)
    -- on_exit runs in libuv's fast context; the callback is not uv-safe.
    vim.schedule(function()
      cleanup()
      if cancelled then
        return
      end
      -- With --display json a successful run exits 0 or 1 ("files differ").
      -- 2 is the DFT_UNSTABLE gate.
      if res.code ~= 0 and res.code ~= 1 then
        callback("difftsigns: difft exited with code " .. res.code .. ": " .. (res.stderr or ""), nil)
        return
      end
      callback(nil, res.stdout or "")
    end)
  end)

  if not ok then
    cleanup()
    callback(("difftsigns: failed to spawn '%s' (is difftastic installed?): %s"):format(cmd, tostring(proc)), nil)
    return nil
  end

  return {
    cancel = function()
      if cancelled then
        return
      end
      cancelled = true
      pcall(proc.kill, proc, "sigterm")
    end,
  }
end

return M
