# difftsigns.nvim — notes for agents

Structural-significance annotator for gitsigns: reads gitsigns' hunks and reference
text, asks difftastic which lines changed structurally, dims the rest in gitsigns'
own gutter cells. User-facing behaviour is in `README.md`; this file is what you
need to not break it.

## Test

```sh
make test
```

Headless plenary. Needs `difft` (pinned `0.70.0`, see `config.lua`) and gitsigns
on the runtimepath (`tests/minimal_init.lua`). Fixtures under `tests/fixtures/`
are captured real difft output — never hand-edit them; recapture.

## Rules

- **Subtract emphasis, never add it.** Only cells gitsigns drew may be touched.
  Never place a sign on a line gitsigns left alone.
- **When in doubt, do nothing.** A missing overlay is cosmetic; a wrong overlay
  hides a real change. Every ambiguity resolves toward leaving the cell lit, and
  a line diff must never be presented as a structural verdict.
- **The hunk is borrowed, not re-modelled.** `Verdict.hunk` is gitsigns' table
  passed through; read fields off it, never copy it into a type of our own.

## Layout and boundaries

- `core.lua` is the only file that knows difftastic's JSON schema.
- `gitsigns.lua` is the only file that knows gitsigns' API. It uses internals
  (`gitsigns.cache`, `gitsigns.hunks.calc_signs`); every access is wrapped and a
  missing piece makes the plugin go inert, not wrong.
- `verdict.lua` is pure: hunks and difft output in, `Verdict[]` out. No vim API,
  no IO, no subprocess. Keep it that way — it is where the hard logic lives and
  must stay the cheapest file to test.
- `process.lua` spawns difft (`vim.system`), owns tempfiles and cancellation.
- `attach.lua` is driven by `User GitSignsUpdate`, not `nvim_buf_attach`. It
  captures `changedtick` before the run and drops the result if it moved.

## Things paid for in debugging time

- difftastic's JSON line numbers are 0-based; `core.lua` normalises to 1-based.
- `unchanged`/`created`/`deleted` statuses omit `chunks` entirely.
- `--display json` needs `DFT_UNSTABLE=yes`; exit codes 0 and 1 are both success.
- Tempfiles must carry the source extension or difft reports `Text`.
- Fallback is detected by the `exceeded DFT_*` substring, never the whole
  language string, plus a shape check: a whitespace-only token outside a
  `comment`/`string` atom means a line diff wearing a language label.
- `changed_lhs` and `changed_rhs` are two views of one aligned position. A token
  change on either side lights the line on both, or a deleted argument on a
  reindented line gets dimmed.
- Ephemeral extmarks do not render `sign_text`. All signs are real extmarks.
- `nvim_buf_set_extmark` defaults `priority` to 4096 and precedence is by
  priority alone, never placement order. Always set it explicitly.
- The preview renders the contiguous *group* of hunks (`verdict.group_at_line`),
  because linematch can split one edit into adjacent hunks. A zero-count hunk
  side is an insertion point, not a line; only counted sides set a range start,
  and a delete anchored at L is adjacent to L and L+1 but *not* to L-1 — line L
  is unchanged, and gitsigns' greedy `]c` treats that as a hunk boundary. Get
  this wrong and the preview shows different content depending on which line of
  one unbroken run of signs you ask from.
- Which hunk a line resolves to is ownership first, the delete's L+1 only as a
  fallback: two deletes one line apart both claim the line between them, and it
  belongs to the one anchored on it — the sign drawn there, and what gitsigns'
  `find_hunk` (`added.start <= lnum <= vend`, `vend == added.start` for a
  delete) returns. The L+1 fallback exists for topdeletes, whose sign gitsigns
  places one row down.
- The float is transient: the next cursor move or `<Esc>` closes it; a second
  `show()` focuses it instead (gitsigns' `preview_hunk` does the same with
  `popup.focus_open`), which is the only way to scroll a clipped hunk. A
  CursorMoved landing on the anchor position is ignored, because gitsigns'
  async `nav_hunk` emits those after it jumps. The source buffer's `<Esc>`
  mapping is restored on close; the float's own `q`/`<Esc>` die with its
  scratch buffer. Because focusing is legitimate, leaving is judged on
  `WinEnter`/`BufEnter` by where the cursor ended up, never on `BufLeave`.
- A jump onto another hunk re-shows instead of closing, and a jump is detected
  by the `'` mark: `nav_hunk` runs `normal! m'` before moving, so the mark holds
  the anchor position (verified: `{0, 3, 1, 0}` after a `]c` from line 3), while
  plain motion never touches it. The mark is also compared against its value at
  open, so one that already sat on the anchor cannot fake a jump.
- CursorMoved and WinScrolled are dispatched from the main loop, which a script
  never reaches: tests and smoke scripts must fire them themselves.
- The float is anchored with `bufpos`; `geometry()` picks the side with more
  room and sizes the height to it (a fixed cap either wastes a tall terminal or
  eats the tail), and `WinScrolled` re-runs it. What is off the bottom is
  counted in the border footer, recomputed from `line("w$")` when the float
  itself scrolls so the count never outlives the lines it names.
- gitsigns' `greedy` hunk mode, own `git show`/`vim.diff`, and reading gitsigns'
  placed extmarks were all rejected: each yields a second hunk set that can
  diverge from the one rendered.

## Tests

Assert the observable outcome, not bookkeeping: `screenstring` for the gutter,
extmark queries for the preview, a real repo + real gitsigns + real difft for
integration. `attach.lua` gets tests like everything else, and errors are
surfaced, not swallowed.
