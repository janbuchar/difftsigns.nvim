-- Minimal init for headless test runs. Puts this plugin, plenary, and gitsigns
-- on the runtimepath and nothing else, so tests are hermetic.
--
-- gitsigns is included because it is a HARD dependency of this plugin, not an
-- optional integration: difftsigns only ever demotes cells gitsigns drew. A test
-- suite that stubbed it out would be testing a plugin nobody can run.

local data = vim.fn.stdpath("data")

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(data .. "/lazy/plenary.nvim")
vim.opt.runtimepath:append(data .. "/lazy/gitsigns.nvim")

vim.cmd("runtime plugin/plenary.vim")

-- Deterministic environment for screen-grid assertions and git invocations.
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"
vim.env.GIT_AUTHOR_NAME = "difftsigns tests"
vim.env.GIT_AUTHOR_EMAIL = "tests@example.invalid"
vim.env.GIT_COMMITTER_NAME = "difftsigns tests"
vim.env.GIT_COMMITTER_EMAIL = "tests@example.invalid"
