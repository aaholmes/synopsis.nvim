-- Minimal Neovim config for recording the README GIF (vhs demo/demo.tape, from the repo root).
-- Loads this repo, Telescope and a colour scheme, nothing personal. Summaries go to a fresh cache
-- each time, so the recording shows one being written.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.rtp:prepend(root)
for _, dep in ipairs { 'plenary.nvim', 'telescope.nvim', 'kanagawa.nvim' } do
  vim.cmd.packadd(dep)
end
vim.env.XDG_CACHE_HOME = vim.fn.tempname()

vim.g.mapleader = ' '
vim.o.termguicolors = true
vim.o.showmode = false
vim.o.swapfile = false
vim.o.laststatus = 0
vim.o.ruler = false
vim.cmd.colorscheme 'kanagawa'

require('telescope').setup {
  defaults = { dynamic_preview_title = true, layout_strategy = 'synopsis', layout_config = { width = 0.98, height = 0.96, preview_width = 0.55 } },
}
-- consent = 'always': the demo repo is public, so the recording skips the question about sending it.
require('synopsis').setup { background = root .. '/demo/background.md', consent = 'always' }
vim.keymap.set('n', '<leader>sf', require('telescope.builtin').find_files)
