-- The chat docked beside Telescope: on a wide screen, Ctrl-g in a picker with the synopsis layout
-- keeps the picker open and opens the chat in a column on the right. Ctrl-g moves between the
-- two; the chat's citations are shown in Telescope's preview; leaving both closes both.
local H = dofile 'tests/harness.lua'
local mock = dofile 'tests/mock_llm.lua'

vim.o.columns, vim.o.lines = 200, 50
vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
-- One reply for every request; summaries are never requested (delay_ms is longer than any test).
local server = mock.start 'See a.lua:2-3 and b.lua:1.'
local root = H.make_repo {
  ['a.lua'] = '-- Says hi.\nlocal M = {}\nfunction M.hi() return "hi" end\nreturn M\n',
  ['b.lua'] = 'return "b"\n',
}
vim.cmd.cd(root)

require('telescope').setup {}
require('synopsis').setup {
  llm = { url = server.url, model = 'mock-model', api_key_env = 'SYNOPSIS_TEST_KEY', params = {} },
  background = SYNOPSIS_ROOT .. '/tests/fixtures/background.md',
  delay_ms = 600000,
  consent = 'always',
}
local answer = require 'synopsis.answer'
local actions = require 'telescope.actions'
local state = require 'telescope.actions.state'

local function prompt_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == 'TelescopePrompt' then return b end
  end
end
local function picker() return prompt_buf() and state.get_current_picker(prompt_buf()) end
local function cur() return answer.current end
local function chat_open() return cur() ~= nil and not cur().closed and cur().win ~= nil and vim.api.nvim_win_is_valid(cur().win) end
local function chat_text() return table.concat(vim.api.nvim_buf_get_lines(cur().buf, 0, -1, false), '\n') end

---Outer box of a floating window: { row, col, w, h }, borders included.
local function box(win)
  local c = vim.api.nvim_win_get_config(win)
  local pad = (c.border and c.border ~= 'none' and #c.border > 0) and 2 or 0
  return { row = c.row, col = c.col, w = c.width + pad, h = c.height + pad }
end
---Every floating window that is not the chat's: Telescope's windows, their borders and the pane.
local function picker_floats()
  local out, mine = {}, {}
  if cur() then for _, w in ipairs { cur().win, cur().input_win } do if w then mine[w] = true end end end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' and not mine[w] then table.insert(out, box(w)) end
  end
  return out
end

local function press(buf, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if vim.keycode(m.lhs) == vim.keycode(lhs) then return m.callback() end
  end
  error('no mapping for ' .. lhs .. ' in mode ' .. mode)
end

local function open_picker()
  require('telescope.builtin').find_files { layout_strategy = 'synopsis' }
  vim.wait(2000, function()
    return picker() ~= nil and state.get_selected_entry() ~= nil and vim.fn.maparg('<C-g>', 'i', false, true).buffer == 1
  end, 10)
end
local function ctrl_g()
  press(prompt_buf(), 'i', '<C-g>')
  vim.wait(2000, chat_open, 10)
  vim.wait(50)
end
local function close_all()
  if cur() and not cur().closed then answer.close() end
  vim.wait(100) -- a chat opened on its own reopens the picker when it closes
  if prompt_buf() then actions.close(prompt_buf()) end
  vim.wait(1000, function() return prompt_buf() == nil end, 10)
  answer.sessions = {}
  vim.cmd 'silent! only'
  vim.cmd 'enew!'
end
local function ask(q)
  vim.api.nvim_buf_set_lines(cur().input_buf, 0, -1, false, { q })
  press(cur().input_buf, 'i', '<CR>')
  vim.wait(3000, function() return cur().pending == false and cur().asked end, 10)
  vim.wait(50)
end

H.check('Ctrl-g on a wide screen keeps the picker open and opens the chat beside it', function()
  close_all()
  open_picker()
  local before = picker_floats()
  ctrl_g()
  H.eq(chat_open(), true, 'chat open')
  H.eq(prompt_buf() ~= nil, true, 'picker still open')
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'focus in the input panel')
  local chat = box(cur().win)
  for _, f in ipairs(picker_floats()) do
    H.eq(f.col + f.w <= chat.col, true, string.format('picker window at col %d, width %d, reaches the chat at %d', f.col, f.w, chat.col))
  end
  local left = math.huge
  for _, f in ipairs(before) do left = math.min(left, f.col) end
  local left_now = math.huge
  for _, f in ipairs(picker_floats()) do left_now = math.min(left_now, f.col) end
  H.eq(left_now, left, 'the picker keeps its left edge')
  local input = box(cur().input_win)
  H.eq(input.col, chat.col, 'input under the conversation')
  H.eq(input.row >= chat.row + chat.h, true, 'input below the conversation')
  H.eq(chat.col + chat.w <= vim.o.columns, true, 'chat fits on the screen')
end)

H.check('Ctrl-g in the chat goes back to the prompt, and from the prompt back to the chat', function()
  local win = cur().win
  press(cur().input_buf, 'i', '<C-g>')
  vim.wait(50)
  H.eq(vim.api.nvim_get_current_win(), picker().prompt_win, 'focus in the prompt')
  H.eq(chat_open(), true, 'chat still open')
  H.eq(prompt_buf() ~= nil, true, 'picker still open')
  ctrl_g()
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'focus back in the input panel')
  H.eq(cur().win, win, 'same chat window')
  vim.api.nvim_set_current_win(cur().win)
  press(cur().buf, 'n', '<C-g>')
  vim.wait(50)
  H.eq(vim.api.nvim_get_current_win(), picker().prompt_win, 'from the conversation too')
end)

