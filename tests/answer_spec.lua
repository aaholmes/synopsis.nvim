-- The :SynopsisAsk chat: a conversation window with an input panel below it, progress lines,
-- answers, opening cited locations, closing, rendering hooks and the consent question. Uses the
-- mock chat endpoint.
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
    ask = { max_rounds = 4, max_map_chars = 150000, retry_ms = 10, render = true, preview = true, preview_min_columns = 120,
      keymaps = { close = { 'q', '<Esc>' }, open = '<CR>', locations = 'gl', new_chat = '<C-n>', next_citation = '<Tab>',
        prev_citation = '<S-Tab>', picker = '<C-Space>', scroll_preview_down = '<C-d>', scroll_preview_up = '<C-u>' } },
  }, over or {})
end
local function cur() return answer.current end
local function lines() return vim.api.nvim_buf_get_lines(cur().buf, 0, -1, false) end
local function text() return table.concat(lines(), '\n') end
local function has(part) return cur() and vim.api.nvim_buf_is_valid(cur().buf) and text():find(part, 1, true) ~= nil end
local function idle() return cur() and cur().pending == false and cur().asked end
local function reset()
  if cur() and not cur().closed then answer.close() end
  answer.sessions = {}
  vim.cmd 'silent! only'
  vim.cmd 'enew!'
