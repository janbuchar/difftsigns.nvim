# Changelog

## [Unreleased]

### Features

- Initial PoC
- Reworked UX
- Allow keeping hunk preview open when browsing hunks
- Use the same syntax highlighting as the buffer
- Make whole-line additions/deletions more legible
- Make the preview follow the cursor across hunks
- Hand over to gitsigns' preview when there is no structural verdict
- Make the difftsigns popup focusable for scrolling

### Bug Fixes

- Various bugfixes
- Fix non-structural diff detection
- Prevent unanchoring the preview window on zz/zt/zb
- Do not show surviving tokens as deleted
- Do not glue hunks across the unchanged line above a delete anchor
- Improve preview window behavior

### Documentation

- Remove fluff from docs
- Update readme and agents
- Add a demo gif
- Add vimdoc
- Compare to existing plugins
- Reduce readme slop
