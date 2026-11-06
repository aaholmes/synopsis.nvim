-- Minimal config for the headless tests: this repo, plenary and Telescope, nothing personal.
-- Dependencies are found with :packadd (e.g. installed by vim.pack), or under $WHATSTHIS_DEPS.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.rtp:prepend(root)
for _, dep in ipairs { 'plenary.nvim', 'telescope.nvim' } do
  if vim.env.WHATSTHIS_DEPS then
    vim.opt.rtp:prepend(vim.env.WHATSTHIS_DEPS .. '/' .. dep)
  else
    vim.cmd.packadd(dep)
  end
end
-- Keep the tests' cache out of the real one.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()
_G.WHATSTHIS_ROOT = root
-- A spec that hangs fails after a minute instead of blocking the run.
vim.defer_fn(function()
  io.write 'FAIL  spec timed out after 60 s\n'
  vim.cmd 'cq!'
end, 60000)
