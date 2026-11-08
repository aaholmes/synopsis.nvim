-- :SynopsisAsk and the ask settings in setup().
local H = dofile 'tests/harness.lua'
local mock = dofile 'tests/mock_llm.lua'

vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
local server = mock.start 'From the command.'
local root = H.make_repo { ['a.lua'] = 'return 1\n' }
vim.cmd.cd(root)
require('telescope').setup {}
local synopsis = require 'synopsis'
synopsis.setup {
  llm = { url = server.url, model = 'm', api_key_env = 'SYNOPSIS_TEST_KEY' },
  consent = 'always',
  ask = { max_rounds = 3, keymaps = { chat = '<C-u>' } },
}

H.check('ask settings merge with the defaults', function()
  local a = synopsis.config.ask
  H.eq(a.max_rounds, 3, 'override')
  H.eq(a.max_map_chars, 150000, 'default kept')
  H.eq(a.keymaps.chat, '<C-u>', 'key override')
  H.eq(a.render, true, 'render default')
  H.eq(synopsis.config.keymaps.ask, '<C-g>', 'Telescope key')
  H.eq(a.keymaps.locations, 'gl', 'key default kept')
end)

H.check(':SynopsisAsk with a question answers it about the current repo', function()
  vim.cmd 'SynopsisAsk What does a.lua return?'
  local answer = require 'synopsis.answer'
  vim.wait(3000, function() return answer.current and answer.current.pending == false and answer.current.asked end, 10)
  H.eq(answer.current.root, vim.fs.normalize(vim.fn.resolve(root)), 'root')
  local lines = table.concat(vim.api.nvim_buf_get_lines(answer.current.buf, 0, -1, false), '\n')
  H.eq(lines:find('From the command.', 1, true) ~= nil, true, lines)
  H.eq(lines:find('What does a.lua return?', 1, true) ~= nil, true, 'question')
  answer.close()
end)

H.check(':SynopsisAsk without a question opens an empty chat and sends nothing', function()
  local answer = require 'synopsis.answer'
  local before = #server.requests
  vim.cmd 'SynopsisAsk'
  vim.wait(300)
  H.eq(answer.current ~= nil and not answer.current.closed, true, 'open')
  H.eq(vim.api.nvim_get_current_win(), answer.current.input_win, 'input focused')
  H.eq(#server.requests, before, 'nothing sent')
  answer.close()
end)

H.finish()
