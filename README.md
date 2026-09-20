# difftsigns.nvim

**Dims the formatting noise in your gitsigns gutter so the real changes stand out.**

You reindent a block, run prettier, or wrap something in a conditional. gitsigns
lights up twelve lines. Two of them actually changed.

difftsigns asks [difftastic](https://github.com/Wilfred/difftastic) which of those
lines changed *structurally* and dims the rest — in the same column, with the same
glyphs, using your existing `]c` navigation.

```
 gitsigns alone          with difftsigns
 ──────────────          ───────────────
 ▎ function run() {      ▎ function run() {
 ▎   if (enabled) {      ▎   if (enabled) {     <- real: new structure
 ▎     doThing();        ▏     doThing();       <- dimmed: only reindented
 ▎     doOther();        ▏     doOther();       <- dimmed
 ▎     return 1;         ▏     return 1;        <- dimmed
 ▎   }                   ▎   }                  <- real: new structure
 ▎ }                     ▎ }
```

It adds **no gutter column**, **no navigation bindings**, and **no new mental
model**. It changes the colour of things you were already looking at.

## Requirements

- Neovim 0.11+
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) — **required**, not
  optional (see [How it works](#how-it-works))
- [difftastic](https://github.com/Wilfred/difftastic) `0.70.0` on `PATH`

## Install

```lua
-- lazy.nvim
{
  "difftsigns.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  opts = {},
}
```

That's it. No `signcolumn` gymnastics required — the column is gitsigns'.

## Configuration

Defaults shown; all keys optional.

```lua
require("difftsigns").setup({
  difft_cmd      = "difft",       -- path to, or wrapper around, difftastic
  debounce_ms    = 400,           -- measured, not guessed (see below)
  max_filesize   = 1024 * 1024,   -- matches difft's own --byte-limit
  noise_hl       = "DifftSignsNoise",  -- highlight for demoted cells
  noise_text     = nil,           -- nil = mirror gitsigns' glyph; set a string to override
  priority_offset = 1,            -- added to gitsigns' sign_priority to win the cell
  graph_limit    = nil,           -- difft --graph-limit; nil = difft's default (3,000,000)
  language_overrides = {},        -- { ["*.foo"] = "javascript" }
  difft_version_expected = "0.70.0",
  on_attach = function(bufnr) end,
})
```

`debounce_ms = 400` is derived from measurement, not taste: with difftastic
0.69.0 a realistic single-token edit costs ~41 ms on a 1145-line TypeScript file
and ~200–330 ms on a 6045-line one.

### `graph_limit`, or "why does it do nothing on this file?"

difftastic abandons the structural diff when its internal graph exceeds
`--graph-limit` vertices and returns a **line diff** instead. difftsigns refuses to
render that (it would mark every token on every changed line, spaces included), so
you get plain gitsigns and `:DifftSigns status` says so.

Measured on a 708-line TypeScript test file with ~50 changed lines:

| `graph_limit` | outcome | time |
|---|---|---|
| 100,000 | gave up | 0.4 s |
| 1,000,000 | gave up | 2.6 s |
| **3,000,000** (difft default) | **gave up** | **7.9 s** |
| 5,000,000 | structural diff | 7.7 s |

Note the shape of that: at the default, difftastic spends eight seconds and then
tells you nothing. Raising the limit buys real answers on heavily-changed files for
no more time than failing slowly cost; lowering it makes hopeless cases fail fast
and cheap. Both are reasonable, so this is a knob rather than a decision made for
you. Raising it also increases peak memory.

### Highlight groups

| Group | Default | Purpose |
|---|---|---|
| `DifftSignsNoise` | links `NonText` | demoted (formatting-only) gutter cells |
| `DifftSignsAdded` | links `Added` | the preview's `+` sign marker (green) |
| `DifftSignsRemoved` | links `Removed` | the preview's `-` sign marker (red) |
| `DifftSignsAddedBg` | links `DiffAdd` | added-token **background** in the preview |
| `DifftSignsRemovedBg` | links `DiffDelete` | removed-token **background** in the preview |
| `DifftSignsContext` | links `Comment` | reflow-only lines in the preview |

The sign markers link `Added`/`Removed` rather than `DiffAdd`/`DiffDelete` on
purpose: the latter are diff-*mode* groups and are background-only in most
colourschemes (nightfox renders them as `#3c4548` and `#403843` — two
indistinguishable dark greys), useless for telling an addition from a removal.
The token *backgrounds* are the opposite case: they sit behind syntax-highlighted
source, so a background-only group is exactly what's wanted, and `DiffAdd`/
`DiffDelete` are precisely that.

The plugin's entire visual design is `DifftSignsNoise`. If dimming is too subtle
or too strong in your colourscheme, that's the knob.

## The preview

`require("difftsigns").preview()` shows the change under the cursor in gitsigns'
familiar shape — removed lines, then added lines — with two things gitsigns can't
show: the **exact changed tokens** highlighted, and the reflow-only lines
**dimmed**, plus a header quantifying the split.

The source lines are shown **verbatim and syntax-highlighted just like the buffer
they came from** — the `-`/`+` markers live in the sign column, not inline, so the
highlighter parses clean lines. Change emphasis is therefore a **red/green
background** behind the changed tokens rather than a foreground colour, so it
stands out without fighting the syntax colours underneath.

**A one-sided change shows one side.** If every token difftastic reported lives on
one side, the other side is dead weight, so it isn't printed — the header says
`· additions only` or `· deletions only`. In practice this collapses most hunks by
half:

```
git:                                    difftsigns:
-import type { IConcurrencySystem }     change @@ -7,1 +7,1 @@ · additions only
      from './concurrency_system.js';  +│ import type { ConcurrencyConsumer,
+import type { ConcurrencyConsumer,      │     IConcurrencySystem } from './...';
      IConcurrencySystem } from './...   ^^^^^^^^^^^^^^^^^^^ green background
```

(The `+` sits in the sign column; the source keeps its syntax colours.)

A formatting-only hunk keeps both sides — there's no relevant part to pick, and
seeing the reflow is the point. So does a hunk whose sides differ in line count
with all the tokens on the removed side: the added side is the only place the
result appears, and "the old line minus the red tokens" stops being readable once
six import lines collapse onto one.

**Only the changed tokens are washed, not the whole line** — a green background
for added, red for removed, over the syntax-highlighted source. Once difftastic
has told us precisely which tokens changed, a whole-line wash is worse than
redundant: it competes with the token highlight for attention. Lines that were
only reformatted stay dimmed, matching the gutter. A whole-line wash is left for
the cases with no tokens to prefer: a brand-new or deleted file, and lines that
exist on one side of the contiguous run only.

It previews the whole **contiguous run** of hunks, not one hunk. gitsigns computes
hunks at zero context and (with `diff_opts.linematch`) can split a single logical
edit into several adjacent ones, so keying the preview to one hunk would show
different content on different lines of one unbroken block of signs. The header
discloses when hunks were merged, e.g. `add+change @@ -363,1 +363,6 @@ (2 hunks)`.

Bind it *instead of* `gitsigns.preview_hunk`:

```lua
vim.keymap.set("n", "<leader>hp", require("difftsigns").preview)
```

### Advancing the preview with `]c`

The preview dismisses when the cursor leaves the hunk, like gitsigns' own popup.
To make `]c` *advance* the preview to the next hunk — keeping it open, the way
gitsigns does with its own preview — re-show it once the jump lands.
`gitsigns.nav_hunk` is async and takes a callback that fires after the cursor has
moved (a bare `vim.schedule` races it), and `preview_is_open()` says whether a
preview was up to begin with:

```lua
local gs = require("gitsigns")

local function nav(direction)
  return function()
    local ok, dts = pcall(require, "difftsigns")
    local reopen = ok and dts.preview_is_open()
    gs.nav_hunk(direction, {}, function()
      if reopen then
        dts.preview()
      end
    end)
  end
end

vim.keymap.set("n", "]c", nav("next"))
vim.keymap.set("n", "[c", nav("prev"))
```

## Commands

```
:DifftSigns preview    -- hunk preview with structural detail
:DifftSigns toggle     -- turn the overlay off to see plain gitsigns again
:DifftSigns refresh    -- force a re-diff
:DifftSigns status     -- report the noise/real split, or why there's no overlay
:DifftSigns attach | detach
```

Statusline component:

```lua
require("difftsigns").status()   -- "difft: 3 noise / 2 real", or nil
```

## How it works

difftsigns **borrows** all of its geometry:

| Thing | Source |
|---|---|
| Hunk boundaries | gitsigns |
| Reference text (the "before") | gitsigns |
| Base revision | gitsigns (follows its `change_base` automatically) |
| Sign glyphs and priority | gitsigns |
| Which lines *really* changed | difftastic |

For every gutter cell gitsigns drew on a line difftastic considers formatting
noise, difftsigns places its own sign in the *same cell* at a higher extmark
priority, with gitsigns' glyph and a dim highlight. One column, one set of
shapes, one navigation model.

Two rules govern the whole plugin:

1. **It subtracts emphasis; it never adds it.** Every cell it touches is a cell
   gitsigns already drew. It will never mark a line gitsigns left alone.
2. **When in doubt, it does nothing.** A missing overlay is a cosmetic
   disappointment. A wrong overlay hides a real change. Every ambiguity resolves
   toward leaving the cell lit.

Because of rule 2, the failure mode is *"the plugin isn't installed"*: if
difftastic is missing, errors, times out, hits the size limit, or can't parse the
language, you get plain, unmodified gitsigns. Run `:DifftSigns status` or
`:checkhealth difftsigns` to find out why.

## What it catches, and what it doesn't

Verified against Difftastic 0.70.0:

| Change | Result |
|---|---|
| Reindent / reformat | fully dimmed ✓ |
| Prettier-style rewrap (incl. added trailing comma) | fully dimmed ✓ |
| Wrap a block in `if` | new lines lit, reindented body dimmed ✓ |
| Variable rename | lit, exact tokens marked ✓ |
| Genuine deletion | lit ✓ |
| Removed blank lines | dimmed ✓ |
| Reindent + argument removed from a call | line stays lit, removed token marked ✓ |
| Reindent + value changed | line stays lit, changed token marked ✓ |
| **Moved / reordered code** | **stays lit — see below** |

**Moved code is not detected.** difftastic 0.70 has no move detection: a
reordered function is reported as a deletion plus an addition with every token
changed. difftsigns therefore leaves it fully lit. That is the safe direction to
fail — nothing real is ever hidden — but it does mean a reorder looks exactly as
noisy as it does today.

### Other limitations

- **Staged hunks are not annotated.** gitsigns diffs those against a different
  base, which would need a second difftastic run.
- **Unsupported languages get nothing.** difftastic falls back to a line diff for
  those; presenting that as a structural verdict would be a lie, so we stand down.
- **Heavily-changed files may exceed difftastic's graph limit** and fall back the
  same way. See [`graph_limit`](#graph_limit-or-why-does-it-do-nothing-on-this-file).
- **No staging.** Structural changes don't round-trip through `git apply`.
  gitsigns already does staging correctly, and it's right there.
- **Two of the four things read from gitsigns are internal APIs**
  (`gitsigns.cache`, `gitsigns.hunks.calc_signs`). If a gitsigns update moves
  them, difftsigns goes inert and says so via `:checkhealth` rather than
  rendering something wrong.

## Development

```sh
make test
```

118 tests: fixture-driven parsing (every fixture is captured real difft output),
the pure verdict join, on-screen gutter assertions via `screenstring`, and
end-to-end tests against a real git repo, real gitsigns, and the real difft
binary.

Design history lives in `REDESIGN.md` (current), with `INITIAL_DESIGN.md` and
`IMPLEMENTATION.md` kept as the record of an earlier, different plugin that drew
its own gutter — and why that turned out to be the wrong idea.