local function preview_cited()
  local p = picker()
  local buf = vim.api.nvim_win_get_buf(p.preview_win)
  local ns = vim.api.nvim_get_namespaces()['synopsis.preview']
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].line_hl_group == 'SynopsisCited' then rows[m[2] + 1] = true end
  end
  return buf, rows
end

H.check("an answer's first citation is shown in Telescope's preview", function()
  ctrl_g()
  ask 'Where is hi?'
  local buf, rows = preview_cited()
  H.eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1], 'function M.hi() return "hi" end', 'a.lua is shown')
  H.eq(rows[2] and rows[3] and not rows[1], true, 'lines 2 and 3 highlighted: ' .. vim.inspect(rows))
  local p = picker()
  H.eq(vim.api.nvim_win_get_cursor(p.preview_win)[1], 2, 'cursor on the first cited line')
  H.eq(p.preview_win ~= nil and cur().preview_win == nil, true, 'no preview pane of its own')
end)

H.check('Tab moves to the next citation and shows it in the preview', function()
  vim.api.nvim_set_current_win(cur().win)
  vim.api.nvim_win_set_cursor(cur().win, { 1, 0 })
  press(cur().buf, 'n', '<Tab>')
  press(cur().buf, 'n', '<Tab>')
  local buf = preview_cited()
  H.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], 'return "b"', 'b.lua is shown')
end)

H.check("going back to the prompt gives the preview back to the picker's file", function()
  press(cur().buf, 'n', '<C-g>')
  vim.wait(300)
  local buf, rows = preview_cited()
  H.eq(next(rows), nil, 'no cited lines in the preview')
  local entry = state.get_selected_entry()
  local name = vim.fs.basename(entry.path or entry.filename or entry.value)
  local want = vim.fn.readfile(root .. '/' .. name)[1]
  H.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], want, 'the selected file ' .. name)
end)

