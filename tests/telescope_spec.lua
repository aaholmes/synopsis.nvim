local H = dofile 'tests/harness.lua'
local mock = dofile 'tests/mock_llm.lua'

vim.o.columns, vim.o.lines = 160, 50
vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
local long = { 'Summary from the mock.', '' }
for i = 1, 60 do long[#long + 1] = '- note ' .. i end
local server = mock.start(table.concat(long, '\n'))
local root = H.make_repo { ['a.lua'] = 'return "a"', ['b.lua'] = 'return "b"' }
vim.cmd.cd(root)

require('telescope').setup {}
local synopsis = require 'synopsis'
synopsis.setup {
  llm = { url = server.url, model = 'mock-model', api_key_env = 'SYNOPSIS_TEST_KEY' },
  background = SYNOPSIS_ROOT .. '/tests/fixtures/background.md',
  delay_ms = 50,
  consent = 'always',
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
      table.insert(out, { win = w, ft = vim.b[b].synopsis and 'synopsis' or vim.bo[b].filetype, row = c.row, col = c.col, w = c.width + pad, h = c.height + pad })
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
  builtin.find_files(vim.tbl_extend('force', { layout_strategy = 'synopsis', layout_config = { width = 0.95, preview_width = 0.75 } }, opts or {}))
  vim.wait(2000, function() return prompt_buf() ~= nil end, 10)
end

local function close()
  local b = prompt_buf()
  if b then actions.close(b) end
  vim.wait(1000, function() return prompt_buf() == nil end, 10)
  vim.wait(50)
end

local function pane_text()
  local f = find 'synopsis'
  return f and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f.win), 0, -1, false), '\n')
end

local function check_geometry()
  local pane, results = find 'synopsis', find 'TelescopeResults'
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
  vim.wait(2000, function() return find 'synopsis' ~= nil end, 10)
  check_geometry()
end)

H.check('the pane shows the summary for the previewed file', function()
  vim.wait(3000, function() return (pane_text() or ''):find('Summary from the mock.', 1, true) ~= nil end, 10)
  H.eq((pane_text() or ''):find('Summary from the mock.', 1, true) ~= nil, true, 'pane text: ' .. tostring(pane_text()))
end)

H.check('the pane is titled Synopsis and is taller than the results under it', function()
  local pane, results = find 'synopsis', find 'TelescopeResults'
  local title = vim.api.nvim_win_get_config(pane.win).title
  H.eq(title and title[1] and vim.trim(title[1][1]), 'Synopsis', 'title')
  H.eq(pane.h - 2 > results.h, true, string.format('pane %d lines, results %d', pane.h - 2, results.h))
end)

local function topline() return vim.fn.getwininfo(find('synopsis').win)[1].topline end

H.check('Ctrl-e and Ctrl-y scroll the synopsis from the prompt, in Insert and Normal mode', function()
  H.eq(topline(), 1, 'starts at the top')
  for _, mode in ipairs { 'i', 'n' } do
    local down = vim.fn.maparg('<C-e>', mode, false, true)
    local up = vim.fn.maparg('<C-y>', mode, false, true)
    H.eq(down.buffer, 1, mode .. ' <C-e> is mapped in the prompt')
    down.callback()
    H.eq(topline() > 1, true, mode .. ' scrolled down')
    up.callback()
    H.eq(topline(), 1, mode .. ' scrolled back up')
  end
end)

-- Headless Neovim has no screen for wheel events to land on, so this checks the setting the wheel
-- needs: it skips windows that cannot take focus, as Telescope's results and preview can.
H.check('the pane draws notes as dots', function()
  H.eq((pane_text() or ''):find('• note 1', 1, true) ~= nil, true, 'dot')
end)

H.check('the pane can take focus, so the mouse wheel scrolls it', function()
  H.eq(vim.api.nvim_win_get_config(find('synopsis').win).focusable, true, 'focusable')
end)

