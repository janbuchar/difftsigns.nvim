-- Minimal init for headless test runs. Puts this plugin and plenary on the
-- runtimepath and nothing else, so tests are hermetic.

local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(plenary)

vim.cmd("runtime plugin/plenary.vim")
