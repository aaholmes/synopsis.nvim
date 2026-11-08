-- The :SynopsisAsk window: progress lines, the answer, opening cited locations, closing, and
-- the consent question. Uses the mock chat endpoint.
local H = dofile 'tests/harness.lua'
local mock = dofile 'tests/mock_llm.lua'
local answer = require 'synopsis.answer'
local consent = require 'synopsis.consent'

vim.o.columns, vim.o.lines = 160, 50
vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
require('telescope').setup {}

local function call(id, name, args)
  return { id = id, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local function tool_reply(...) return { message = { role = 'assistant', content = vim.NIL, tool_calls = { ... } } } end

local function config(server, over)
  return vim.tbl_deep_extend('force', {
    llm = { url = server.url, model = 'm', api_key_env = 'SYNOPSIS_TEST_KEY', params = {}, timeout_ms = 5000 },
    consent = 'always', exclude = { '.env' }, max_bytes = 100 * 1024,
    ask = { max_rounds = 4, max_map_chars = 150000, retry_ms = 10,
      keymaps = { close = { 'q', '<Esc>' }, open = '<CR>', locations = 'gl', follow_up = 'a' } },
  }, over or {})
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(answer.current.buf, 0, -1, false), '\n') end
local function has(part) return answer.current and vim.api.nvim_buf_is_valid(answer.current.buf) and text():find(part, 1, true) ~= nil end
local function done() return answer.current and answer.current.result ~= nil end
local function reset()
  if answer.current and vim.api.nvim_win_is_valid(answer.current.win) then answer.close() end
  vim.cmd 'silent! only'
  vim.cmd 'enew!'
end

local repo = H.make_repo {
  ['a.lua'] = '-- Says hi.\nlocal M = {}\nfunction M.hi() return "hi" end\nreturn M\n',
  ['b.lua'] = 'return 2\n',
  ['.env'] = 'KEY=1\n',
}

H.check('the window shows each tool call as it starts, then the answer', function()
  reset()
  local server = mock.start({ tool_reply(call('c1', 'rg', { pattern = 'hi' })), 'It is in a.lua:3.' }, { delay_ms = 200 })
  answer.ask { root = repo, question = 'Where is hi?', config = config(server) }
  H.eq(vim.api.nvim_win_get_config(answer.current.win).relative ~= '', true, 'floating')
  vim.wait(3000, function() return has 'Searching `hi`' end, 10)
  H.eq(has 'Searching `hi`', true, text())
  vim.wait(3000, done, 10)
  H.eq(has 'It is in a.lua:3.', true, text())
  H.eq(has 'Where is hi?', true, 'question shown')
  H.eq(has '1 tool call', true, 'footer')
end)

H.check('the map sent to the model lists the files, and excluded files by path only', function()
  reset()
  local server = mock.start 'Answer.'
  answer.ask { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, done, 10)
  local user = server.requests[1].body.messages[2].content
  if type(user) == 'table' then user = user[1].text .. user[2].text end
  H.eq(user:find('a.lua: Says hi. Defines: M.hi', 1, true) ~= nil, true, user)
  H.eq(user:find('.env: (excluded)', 1, true) ~= nil, true, 'excluded')
  H.eq(user:find('KEY=1', 1, true), nil, 'no secret')
  H.eq(vim.endswith(user, 'QUESTION: Q?'), true, 'question last')
end)

H.check('<CR> on a path:line citation opens that file at that line', function()
  reset()
  local server = mock.start 'The function is at a.lua:3 in the repo.'
  answer.ask { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, done, 10)
  local lines = vim.api.nvim_buf_get_lines(answer.current.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    local col = l:find('a.lua:3', 1, true)
    if col then vim.api.nvim_win_set_cursor(answer.current.win, { i, col + 1 }) end
  end
  vim.api.nvim_feedkeys(vim.keycode '<CR>', 'x', false)
  H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), 'a.lua', 'file')
  H.eq(vim.api.nvim_win_get_cursor(0)[1], 3, 'line')
end)

H.check('citations: distinct existing path:line pairs, ranges by their first line, in order', function()
  local got = answer.citations('See `a.lua:3`, b.lua:1-2 and a.lua:3 again; c.lua:9 does not exist; also a.lua.', repo)
  H.eq(#got, 2, 'count')
  H.eq(got[1].path .. ':' .. got[1].line, 'a.lua:3', 'first')
  H.eq(got[2].path .. ':' .. got[2].line, 'b.lua:1', 'second')
end)

H.check('gl opens a Telescope picker of the cited locations', function()
  reset()
  local server = mock.start 'See a.lua:3 and b.lua:1.'
  answer.ask { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, done, 10)
  vim.api.nvim_set_current_win(answer.current.win)
  vim.api.nvim_feedkeys('gl', 'x', false)
  local prompt
  vim.wait(2000, function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == 'TelescopePrompt' then prompt = b end
    end
    return prompt ~= nil
  end, 10)
  H.eq(prompt ~= nil, true, 'picker open')
  require('telescope.actions').close(prompt)
end)

H.check('q closes the window and cancels the request in flight', function()
  reset()
  local server = mock.start({ tool_reply(call('c1', 'read', { path = 'a.lua' })), 'Late.' }, { delay_ms = 300 })
  answer.ask { root = repo, question = 'Q?', config = config(server) }
  local win = answer.current.win
  vim.wait(100)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys('q', 'x', false)
  H.eq(vim.api.nvim_win_is_valid(win), false, 'closed')
  vim.wait(1000)
  H.eq(#server.requests <= 1, true, 'no further request')
end)

H.check('a follow-up question is answered below the first answer', function()
  reset()
  local server = mock.start { 'First.', 'Second.' }
  answer.ask { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(3000, done, 10)
  answer.follow_up 'Q2?'
  vim.wait(3000, function() return has 'Second.' end, 10)
  H.eq(has 'First.' and has 'Q2?' and has 'Second.', true, text())
end)

H.check('a repo marked deny sends nothing and opens no window', function()
  reset()
  local server = mock.start 'A.'
  local r = H.make_repo { ['x.lua'] = 'return 1\n' }
  consent.set(r, 'deny')
  answer.current = nil
  answer.ask { root = r, question = 'Q?', config = config(server, { consent = 'ask' }) }
  vim.wait(300)
  H.eq(answer.current, nil, 'no window')
  H.eq(#server.requests, 0, 'nothing sent')
end)

H.check('an undecided repo asks first; allowing records it and sends', function()
  reset()
  local server = mock.start 'A.'
  local r = H.make_repo { ['x.lua'] = 'return 1\n' }
  local orig = vim.ui.select
  local asked
  vim.ui.select = function(items, opts, cb) asked = opts.prompt; cb(items[1]) end
  answer.ask { root = r, question = 'Q?', config = config(server, { consent = 'ask' }) }
  vim.ui.select = orig
  vim.wait(3000, done, 10)
  H.eq(type(asked), 'string', 'asked')
  H.eq(consent.get(r), 'allow', 'recorded')
  H.eq(#server.requests, 1, 'sent')
end)

H.check('a folder that is not a git repo works too', function()
  reset()
  local server = mock.start 'A.'
  local dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile({ '-- Plain.' }, dir .. '/p.lua')
  answer.ask { root = dir, question = 'Q?', config = config(server) }
  vim.wait(3000, done, 10)
  local user = server.requests[1].body.messages[2].content
  if type(user) == 'table' then user = user[1].text .. user[2].text end
  H.eq(user:find('p.lua: Plain.', 1, true) ~= nil, true, user)
end)

H.finish()