H.check('Ctrl-a in the prompt allows the repo and Ctrl-o turns synopses off', function()
  local consent = require 'synopsis.consent'
  for _, mode in ipairs { 'i', 'n' } do
    H.eq(vim.fn.maparg('<C-a>', mode, false, true).buffer, 1, mode .. ' <C-a> mapped')
    H.eq(vim.fn.maparg('<C-o>', mode, false, true).buffer, 1, mode .. ' <C-o> mapped')
  end
  vim.fn.maparg('<C-o>', 'i', false, true).callback()
  H.eq(consent.get(root), 'deny', 'denied')
  vim.fn.maparg('<C-a>', 'i', false, true).callback()
  H.eq(consent.get(root), 'allow', 'allowed')
end)

H.check('the pane follows the layout when Neovim is resized', function()
  vim.o.columns = 120
  vim.cmd 'doautocmd VimResized'
  vim.wait(300)
  check_geometry()
end)

H.check('the pane closes with the picker', function()
  close()
  H.eq(find 'synopsis', nil, 'pane')
end)

H.check('a picker using another layout gets no pane and no ask key', function()
  open { layout_strategy = 'horizontal' }
  vim.wait(500)
  H.eq(find 'synopsis', nil, 'pane')
  H.eq(vim.fn.maparg('<C-g>', 'i', false, true).buffer, nil, 'no <C-g>')
  close()
end)

H.check('the prompt keys are mapped even when no preview is shown', function()
  open { previewer = false }
  vim.wait(300)
  H.eq(vim.fn.maparg('<C-g>', 'i', false, true).buffer, 1, '<C-g> mapped')
  close()
end)

H.check('<C-g> in the prompt opens the chat about the selected file; closing it reopens the picker', function()
  local answer = require 'synopsis.answer'
  open()
  vim.wait(1000, function() return find 'synopsis' ~= nil end, 10)
  local entry = require('telescope.actions.state').get_selected_entry()
  local name = vim.fs.basename(entry.path or entry.filename or entry.value)
  vim.fn.maparg('<C-g>', 'i', false, true).callback()
  vim.wait(2000, function() return answer.current ~= nil and not answer.current.closed end, 10)
  H.eq(prompt_buf(), nil, 'picker closed')
  H.eq(answer.current.about.path, name, 'about the selected file')
  local hint = table.concat(vim.api.nvim_buf_get_lines(answer.current.buf, 0, -1, false), '\n')
  H.eq(hint:find('Asking about `' .. name .. '`', 1, true) ~= nil, true, hint)
  answer.close()
  vim.wait(2000, function() return prompt_buf() ~= nil end, 10)
  H.eq(prompt_buf() ~= nil, true, 'picker reopened')
  vim.wait(1000, function() return find 'synopsis' ~= nil end, 10)
  H.eq(find 'synopsis' ~= nil, true, 'pane back')
  H.eq(vim.fn.maparg('<C-g>', 'i', false, true).buffer, 1, '<C-g> mapped again')
  vim.fn.maparg('<C-g>', 'i', false, true).callback()
  vim.wait(2000, function() return answer.current ~= nil and not answer.current.closed end, 10)
  H.eq(prompt_buf(), nil, 'second chat opened')
  answer.close()
  vim.wait(2000, function() return prompt_buf() ~= nil end, 10)
  close()
end)

H.check('Ctrl-g on another file continues the same conversation', function()
  local answer = require 'synopsis.answer'
  answer.sessions = {}
  open()
  vim.wait(1000, function() return find 'synopsis' ~= nil end, 10)
  vim.fn.maparg('<C-g>', 'i', false, true).callback()
  vim.wait(2000, function() return answer.current ~= nil and not answer.current.closed end, 10)
  answer.send 'First question?'
  vim.wait(3000, function() return answer.current.pending == false end, 10)
  answer.close()
  vim.wait(2000, function() return prompt_buf() ~= nil end, 10)
  require('telescope.actions').move_selection_next(prompt_buf())
  vim.wait(300)
  vim.fn.maparg('<C-g>', 'i', false, true).callback()
  vim.wait(2000, function() return answer.current ~= nil and not answer.current.closed end, 10)
  local t = table.concat(vim.api.nvim_buf_get_lines(answer.current.buf, 0, -1, false), '\n')
  H.eq(t:find('First question?', 1, true) ~= nil, true, t)
  H.eq(t:find('Now viewing', 1, true) ~= nil, true, 'new file noted')
  answer.close()
  vim.wait(2000, function() return prompt_buf() ~= nil end, 10)
  close()
end)

H.finish()