H.check('Ctrl-g on another file continues the chat, noting the new file once', function()
  actions.move_selection_next(prompt_buf())
  vim.wait(300)
  local entry = state.get_selected_entry()
  local name = vim.fs.basename(entry.path or entry.filename or entry.value)
  ctrl_g()
  H.eq(chat_text():find('Where is hi?', 1, true) ~= nil, true, 'earlier question kept')
  H.eq(chat_text():find('Now viewing `' .. name .. '`', 1, true) ~= nil, true, chat_text())
  local n = #server.requests
  ask 'And this one?'
  local msgs = server.requests[n + 1].body.messages
  H.eq(msgs[#msgs].content:find('(asked while viewing ' .. name, 1, true) == 1, true, msgs[#msgs].content)
  press(cur().input_buf, 'i', '<C-g>')
  ctrl_g()
  local _, count = chat_text():gsub('Now viewing', '')
  H.eq(count, 1, 'noted once')
end)

H.check('q in the conversation closes only the chat, and the picker takes the full width again', function()
  local narrow = vim.api.nvim_win_get_width(picker().results_win)
  vim.api.nvim_set_current_win(cur().win)
  press(cur().buf, 'n', 'q')
  vim.wait(300)
  H.eq(cur().closed, true, 'chat closed')
  H.eq(prompt_buf() ~= nil, true, 'picker open')
  H.eq(vim.api.nvim_get_current_win(), picker().prompt_win, 'focus in the prompt')
  H.eq(vim.api.nvim_win_get_width(picker().results_win) > narrow, true, 'results wider again')
  vim.wait(300)
  H.eq(prompt_buf() ~= nil, true, 'picker not reopened or closed later')
end)

H.check('closing the picker closes the chat', function()
  ctrl_g()
  press(cur().input_buf, 'i', '<C-g>')
  vim.wait(50)
  actions.close(prompt_buf())
  vim.wait(500, function() return cur().closed end, 10)
  H.eq(cur().closed, true, 'chat closed')
  vim.wait(300)
  H.eq(prompt_buf(), nil, 'picker not reopened')
end)

H.check('moving the focus to an ordinary window closes the picker and the chat', function()
  close_all()
  local normal = vim.api.nvim_get_current_win()
  open_picker()
  ctrl_g()
  vim.api.nvim_set_current_win(normal)
  vim.wait(500, function() return prompt_buf() == nil and cur().closed end, 10)
  H.eq(cur().closed, true, 'chat closed')
  H.eq(prompt_buf(), nil, 'picker closed')
end)

H.check('<CR> on a citation closes both and opens the file at the line', function()
  close_all()
  open_picker()
  ctrl_g()
  ask 'Where?'
  vim.api.nvim_set_current_win(cur().win)
  local row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(cur().buf, 0, -1, false)) do if l:find('a.lua:2', 1, true) then row = i end end
  local col = vim.api.nvim_buf_get_lines(cur().buf, row - 1, row, false)[1]:find('a.lua:2', 1, true)
  vim.api.nvim_win_set_cursor(cur().win, { row, col - 1 })
  press(cur().buf, 'n', '<CR>')
  vim.wait(500, function() return prompt_buf() == nil end, 10)
  H.eq(prompt_buf(), nil, 'picker closed')
  H.eq(cur().closed, true, 'chat closed')
  H.eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), 'a.lua', 'file opened')
  H.eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'at the line')
  H.eq(vim.api.nvim_win_get_config(0).relative, '', 'in an ordinary window')
end)

local function wh(win) return vim.wo[win].winhighlight end

H.check("the docked chat's borders use Telescope's highlight groups; a chat on its own does not", function()
  close_all()
  open_picker()
  ctrl_g()
  H.eq(wh(cur().win):find('FloatBorder:TelescopeResultsBorder', 1, true) ~= nil, true, wh(cur().win))
  H.eq(wh(cur().input_win):find('FloatBorder:TelescopePromptBorder', 1, true) ~= nil, true, wh(cur().input_win))
  close_all()
  answer.open { root = root, config = require('synopsis').config }
  vim.wait(500, chat_open, 10)
  H.eq(wh(cur().win):find('Telescope', 1, true), nil, 'standalone: ' .. wh(cur().win))
  close_all()
end)

