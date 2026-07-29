# dft-signs

A Neovim plugin that drives [difftastic](https://github.com/Wilfred/difftastic)
to produce **structural** (syntax-aware) gutter signs — markers only on lines
that difftastic considers genuinely changed, not lines that merely reflowed or
got reindented.

If you wanted line-based markers you'd use gitsigns and go home. This is for
when you want to see *structural* change and nothing else.

## Features

- **Structural changed-line markers** (layer 1) — a sign only on buffer lines
  difftastic reports as genuinely changed.
- **Chunk-span markers** (layer 2) — a visually subdued sign spanning each
  difftastic *chunk* (logical change region), including the context lines
  inside it. Reads as "this whole region is one structural change."
- **Live, debounced updates** with a deliberately large interval (1.5s default).
- **Revision-agnostic core** — the same engine serves both "working buffer vs
  git ref" and "blob@base vs blob@head" (octo.nvim review mode).

## Requirements

- Neovim 0.10+ (uses `vim.system`, `vim.uv`, decoration providers).
- [difftastic](https://github.com/Wilfred/difftastic) (`difft`) on your `PATH`.
  Validated against **0.69.0**. The JSON output format is explicitly unstable;
  see below.

## Install (lazy.nvim)

```lua
{
  "you/dft-signs",
  config = function()
    require("dft-signs").setup({})
  end,
}
```

## Configuration

```lua
require("dft-signs").setup({
  difft_cmd      = "difft",            -- allow custom path / wrapper
  debounce_ms    = 1500,               -- large by design (see §5 of the spec)
  max_filesize   = 1024 * 1024,        -- match difft's byte-limit; skip beyond
  compare_base   = "index",            -- 'index'|'HEAD'|'save'|<revision>
  layers = {
    changed = { enable = true, text = "▌", hl = "DftSignsChange" },
    span    = { enable = true, text = "▏", hl = "DftSignsSpan"   },
  },
  language_overrides = {},              -- { ["*.foo"] = "javascript" }
  difft_version_expected = "0.69.0",    -- pin; warn on mismatch
  preview_context = 2,                  -- unchanged lines shown around each change in the preview
  on_attach = function(bufnr) end,      -- for buffer-local keymaps
})
```

### Example with keybinds

`on_attach` fires once per buffer we attach to, exactly like gitsigns'. Use it
for buffer-local mappings so the keys only exist where the plugin is active:

```lua
require("dft-signs").setup({
  on_attach = function(bufnr)
    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc })
    end

    map("<leader>ds", "<Cmd>DftSigns toggle_spans<CR>",   "dft-signs: toggle chunk spans")
    map("<leader>dc", "<Cmd>DftSigns toggle_changes<CR>", "dft-signs: toggle changed-line markers")
          map("<leader>dp", "<Cmd>DftSigns preview_span<CR>",   "dft-signs: preview span under cursor")
          map("<leader>dr", "<Cmd>DftSigns refresh<CR>",        "dft-signs: refresh now")

    -- Compare against different bases without leaving the buffer.
    map("<leader>dH", "<Cmd>DftSigns change_base HEAD<CR>",  "dft-signs: diff vs HEAD")
    map("<leader>dI", "<Cmd>DftSigns change_base index<CR>", "dft-signs: diff vs index")
  end,
})
```

## Commands

```
:DftSigns attach            attach to the current buffer
:DftSigns detach            detach from the current buffer
:DftSigns refresh           force an immediate update
:DftSigns toggle_spans      toggle layer 2 (chunk spans)
:DftSigns toggle_changes    toggle layer 1 (changed-line markers)
:DftSigns preview_span      preview the structural change under the cursor
:DftSigns change_base <rev> compare against an arbitrary revision
```

## octo.nvim review mode

The comparison core takes two arbitrary text arrays and knows nothing about git
or buffers, so review mode is a thin adapter:

```lua
require("dft-signs.octo").review(review_bufnr, base_text, head_text, {
  lang = "typescript",       -- optional
  filename = "src/foo.ts",   -- optional; used for difft language detection
})
```

## Why not gitsigns / mini.diff?

Both funnel everything through a **line-based** diff model. gitsigns' hunk type
and staging (`create_patch`) assume unified-diff semantics; mini.diff's `source`
contract is "text in, `vim.diff` out" and assumes one diff side *is* the
attached buffer. Either way, difftastic's per-line structural verdict is
destroyed — you'd be showing a line diff under a "structural" banner, which is a
lie. A custom decoration provider is the only thing that can render structural
markers and fit the revision-vs-revision review case. See `dft-signs` internal
docs / the design spec for the full argument.

## Running alongside gitsigns

**Yes — this is designed to run in parallel with gitsigns, not replace it.** The
two are additive:

- dft-signs owns its own extmark namespaces (`dft_signs_change`,
  `dft_signs_span`) and never touches gitsigns' state. gitsigns keeps its own
  namespaces and its default `sign_priority = 6`. Neither plugin reads or clears
  the other's marks. (Verified: gitsigns' signs remain untouched with dft-signs
  attached to the same buffer.)
- Think of it as two layers with different jobs: keep gitsigns for **line-based**
  hunks, staging (`stage_hunk`), blame, and preview — everything dft-signs
  deliberately does *not* do — and let dft-signs add the **structural** verdict
  on top.

### Previewing changes: span preview, not hunk preview

There is **no `<leader>hp` equivalent**, and that is deliberate. gitsigns'
preview works because a line-based hunk *is* a block of old text to show. A
difftastic chunk is a set of **token-level** changes scattered across lines that
may have reflowed — there is no honest "here are the N old lines this replaced"
to display. Faking one would be the exact line-based framing this plugin exists
to avoid (§2/§9).

Instead, `:DftSigns preview_span` (`<leader>xp` in the example config) previews
the **span under the cursor**: a float showing the **actual source lines** from
the reference (was) side and the buffer (now) side, with the changed tokens
highlighted in place. Changed lines are marked with `>`; a few unchanged lines
around each change are shown dimmed for context (configurable via
`preview_context`, default 2), so reorders and moves read correctly — you see
both lines that swapped, not a lone token stripped of its surroundings.

For a classic old-text block preview, use **gitsigns' `<leader>hp`** — it's
attached to the same buffer and a line-based preview is the right tool for
"show me the old text." Keep both: dft-signs tells you *which lines structurally
changed and what tokens*, gitsigns shows you *the old line block*.

### Required: use a **fixed-width** `signcolumn` (not `auto`)

**dft-signs' markers are invisible under `signcolumn=auto`.** This is the single
most important setting to get right, so it's first.

dft-signs places its signs *ephemerally* from a decoration provider (recomputed
per redraw, only for on-screen lines — see §6). Neovim's `auto` sign column
sizes itself from **non-ephemeral, placed** signs only; ephemeral decoration
signs don't count. So `auto` decides "no signs → no column," reserves zero
width, and dft-signs' markers render into a gutter that isn't there. You see
nothing, even though the diff ran correctly.

Use a fixed width instead:

```lua
vim.opt.signcolumn = "yes:2"   -- always reserve two sign columns
```

Two columns (rather than `yes:1`) also lets dft-signs coexist with gitsigns —
see below.

### Coexisting with gitsigns in the same gutter

With a single sign column, if a line has *both* a gitsigns sign and a dft-signs
sign, only one glyph fits, and dft-signs' higher extmark priority (span = 8,
change = 20, both above gitsigns' default 6) means **dft-signs wins the cell and
hides the gitsigns sign** on that line. `signcolumn = "yes:2"` gives each plugin
its own column, so both show.

If instead you'd rather gitsigns win contested cells, lower dft-signs' priority
below 6 — currently that means editing `PRIORITY_SPAN`/`PRIORITY_CHANGE` in
`signs.lua` (exposing these via `setup()` is a reasonable future addition).

## Known limitations

- **No staging.** Structural chunks can't round-trip through `git apply`. Out of
  scope, permanently — that's gitsigns/mini.diff's job on a line-based backend.
- **Latency.** We spawn difftastic (tree-sitter + graph diff) out of process. We
  are slower than any `vim.diff` gutter, by design. Mitigated with debounce +
  in-flight cancellation.
- **Schema fragility.** difftastic's `--display json` is gated behind
  `DFT_UNSTABLE=yes` and may change. All schema knowledge is quarantined in
  `core.lua`; a version mismatch warns loudly.
- **Language fallback.** For languages difftastic can't parse it falls back to a
  line diff (reported as `Text`). We detect this and **clear** signs rather than
  mislabel a line diff as structural.

## Development

```
make test
```

Runs the plenary test suite headlessly. Parser tests validate against real
difftastic fixtures in `tests/fixtures/` (captured from the actual binary, not
hand-written). Tests touching difft skip themselves if it isn't installed.

## Architecture

| Module        | Responsibility                                              |
|---------------|-------------------------------------------------------------|
| `core.lua`    | `run_diff` + **all** difftastic JSON parsing → `Region[]`   |
| `process.lua` | libuv spawn of difft with cancellation; temp files          |
| `signs.lua`   | decoration provider, 2 namespaces, extmark placement        |
| `attach.lua`  | buf watcher, debounce, reference-text resolution            |
| `git.lua`     | `git show <rev>:<path>`, `.git` watcher, cache               |
| `octo.lua`    | review-mode adapter feeding blob/blob into core             |
| `debounce.lua`| trailing debounce + async throttle                          |
| `config.lua`  | defaults + validation                                       |

The layering enforces one invariant: difftastic knowledge lives only in
`core.lua`/`process.lua`, git knowledge only in `git.lua`. Anything upstream
that changes touches exactly one file.
```