end
---Run the buffer-local mapping for `lhs` in `mode` on buf, as pressing the key would.
local function press(buf, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then return m.callback() end
  end
  error('no mapping for ' .. lhs .. ' in mode ' .. mode)
end
---Type `s` into the input panel and press <CR>.
local function type_question(s)
  vim.api.nvim_set_current_win(cur().input_win)
  vim.api.nvim_buf_set_lines(cur().input_buf, 0, -1, false, { s })
  press(cur().input_buf, 'i', '<CR>')
end
---The highlight group on row (0-based) of the chat buffer, from the plugin's own namespace.
local function hl_at(row)
  local ns = vim.api.nvim_get_namespaces()['synopsis.answer']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cur().buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
    if m[4].hl_group then return m[4].hl_group end
  end
end
local function row_of(part)
  for i, l in ipairs(lines()) do if l:find(part, 1, true) then return i - 1, l end end
end

local repo = H.make_repo {
  ['a.lua'] = '-- Says hi.\nlocal M = {}\nfunction M.hi() return "hi" end\nreturn M\n',
  ['b.lua'] = 'return 2\n',
  ['.env'] = 'KEY=1\n',
  ['doc.md'] = '# Doc\n\nIt is $x^2$.\n',
}
local function user_text(m) return type(m.content) == 'table' and (m.content[1].text .. m.content[2].text) or m.content end
local function last_request(server) return server.requests[#server.requests].body end

H.check('each tool call is shown as it starts, then the answer replaces them', function()
  reset()
  local server = mock.start({ tool_reply(call('c1', 'rg', { pattern = 'hi' })), 'It is in a.lua:3.' }, { delay_ms = 200 })
  answer.open { root = repo, question = 'Where is hi?', config = config(server) }
  H.eq(vim.api.nvim_win_get_config(cur().win).relative ~= '', true, 'floating')
  vim.wait(3000, function() return has 'Searching `hi`' end, 10)
  H.eq(has 'Searching `hi`', true, text())
  vim.wait(3000, idle, 10)
  H.eq(has 'It is in a.lua:3.', true, text())
  H.eq(has 'Searching', false, 'progress removed')
end)

H.check('questions get a coloured bar; answers, progress and footer are indented; the footer is muted', function()
  reset()
  local server = mock.start({ tool_reply(call('c1', 'rg', { pattern = 'hi' })), 'Line one.\n- a bullet' }, { delay_ms = 200 })
  answer.open { root = repo, question = 'Where is hi?', config = config(server) }
  vim.wait(3000, function() return has 'Searching' end, 10)
  local prow = row_of 'Searching'
  H.eq(hl_at(prow), 'SynopsisProgress', 'progress colour')
  vim.wait(3000, idle, 10)
  local qrow, q = row_of 'Where is hi?'
  H.eq(q, '▌ Where is hi?', 'question line')
  H.eq(hl_at(qrow), 'SynopsisQuestion', 'question colour')
  H.eq(select(2, row_of 'Line one.'), '  Line one.', 'answer indented')
  H.eq(select(2, row_of 'a bullet'), '  - a bullet', 'bullet indented')
  local frow, f = row_of 'tool call'
  H.eq(f:match '^  1 tool call · [%d.]+ s · [%d,]+ tokens$' ~= nil, true, f)
  H.eq(f:find('_', 1, true), nil, 'no underscores')
  H.eq(hl_at(frow), 'SynopsisMeta', 'footer colour')
end)

H.check('LaTeX written as \\( \\) or \\[ \\] is shown with dollar signs, outside code only', function()
  H.eq(answer.dollars [[It uses \(D_{KL}(p\,\|\,q)\) and \[x^2\].]], [[It uses $D_{KL}(p\,\|\,q)$ and $$x^2$$.]], 'inline and display')
  H.eq(answer.dollars [[Code `\(x\)` stays, \(y\) does not.]], [[Code `\(x\)` stays, $y$ does not.]], 'code span')
  H.eq(answer.dollars '\\[\nx = 1\n\\]', '$$\nx = 1\n$$', 'display block on its own lines')
  H.eq(answer.dollars '```\n\\(x\\)\n```', '```\n\\(x\\)\n```', 'code block')
end)

H.check('token counts get thousands separators', function()
  H.eq(answer.thousands(7208), '7,208', 'four digits')
  H.eq(answer.thousands(1234567), '1,234,567', 'seven digits')
  H.eq(answer.thousands(12), '12', 'two digits')
end)

H.check('the highlight groups default to the colour scheme: blue and bold for questions, muted for the rest', function()
  answer.highlights()
  local q = vim.api.nvim_get_hl(0, { name = 'SynopsisQuestion' })
  local fn = vim.api.nvim_get_hl(0, { name = 'Function', link = false })
  H.eq(q.bold, true, 'bold')
  H.eq(q.fg, fn.fg, 'Function colour')
  H.eq(vim.api.nvim_get_hl(0, { name = 'SynopsisMeta' }).link, 'Comment', 'meta')
  H.eq(vim.api.nvim_get_hl(0, { name = 'SynopsisProgress' }).link, 'Comment', 'progress')
end)

H.check('an input panel sits below the chat, as wide, and has the focus', function()
  reset()
  local server = mock.start 'A.'
  answer.open { root = repo, config = config(server) }
  local c = vim.api.nvim_win_get_config(cur().win)
  local i = vim.api.nvim_win_get_config(cur().input_win)
  H.eq(i.relative ~= '', true, 'floating')
  H.eq(i.row, c.row + c.height + 2, 'directly below')
  H.eq(i.width, c.width, 'same width')
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'focus')
end)

H.check('with no question, the chat shows a hint and sends nothing until you type', function()
  reset()
  local server = mock.start 'First.'
  answer.open { root = repo, config = config(server) }
  vim.wait(300)
  H.eq(#server.requests, 0, 'nothing sent')
  H.eq(has('Ask about ' .. vim.fs.basename(repo)), true, text())
  type_question 'Q1?'
  vim.wait(3000, idle, 10)
  H.eq(has '▌ Q1?', true, text())
  H.eq(has 'First.', true, 'answer')
  H.eq(has 'Ask about', false, 'hint removed')
  H.eq(table.concat(vim.api.nvim_buf_get_lines(cur().input_buf, 0, -1, false), ''), '', 'input cleared')
end)

H.check('a question typed in the panel follows up in the same conversation', function()
  reset()
  local server = mock.start { 'First.', 'Second.' }
  answer.open { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(3000, idle, 10)
  type_question 'Q2?'
  vim.wait(3000, function() return has 'Second.' end, 10)
  H.eq(has 'First.' and has '▌ Q2?' and has 'Second.', true, text())
  H.eq(#server.requests[2].body.messages, 4, 'earlier conversation sent')
end)

H.check('sending while an answer is coming sends nothing and says so', function()
  reset()
  local server = mock.start({ 'Slow.' }, { delay_ms = 400 })
  answer.open { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(100)
  type_question 'Q2?'
  H.eq(vim.api.nvim_win_get_config(cur().input_win).title[1][1]:find('waiting', 1, true) ~= nil, true, 'title')
  vim.wait(2000, idle, 10)
  vim.wait(200)
  H.eq(#server.requests, 1, 'one request')
end)

H.check('the conversation never keeps the focus: entering it goes back to the input', function()
  reset()
  local server = mock.start 'A.'
  answer.open { root = repo, config = config(server) }
  vim.api.nvim_set_current_win(cur().win)
  vim.wait(100)
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'input')
end)

H.check('the map sent to the model lists the files, and excluded files by path only', function()
  reset()
  local server = mock.start 'Answer.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  local user = server.requests[1].body.messages[2].content
  if type(user) == 'table' then user = user[1].text .. user[2].text end
  H.eq(user:find('a.lua: Says hi. Defines: M.hi', 1, true) ~= nil, true, user)
  H.eq(user:find('.env: (excluded)', 1, true) ~= nil, true, 'excluded')
  H.eq(user:find('KEY=1', 1, true), nil, 'no secret')
  H.eq(vim.endswith(user, 'QUESTION: Q?'), true, 'question last')
end)

H.check('a chat about a file tells the model which file, in the first question only', function()
  reset()
  local server = mock.start { 'A1.', 'A2.' }
  answer.open { root = repo, config = config(server), about = { path = 'a.lua', line = 3 } }
  H.eq(has 'Asking about `a.lua`', true, text())
  type_question 'How does it work?'
  vim.wait(3000, idle, 10)
  local user = server.requests[1].body.messages[2].content
  if type(user) == 'table' then user = user[1].text .. user[2].text end
  H.eq(user:find('QUESTION: (asked while viewing a.lua, line 3) How does it work?', 1, true) ~= nil, true, user)
  H.eq(has '▌ How does it work?', true, 'shown as typed')
  type_question 'And then?'
  vim.wait(3000, function() return has 'A2.' end, 10)
  H.eq(server.requests[2].body.messages[4].content, 'And then?', 'follow-up plain')
end)

H.check('<CR> in an empty input opens the selected citation at its line', function()
  reset()
  local server = mock.start 'The function is at a.lua:3 in the repo.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  vim.api.nvim_buf_set_lines(cur().input_buf, 0, -1, false, { '' })
  press(cur().input_buf, 'i', '<CR>')
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
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  press(cur().input_buf, 'n', 'gl')
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

H.check('q in the input (Normal mode) closes both windows and cancels the request in flight', function()
  reset()
  local server = mock.start({ tool_reply(call('c1', 'read', { path = 'a.lua' })), 'Late.' }, { delay_ms = 300 })
  answer.open { root = repo, question = 'Q?', config = config(server) }
  local win, input = cur().win, cur().input_win
  vim.wait(100)
  press(cur().input_buf, 'n', 'q')
  H.eq(vim.api.nvim_win_is_valid(win), false, 'chat closed')
  H.eq(vim.api.nvim_win_is_valid(input), false, 'input closed')
  vim.wait(1000)
  H.eq(#server.requests <= 1, true, 'no further request')
end)

H.check('closing the input panel closes the chat too, and calls on_close', function()
  reset()
  local server = mock.start 'A.'
  local closed = 0
  answer.open { root = repo, config = config(server), on_close = function() closed = closed + 1 end }
  local win = cur().win
  vim.api.nvim_win_close(cur().input_win, true)
  vim.wait(100)
  H.eq(vim.api.nvim_win_is_valid(win), false, 'chat closed')
  H.eq(closed, 1, 'on_close once')
end)

H.check('opening a citation does not call on_close', function()
  reset()
  local server = mock.start 'See a.lua:3.'
  local closed = 0
  answer.open { root = repo, question = 'Q?', config = config(server), on_close = function() closed = closed + 1 end }
  vim.wait(3000, idle, 10)
  press(cur().input_buf, 'i', '<CR>')
  vim.wait(100)
  H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), 'a.lua', 'opened')
  H.eq(closed, 0, 'not called')
end)

H.check('the chat is rendered with markview when it is loaded, and the event fires', function()
  reset()
  local calls = {}
  package.loaded.markview = { strict_render = {
    clear = function(_, b) table.insert(calls, 'clear ' .. b) end,
    render = function(_, b) table.insert(calls, 'render ' .. b) end,
  } }
  local fired
  vim.api.nvim_create_autocmd('User', { pattern = 'SynopsisAnswerRendered', once = true, callback = function(ev) fired = ev.data end })
  local server = mock.start 'With $x^2$.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  local buf = cur().buf
  H.eq(vim.tbl_contains(calls, 'render ' .. buf), true, vim.inspect(calls))
  H.eq(vim.wo[cur().win].conceallevel, 2, 'conceallevel')
  H.eq(fired and fired.buf, buf, 'event')
  answer.close()
  H.eq(calls[#calls], 'clear ' .. buf, 'cleared on close')
  package.loaded.markview = nil
end)

H.check('render = false leaves markview alone', function()
  reset()
  local calls = 0
  package.loaded.markview = { strict_render = { clear = function() end, render = function() calls = calls + 1 end } }
  local server = mock.start 'A.'
  answer.open { root = repo, question = 'Q?', config = config(server, { ask = { render = false } }) }
  vim.wait(3000, idle, 10)
  H.eq(calls, 0, 'not rendered')
  package.loaded.markview = nil
end)

H.check('a repo marked deny sends nothing and opens no window', function()
  reset()
  local server = mock.start 'A.'
  local r = H.make_repo { ['x.lua'] = 'return 1\n' }
  consent.set(r, 'deny')
  answer.current = nil
  answer.open { root = r, question = 'Q?', config = config(server, { consent = 'ask' }) }
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
  answer.open { root = r, question = 'Q?', config = config(server, { consent = 'ask' }) }
  vim.ui.select = orig
  vim.wait(3000, idle, 10)
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
  answer.open { root = dir, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  local user = server.requests[1].body.messages[2].content
  if type(user) == 'table' then user = user[1].text .. user[2].text end
  H.eq(user:find('p.lua: Plain.', 1, true) ~= nil, true, user)
end)

-- Conversations kept per repo.
H.check('closing and reopening the chat for the same repo continues the conversation', function()
  reset()
  local server = mock.start { 'A1.', 'A2.' }
  answer.open { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(3000, idle, 10)
  answer.close()
  answer.open { root = repo, config = config(server) }
  H.eq(has '▌ Q1?' and has 'A1.', true, text())
  type_question 'Q2?'
  vim.wait(3000, function() return has 'A2.' end, 10)
  H.eq(#last_request(server).messages, 4, 'earlier conversation sent')
end)

H.check('reopened from another file, the chat says so and tells the model once', function()
  reset()
  local server = mock.start { 'A1.', 'A2.', 'A3.' }
  answer.open { root = repo, question = 'Q1?', config = config(server), about = { path = 'a.lua' } }
  vim.wait(3000, idle, 10)
  answer.close()
  answer.open { root = repo, config = config(server), about = { path = 'b.lua', line = 1 } }
  H.eq(has 'Now viewing `b.lua`', true, text())
  type_question 'Q2?'
  vim.wait(3000, function() return has 'A2.' end, 10)
  H.eq(vim.startswith(last_request(server).messages[4].content, '(asked while viewing b.lua, line 1) Q2?'), true,
    last_request(server).messages[4].content)
  type_question 'Q3?'
  vim.wait(3000, function() return has 'A3.' end, 10)
  H.eq(last_request(server).messages[6].content, 'Q3?', 'told once')
end)

H.check('a question cancelled by closing is shown as cancelled and left out of the conversation', function()
  reset()
  local server = mock.start({ 'Never.', 'A2.' }, { delay_ms = 300 })
  answer.open { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(150)
  answer.close()
  answer.open { root = repo, config = config(server) }
  H.eq(has 'Cancelled.', true, text())
  type_question 'Q2?'
  vim.wait(3000, function() return has 'A2.' end, 10)
  local msgs = last_request(server).messages
  H.eq(#msgs, 2, 'only the new question')
  H.eq(user_text(msgs[2]):find('Q1?', 1, true), nil, 'cancelled question left out')
end)

H.check('<C-n> starts a new conversation', function()
  reset()
  local server = mock.start { 'A1.', 'A2.' }
  answer.open { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(3000, idle, 10)
  press(cur().input_buf, 'i', '<C-n>')
  H.eq(has 'Q1?', false, text())
  type_question 'Q2?'
  vim.wait(3000, function() return has 'A2.' end, 10)
  H.eq(#last_request(server).messages, 2, 'fresh')
end)

H.check('each repo has its own conversation', function()
  reset()
  local server = mock.start 'A1.'
  answer.open { root = repo, question = 'Q1?', config = config(server) }
  vim.wait(3000, idle, 10)
  answer.close()
  local other = H.make_repo { ['x.lua'] = 'return 1\n' }
  answer.open { root = other, config = config(server) }
  H.eq(has 'Q1?', false, text())
end)

-- The preview pane.
local function wins()
  local c, i = vim.api.nvim_win_get_config(cur().win), vim.api.nvim_win_get_config(cur().input_win)
  local p = cur().preview_win and vim.api.nvim_win_is_valid(cur().preview_win) and vim.api.nvim_win_get_config(cur().preview_win)
  return c, i, p
end

H.check('on a wide screen a preview pane sits to the right of the chat, as tall as chat and input', function()
  reset()
  local server = mock.start 'A.'
  answer.open { root = repo, config = config(server) }
  local c, i, p = wins()
  H.eq(p and p.relative ~= '', true, 'preview open')
  H.eq(p.col > c.col + c.width, true, 'to the right')
  H.eq(p.row, c.row, 'tops aligned')
  H.eq(p.height, c.height + i.height + 2, 'height')
end)

H.check('on a narrow screen, or with preview = false, there is no preview pane', function()
  reset()
  local server = mock.start 'A.'
  vim.o.columns = 100
  answer.open { root = repo, config = config(server) }
  local narrow = select(3, wins())
  vim.o.columns = 160
  H.eq(not narrow, true, 'narrow')
  reset()
  answer.open { root = repo, config = config(server, { ask = { preview = false } }) }
  H.eq(not select(3, wins()), true, 'turned off')
end)

local function cited_rows()
  local ns = vim.api.nvim_get_namespaces()['synopsis.preview']
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cur().preview_buf, ns, 0, -1, { details = true })) do
    if m[4].line_hl_group == 'SynopsisCited' then table.insert(rows, m[2]) end
  end
  table.sort(rows)
  return table.concat(rows, ',')
end
local function preview_text() return table.concat(vim.api.nvim_buf_get_lines(cur().preview_buf, 0, -1, false), '\n') end

H.check("an answer's first citation is previewed with its lines highlighted", function()
  reset()
  local server = mock.start 'See a.lua:2-3 and b.lua:1.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  H.eq(cur().preview_path, 'a.lua', 'file')
  H.eq(vim.bo[cur().preview_buf].filetype, 'lua', 'filetype')
  H.eq(cited_rows(), '1,2', 'lines 2-3 highlighted')
  H.eq(vim.api.nvim_win_get_cursor(cur().preview_win)[1], 2, 'cursor')
end)

H.check('a citation is shown near the top of the preview, with three lines above it', function()
  reset()
  local so = vim.o.scrolloff
  vim.o.scrolloff = 10 -- as kickstart sets it
  local lines = {}
  for i = 1, 200 do lines[i] = 'line ' .. i end
  vim.fn.writefile(lines, repo .. '/long.txt')
  local server = mock.start 'See long.txt:100.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  H.eq(cur().preview_path, 'long.txt', 'previewed')
  local top = vim.api.nvim_win_call(cur().preview_win, function() return vim.fn.line 'w0' end)
  H.eq(top, 97, 'top line')
  H.eq(vim.api.nvim_win_get_cursor(cur().preview_win)[1], 100, 'cursor on the cited line')
  answer.preview('long.txt', 2)
  top = vim.api.nvim_win_call(cur().preview_win, function() return vim.fn.line 'w0' end)
  H.eq(top, 1, 'near the start, from the first line')
  -- Ctrl-D and Ctrl-U in the input scroll the preview half a window, as they do in Telescope.
  local function top_line() return vim.api.nvim_win_call(cur().preview_win, function() return vim.fn.line 'w0' end) end
  local half = math.floor(vim.api.nvim_win_get_height(cur().preview_win) / 2)
  for _, mode in ipairs { 'i', 'n' } do
    press(cur().input_buf, mode, '<C-d>')
    H.eq(top_line(), 1 + half, mode .. ': <C-d> scrolls the preview down')
    press(cur().input_buf, mode, '<C-u>')
    H.eq(top_line(), 1, mode .. ': <C-u> scrolls it back up')
  end
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'the focus stays in the input')
  -- A file that fits in the window scrolls too, as in Telescope.
  vim.fn.writefile({ 'one', 'two', 'three' }, repo .. '/short.txt')
  answer.preview('short.txt', 1)
  press(cur().input_buf, 'i', '<C-d>')
  H.eq(top_line() > 1, true, '<C-d> scrolls a short file')
  press(cur().input_buf, 'i', '<C-u>')
  H.eq(top_line(), 1, '<C-u> scrolls it back')
  vim.fn.delete(repo .. '/short.txt')
  reset()
  vim.o.scrolloff = so
  vim.fn.delete(repo .. '/long.txt')
end)

H.check("the chat's title names the project, not the file it was opened on", function()
  reset()
  local server = mock.start 'ok'
  answer.open { root = repo, config = config(server), about = { path = 'a.lua' } }
  local title = vim.api.nvim_win_get_config(cur().win).title
  H.eq(vim.trim(title[1][1]), vim.fs.basename(repo), 'title')
  reset()
end)

H.check('a single-line citation highlights the code block that starts on that line, up to 50 lines', function()
  reset()
  local long = { 'local M = {}', 'function M.long()' }
  for i = 1, 60 do long[#long + 1] = '  local x' .. i .. ' = ' .. i end
  vim.list_extend(long, { 'end', 'return M' })
  vim.fn.writefile({ 'local M = {}', 'function M.f(a)', '  local b = a + 1', '  return b', 'end', 'return M' }, repo .. '/f.lua')
  vim.fn.writefile(long, repo .. '/g.lua')
  local server = mock.start 'ok'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  answer.preview('f.lua', 2)
  H.eq(cited_rows(), '1,2,3,4', 'the whole function from its first line')
  answer.preview('f.lua', 3)
  H.eq(cited_rows(), '2', 'a one-line statement inside it: just that line')
  answer.preview('f.lua', 2, 3)
  H.eq(cited_rows(), '1,2', 'a range as cited')
  answer.preview('g.lua', 2)
  H.eq(cited_rows(), '1', 'a block longer than 50 lines: just the line')
  answer.preview('b.lua', 1)
  H.eq(cited_rows(), '0', 'not widened to the whole file')
  answer.preview('.gitignore', 1) -- no parser for it
  reset()
  vim.fn.delete(repo .. '/f.lua')
  vim.fn.delete(repo .. '/g.lua')
end)

H.check("a cited line inside a long function stands for itself, or for its statement across lines", function()
  reset()
  vim.fn.writefile({
    'function train(model, data)',
    '  local loss = cross_entropy(model(data.x), data.y)', -- the first statement of the body
    '  local opt = adam(',
    '    model.params, 0.001',
    '  )',
    '  opt:step(loss)',
    'end',
  }, repo .. '/train.lua')
  local server = mock.start 'ok'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  answer.preview('train.lua', 2)
  H.eq(cited_rows(), '1', 'the loss line only, not the rest of the function')
  answer.preview('train.lua', 3)
  H.eq(cited_rows(), '2,3,4', 'a statement over three lines')
  answer.preview('train.lua', 1)
  H.eq(cited_rows(), '0,1,2,3,4,5,6', 'the function from its first line')
  reset()
  vim.fn.delete(repo .. '/train.lua')
end)

H.check('in Python: a def or for line highlights its block; a loss line inside a loop only itself', function()
  reset()
  H.eq(H.has_parser 'python', true, "Python's Tree-sitter parser is installed")
  vim.fn.writefile({
    'import torch.nn.functional as F',
    '',
    '',
    '@torch.no_grad()',
    'def evaluate(model, data):',
    '    return model(data).mean()',
    '',
    '',
    'def train(model, data, opt):',
    '    for x, y in data:',
    '        logits = model(x)',
    '        loss = F.cross_entropy(logits, y)',
    '        loss.backward()',
    '        opt.step()',
    '    return loss',
  }, repo .. '/train.py')
  local server = mock.start 'ok'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  local function rows(line)
    answer.preview('train.py', line)
    local r = vim.split(cited_rows(), ',')
    return (tonumber(r[1]) + 1) .. '-' .. (tonumber(r[#r]) + 1)
  end
  H.eq(rows(9), '9-15', 'def train: the function')
  H.eq(rows(10), '10-14', 'for: the loop')
  H.eq(rows(11), '11-11', "the loop's first statement only")
  H.eq(rows(12), '12-12', 'the loss line only')
  H.eq(rows(4), '4-4', 'a decorator line only')
  H.eq(rows(5), '5-6', 'def evaluate: the function')
  reset()
  vim.fn.delete(repo .. '/train.py')
end)

---The text the conversation highlights as the selected link.
local function selected_link()
  local ns = vim.api.nvim_get_namespaces()['synopsis.link']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cur().buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == 'SynopsisLink' then
      return vim.api.nvim_buf_get_text(cur().buf, m[2], m[3], m[4].end_row, m[4].end_col, {})[1]
    end
  end
end

H.check('the selected link stands out: SynopsisLink links to IncSearch by default', function()
  vim.cmd 'highlight clear SynopsisLink'
  answer.highlights()
  H.eq(vim.api.nvim_get_hl(0, { name = 'SynopsisLink' }).link, 'IncSearch', 'default link')
end)

H.check("the selected link's highlight wins over markview's inline code (priority 4096)", function()
  reset()
  local server = mock.start 'See `a.lua:2-3` and b.lua:1.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  local ns = vim.api.nvim_get_namespaces()['synopsis.link']
  local m = vim.api.nvim_buf_get_extmarks(cur().buf, ns, 0, -1, { details = true })[1]
  H.eq(m ~= nil and m[4].priority > 4096, true, m and ('priority ' .. m[4].priority) or 'no link mark')
end)

H.check('<Tab> and <S-Tab> in the input move the selected link, wrapping, and the preview follows', function()
  reset()
  local server = mock.start 'See a.lua:2-3 and b.lua:1.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  H.eq(selected_link(), 'a.lua:2', 'the first link is selected')
  press(cur().input_buf, 'i', '<Tab>')
  H.eq(cur().preview_path, 'b.lua', 'second')
  H.eq(selected_link(), 'b.lua:1', 'highlighted')
  H.eq(cited_rows(), '0', 'b.lua line 1')
  press(cur().input_buf, 'i', '<Tab>')
  H.eq(cur().preview_path, 'a.lua', 'wrapped forward')
  press(cur().input_buf, 'i', '<S-Tab>')
  H.eq(cur().preview_path, 'b.lua', 'wrapped back')
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'still typing in the input')
end)

H.check("a new answer selects its own first link, and shows the answer's start", function()
  reset()
  local server = mock.start { 'See a.lua:2.', 'Then b.lua:1.' }
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  type_question 'And?'
  vim.wait(3000, function() return has 'Then b.lua:1.' and idle() end, 10)
  H.eq(selected_link(), 'b.lua:1', 'second answer selected')
  H.eq(cur().preview_path, 'b.lua', 'previewed')
  local top = vim.fn.getwininfo(cur().win)[1].topline
  H.eq(top <= row_of 'Then b.lua:1.' + 1, true, 'answer start visible')
end)

H.check('clicking a link selects and previews it, and the typing cursor stays in the input', function()
  reset()
  local server = mock.start 'See a.lua:2-3 and b.lua:1.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  local row, l = row_of 'b.lua:1'
  H.eq(answer.click { winid = cur().win, line = row + 1, column = l:find('b.lua:1', 1, true) + 1 }, true, 'handled')
  vim.wait(100)
  H.eq(cur().preview_path, 'b.lua', 'previewed')
  H.eq(selected_link(), 'b.lua:1', 'selected')
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'input focused')
  -- A click that lands in the conversation directly (from the input) does the same.
  local ra, la = row_of 'a.lua:2'
  vim.api.nvim_win_set_cursor(cur().win, { ra + 1, (la:find('a.lua:2', 1, true)) })
  vim.api.nvim_set_current_win(cur().win)
  vim.wait(100)
  H.eq(selected_link(), 'a.lua:2', 'selected by entering')
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'back in the input')
end)

H.check('an excluded file is never shown in the preview', function()
  reset()
  local server = mock.start 'See .env:1.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  H.eq(preview_text():find('excluded by the exclude setting', 1, true) ~= nil, true, preview_text())
  H.eq(preview_text():find('KEY=1', 1, true), nil, 'no secret')
end)

H.check('<CR> in the preview opens the file at its cursor line, without reopening Telescope', function()
  reset()
  local server = mock.start 'See a.lua:2-3.'
  local closed = 0
  answer.open { root = repo, question = 'Q?', config = config(server), on_close = function() closed = closed + 1 end }
  vim.wait(3000, idle, 10)
  vim.api.nvim_set_current_win(cur().preview_win)
  press(cur().preview_buf, 'n', '<CR>')
  vim.wait(100)
  H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), 'a.lua', 'file')
  H.eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'line')
  H.eq(closed, 0, 'on_close not called')
end)

H.check('a cited markdown file is rendered in the preview', function()
  reset()
  local calls = {}
  package.loaded.markview = { strict_render = {
    clear = function() end, render = function(_, b) table.insert(calls, b) end,
  } }
  local server = mock.start 'See doc.md:3.'
  answer.open { root = repo, question = 'Q?', config = config(server) }
  vim.wait(3000, idle, 10)
  H.eq(cur().preview_path, 'doc.md', 'previewed')
  H.eq(vim.tbl_contains(calls, cur().preview_buf), true, 'rendered')
  package.loaded.markview = nil
end)

H.finish()