H.check("previewing a citation fires Telescope's preview event with its filetype; going back fires it for the selected file", function()
  open_picker()
  ctrl_g()
  local events = {}
  local group = vim.api.nvim_create_augroup('test-preview-events', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'TelescopePreviewerLoaded',
    callback = function(ev) table.insert(events, { data = ev.data or {}, buf = vim.api.nvim_get_current_buf() }) end,
  })
  answer.preview('b.lua', 1)
  local e = events[#events]
  H.eq(e and e.data.filetype, 'lua', 'filetype')
  H.eq(e.data.synopsis_citation, true, 'marked as a citation')
  H.eq(e.buf, vim.api.nvim_win_get_buf(picker().preview_win), 'fired with the preview buffer current')
  events = {}
  press(cur().input_buf, 'i', '<C-g>')
  vim.wait(500, function() return #events > 0 end, 10)
  local entry = state.get_selected_entry()
  local name = vim.fs.basename(entry.path or entry.filename or entry.value)
  local last = events[#events]
  H.eq(last ~= nil and not last.data.synopsis_citation, true, 'an event for the picker: ' .. vim.inspect(events))
  H.eq(vim.fs.basename(last.data.bufname or ''), name, 'for the selected file')
  vim.api.nvim_del_augroup_by_id(group)
  close_all()
end)

---Whether buf's Insert-mode lhs (default <C-g>) is synopsis's own.
local function ours(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'i')) do
    if vim.keycode(m.lhs) == vim.keycode(lhs or '<C-g>') then return (m.desc or ''):find('^synopsis:') ~= nil end
  end
  return false
end
---Fire InsertEnter in win's buffer, as entering Insert mode there would, and let scheduled work run.
local function insert_enter(win)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_exec_autocmds('InsertEnter', { buffer = vim.api.nvim_win_get_buf(win) })
  vim.wait(50)
end

H.check("the chat's keys survive other plugins mapping them on InsertEnter, as llama.vim and blink.cmp do", function()
  local fake = vim.api.nvim_create_augroup('fake-llama', { clear = true })
  -- llama.vim maps <C-g> on InsertEnter and can unmap it again; blink.cmp maps <C-n>, <C-e>, ...
  vim.api.nvim_create_autocmd('InsertEnter', { group = fake, pattern = '*',
    command = 'inoremap <buffer> <C-g> <Nop> | inoremap <buffer> <C-n> <Nop> | inoremap <buffer> <C-e> <Nop>' })
  vim.api.nvim_create_autocmd('InsertLeave', { group = fake, pattern = '*', command = 'silent! iunmap <buffer> <C-g>' })
  open_picker()
  insert_enter(picker().prompt_win)
  H.eq(ours(prompt_buf()), true, 'prompt key, before the chat opens')
  for i = 1, 3 do
    press(prompt_buf(), 'i', '<C-g>')
    vim.wait(2000, chat_open, 10)
    vim.wait(50)
    H.eq(vim.api.nvim_get_current_win(), cur().input_win, i .. ': in the input')
    vim.api.nvim_exec_autocmds('InsertLeave', { buffer = cur().input_buf })
    insert_enter(cur().input_win)
    for _, k in ipairs { '<C-g>', '<C-n>', '<C-e>' } do H.eq(ours(cur().input_buf, k), true, i .. ': input ' .. k) end
    H.eq(vim.b[cur().input_buf].completion, false, 'completion menus off in the input')
    press(cur().input_buf, 'i', '<C-g>')
    vim.wait(50)
    H.eq(vim.api.nvim_get_current_win(), picker().prompt_win, i .. ': in the prompt')
    insert_enter(picker().prompt_win)
    H.eq(ours(prompt_buf()), true, i .. ': prompt key')
  end
  vim.api.nvim_del_augroup_by_id(fake)
  close_all()
end)

local function cited_rows()
  local buf = vim.api.nvim_win_get_buf(picker().preview_win)
  local ns = vim.api.nvim_get_namespaces()['synopsis.preview']
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

H.check('clicks move the focus between the picker and the chat', function()
  open_picker()
  ctrl_g()
  press(cur().input_buf, 'i', '<C-g>')
  vim.wait(50)
  local click
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(prompt_buf(), 'i')) do
    if m.lhs == '<LeftMouse>' then click = m end
  end
  H.eq(click and (click.desc or ''):find('^synopsis:') ~= nil, true, "the prompt's <LeftMouse> is synopsis's")
  H.eq(answer.click { winid = cur().win, line = 1, column = 3 }, true, 'click handled')
  H.eq(vim.api.nvim_get_current_win(), cur().win, 'conversation focused')
  H.eq(vim.api.nvim_win_get_cursor(cur().win)[1] == 1 and vim.api.nvim_win_get_cursor(cur().win)[2] == 2, true,
    vim.inspect(vim.api.nvim_win_get_cursor(cur().win)))
  H.eq(answer.click { winid = cur().input_win, line = 1, column = 1 }, true, 'click handled')
  H.eq(vim.api.nvim_get_current_win(), cur().input_win, 'input focused')
  H.eq(answer.click { winid = picker().results_win, line = 1, column = 1 }, false, 'results left to Telescope')
  -- From the chat, a click lands in a Telescope window; entering the results selects that row.
  local p = picker()
  local rows = vim.api.nvim_buf_get_lines(p.results_bufnr, 0, -1, false)
  local target
  for r, l in ipairs(rows) do if l ~= '' and r - 1 ~= p:get_selection_row() then target = r end end
  vim.api.nvim_win_set_cursor(p.results_win, { target, 0 })
  vim.api.nvim_set_current_win(p.results_win)
  vim.wait(300)
  H.eq(vim.api.nvim_get_current_win(), p.prompt_win, 'moved to the prompt')
  H.eq(p:get_selection_row(), target - 1, 'clicked row selected')
  -- Entering the prompt from the chat hands the preview back to the picker.
  ctrl_g()
  answer.preview('b.lua', 1)
  H.eq(cited_rows() > 0, true, 'citation shown')
  vim.api.nvim_set_current_win(p.prompt_win)
  vim.wait(300)
  H.eq(cited_rows(), 0, 'preview back to the selected file')
  close_all()
end)

H.check('below side_min_columns, Ctrl-g closes the picker and opens the chat on its own', function()
  close_all()
  vim.o.columns = 160
  open_picker()
  ctrl_g()
  vim.o.columns = 200
  H.eq(prompt_buf(), nil, 'picker closed')
  H.eq(chat_open(), true, 'chat open')
  close_all()
end)

H.finish()
