vim.opt.runtimepath:prepend("/plugin")
vim.opt.runtimepath:prepend("/opt/gitsigns.nvim")
vim.opt.runtimepath:prepend("/opt/nightfox.nvim")

vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.showmode = false
vim.o.ruler = false
vim.o.laststatus = 0
vim.o.cmdheight = 1
vim.cmd.colorscheme("nordfox")

require("gitsigns").setup({
  update_debounce = 50,
  signs = { add = { text = "▎" }, change = { text = "▎" } },
})
require("difftsigns").setup({ debounce_ms = 50 })
