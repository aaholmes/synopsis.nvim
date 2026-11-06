local H = dofile 'tests/harness.lua'
local mock = dofile 'tests/mock_llm.lua'

vim.o.columns, vim.o.lines = 160, 50
vim.env.WHATSTHIS_TEST_KEY = 'sk-test'
local server = mock.start 'Summary from the mock.'
local root = H.make_repo { ['a.lua'] = 'return "a"', ['b.lua'] = 'return "b"' }
vim.cmd.cd(root)

require('telescope').setup {}
local whatsthis = require 'whatsthis'
whatsthis.setup {
  llm = { url = server.url, model = 'mock-model', api_key_env = 'WHATSTHIS_TEST_KEY' },
  background = WHATSTHIS_ROOT .. '/tests/fixtures/background.md',
  delay_ms = 50, height = 6,
}
local actions = require 'telescope.actions'
local builtin = require 'telescope.builtin'

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= '' then
      local pad = (c.border and c.border ~= 'none' and #c.border > 0) and 2 or 0
      local b = vim.api.nvim_win_get_buf(w)
      table.insert(out, { win = w, ft = vim.b[b].whatsthis and 'whatsthis' or vim.bo[b].filetype, row = c.row, col = c.col, w = c.width + pad, h = c.height + pad })
    end
  end
  return out
end

local function find(ft)
  for _, f in ipairs(floats()) do
    if f.ft == ft then return f end
  end
end

local function prompt_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == 'TelescopePrompt' then return b end
  end
end

local function overlaps(a, b) return a.row < b.row + b.h and b.row < a.row + a.h and a.col < b.col + b.w and b.col < a.col + a.w end

local function open(opts)
  builtin.find_files(vim.tbl_extend('force', { layout_strategy = 'whatsthis', layout_config = { width = 0.95, preview_width = 0.75 } }, opts or {}))
  vim.wait(2000, function() return prompt_buf() ~= nil end, 10)
end

local function close()
  local b = prompt_buf()
  if b then actions.close(b) end
  vim.wait(1000, function() return prompt_buf() == nil end, 10)
  vim.wait(50)
end

local function pane_text()
  local f = find 'whatsthis'
  return f and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f.win), 0, -1, false), '\n')
end

local function check_geometry()
  local pane, results = find 'whatsthis', find 'TelescopeResults'
  H.eq(pane ~= nil, true, 'pane open')
  local rc = vim.api.nvim_win_get_config(results.win)
  H.eq(pane.w, rc.width + 2, 'pane outer width matches the results outer width')
  H.eq(pane.row < rc.row, true, 'pane above results')
  for _, f in ipairs(floats()) do
    if f.win ~= pane.win then H.eq(overlaps(pane, f), false, 'overlaps ' .. (f.ft ~= '' and f.ft or 'a border') .. ' window') end
  end
end

H.check('the pane sits above the results, overlapping no other window', function()
  open()
  vim.wait(2000, function() return find 'whatsthis' ~= nil end, 10)
  check_geometry()
end)

H.check('the pane shows the summary for the previewed file', function()
  vim.wait(3000, function() return (pane_text() or ''):find('Summary from the mock.', 1, true) ~= nil end, 10)
  H.eq((pane_text() or ''):find('Summary from the mock.', 1, true) ~= nil, true, 'pane text: ' .. tostring(pane_text()))
end)

H.check('the pane follows the layout when Neovim is resized', function()
  vim.o.columns = 120
  vim.cmd 'doautocmd VimResized'
  vim.wait(300)
  check_geometry()
end)

H.check('the pane closes with the picker', function()
  close()
  H.eq(find 'whatsthis', nil, 'pane')
end)

H.check('a picker using another layout gets no pane', function()
  open { layout_strategy = 'horizontal' }
  vim.wait(500)
  H.eq(find 'whatsthis', nil, 'pane')
  close()
end)

H.finish()
