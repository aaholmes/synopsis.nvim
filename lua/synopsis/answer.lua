-- The :SynopsisAsk chat. open{ root, config, question?, about?, on_close? } checks consent and
-- opens up to three floating windows: the conversation, an input panel below it where questions
-- are typed, and on wide screens a preview pane on the right that shows a cited file with the
-- cited lines highlighted. Each repo keeps its conversation for the editor session, so closing
-- and reopening the chat continues it. Each question runs the question loop (ask.lua) with the
-- repo's file map; tool calls show as muted progress lines until the answer replaces them.
-- Closing any window closes all of them and cancels a question still being answered.
local consent = require 'synopsis.consent'
local files = require 'synopsis.files'
local map = require 'synopsis.map'
local store = require 'synopsis.store'
local loop = require 'synopsis.ask'
local M = { sessions = {} }

local TOOLS = { 'rg', 'read', 'outline' }
local ns = vim.api.nvim_create_namespace 'synopsis.answer'
local ns_preview = vim.api.nvim_create_namespace 'synopsis.preview'
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local system_prompt
local function system()
  if not system_prompt then
    local f = assert(io.open(plugin_root .. '/prompts/ask.md', 'rb'))
    system_prompt = vim.trim(f:read '*a')
    f:close()
  end
  return system_prompt
end

---Default colours, from the colour scheme: questions in Function's colour, bold; progress, footer
---and hints muted (Comment); cited lines in the preview like a selection (Visual). Defined with
---default = true, so a colour scheme or user wins.
function M.highlights()
  local fn = vim.api.nvim_get_hl(0, { name = 'Function', link = false })
  vim.api.nvim_set_hl(0, 'SynopsisQuestion', { fg = fn.fg, ctermfg = fn.ctermfg, bold = true, default = true })
  for _, g in ipairs { 'SynopsisProgress', 'SynopsisMeta', 'SynopsisHint' } do
    vim.api.nvim_set_hl(0, g, { link = 'Comment', default = true })
  end
  vim.api.nvim_set_hl(0, 'SynopsisCited', { link = 'Visual', default = true })
end
M.highlights()
vim.api.nvim_create_autocmd('ColorScheme', { group = vim.api.nvim_create_augroup('synopsis.answer', { clear = true }), callback = M.highlights })

---12345 -> "12,345"
function M.thousands(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return (out:gsub('^,', ''))
end

---Rewrite LaTeX delimiters \( \) and \[ \] as $ and $$, which markdown renderers recognise,
---outside code spans and fenced code blocks.
function M.dollars(text)
  local out, fence = {}, false
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line:match '^%s*```' or line:match '^%s*~~~' then
      fence = not fence
    elseif not fence then
      local indent, body = line:match '^(%s*)(.-)%s*$'
      if body == '\\[' or body == '\\]' then
        line = indent .. '$$'
      else
        local parts = vim.split(line, '`', { plain = true })
        for i = 1, #parts, 2 do -- odd pieces are outside code spans
          parts[i] = parts[i]:gsub('\\%((.-)\\%)', '$%1$'):gsub('\\%[(.-)\\%]', '$$%1$$')
        end
        line = table.concat(parts, '`')
      end
    end
    table.insert(out, line)
  end
  return table.concat(out, '\n')
end

---Each path:line (or path:first-last) in `line` that names a file in root:
---{ s, e, path, line, last } (s, e are byte columns).
local function find_all(line, root)
  local out, init = {}, 1
  while true do
    local s, e, path, n = line:find('([%w_%-%./]+):(%d+)', init)
    if not s then break end
    init = e + 1
    path = path:gsub('^%./', '')
    local last = line:match('^%-(%d+)', e + 1) or line:match('^–(%d+)', e + 1)
    local st = path:find '[%./]' and vim.uv.fs_stat(root .. '/' .. path)
    if st and st.type == 'file' then
      table.insert(out, { s = s, e = e, path = path, line = tonumber(n), last = tonumber(last) })
    end
  end
  return out
end

---The distinct path:line citations in text that name files in root, in order of appearance.
function M.citations(text, root)
  local out, seen = {}, {}
  for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
    for _, c in ipairs(find_all(l, root)) do
      local k = c.path .. ':' .. c.line
      if not seen[k] then
        seen[k] = true
        table.insert(out, { path = c.path, line = c.line, last = c.last })
      end
    end
  end
  return out
end

local function label(name, args)
  local ok, a = pcall(vim.json.decode, args or '{}')
  a = ok and type(a) == 'table' and a or {}
  if name == 'rg' then
    return string.format('Searching `%s`%s', a.pattern or '', a.glob and (' in `' .. a.glob .. '`') or '')
  elseif name == 'read' then
    local range = (a.start or a['end']) and string.format(' %s–%s', a.start or 1, a['end'] or 'end') or ''
    return string.format('Reading `%s`%s', a.path or '', range)
  elseif name == 'outline' then
    return string.format('Outlining `%s`', a.path or '')
  end
  return name
end

-- The conversation is a list of items { kind, text }: question (shown with a bar), answer,
-- progress, meta (the footer), hint (removed once a question is asked), note (a lasting hint,
-- such as "Now viewing …"), or blank. Everything but questions is indented 2 spaces.
local HL = { question = 'SynopsisQuestion', progress = 'SynopsisProgress', meta = 'SynopsisMeta', hint = 'SynopsisHint',
  note = 'SynopsisHint' }

local function layout(items)
  local lines, marks = {}, {}
  for _, it in ipairs(items) do
    for _, l in ipairs(vim.split(it.text or '', '\n', { plain = true })) do
      local line
      if it.kind == 'question' then
        line = '▌ ' .. l
      elseif it.kind == 'blank' or l == '' then
        line = ''
      else
        line = '  ' .. l
      end
      table.insert(lines, line)
      if HL[it.kind] and line ~= '' then table.insert(marks, { row = #lines - 1, len = #line, hl = HL[it.kind] }) end
    end
  end
  return lines, marks
end

local function is_open(s) return s and not s.closed and s.win and vim.api.nvim_win_is_valid(s.win) end

---Render buf's markdown and LaTeX with markview and snacks, if they are loaded.
local function markdown_render(s, buf)
  if s.config.ask.render == false then return end
  local mv = package.loaded.markview
  if mv and mv.strict_render then
    pcall(mv.strict_render.clear, mv.strict_render, buf)
    pcall(mv.strict_render.render, mv.strict_render, buf)
  end
  local image = rawget(_G, 'Snacks') and Snacks.image
  if not vim.b[buf].synopsis_snacks and image and image.supports_terminal and image.supports_terminal() then
    vim.b[buf].synopsis_snacks = true
    pcall(image.doc.attach, buf)
  end
end

local function forget_markview(buf)
  local mv = package.loaded.markview
  if mv and mv.strict_render then pcall(mv.strict_render.clear, mv.strict_render, buf) end
end

local function render(s)
  if not (is_open(s) and vim.api.nvim_buf_is_valid(s.buf)) then return end
  local items = vim.list_extend(vim.deepcopy(s.items), s.tail)
  local lines, marks = layout(items)
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, m.row, 0, { end_col = m.len, hl_group = m.hl, priority = 150 })
  end
  markdown_render(s, s.buf)
  if vim.api.nvim_get_current_win() ~= s.win then pcall(vim.api.nvim_win_set_cursor, s.win, { #lines, 0 }) end
  vim.api.nvim_exec_autocmds('User', { pattern = 'SynopsisAnswerRendered', data = { buf = s.buf, win = s.win } })
end

local function set_title(s)
  if not (s.input_win and vim.api.nvim_win_is_valid(s.input_win)) then return end
  local title = s.pending and ' waiting for the answer… ' or ' Ask · Enter sends · Ctrl-k to the chat '
  vim.api.nvim_win_set_config(s.input_win, { title = title, title_pos = 'left' })
end

-- The preview pane.

local jump -- defined below: close the chat and open a file at a line

local function preview_message(s, text)
  local buf = s.preview_msg_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'
    s.preview_msg_buf = buf
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '  ' .. text })
  vim.bo[buf].modifiable = false
  return buf
end

---A scratch buffer holding path's text, with its filetype and syntax colours; cached per session.
local function preview_buffer(s, path, text)
  s.preview_bufs = s.preview_bufs or {}
  local buf = s.preview_bufs[path]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ft = vim.filetype.match { filename = path, contents = vim.list_slice(lines, 1, 5) }
  if ft then
    -- No FileType autocmds: they would attach language servers and plugins to a scratch buffer.
    vim.api.nvim_buf_call(buf, function() vim.cmd('noautocmd setlocal filetype=' .. ft) end)
    local lang = vim.treesitter.language.get_lang(ft)
    if lang then pcall(vim.treesitter.start, buf, lang) end
    if ft == 'markdown' then
      vim.b[buf].synopsis_markdown = true
    end
  end
  vim.keymap.set('n', '<CR>', function() jump(s, path, vim.api.nvim_win_get_cursor(0)[1]) end,
    { buffer = buf, nowait = true, desc = 'synopsis: open this file at the cursor line' })
  local close = s.config.ask.keymaps and s.config.ask.keymaps.close
  for _, k in ipairs(type(close) == 'table' and close or { close }) do
    vim.keymap.set('n', k, M.close, { buffer = buf, nowait = true, desc = 'synopsis: close the chat' })
  end
  s.preview_bufs[path] = buf
  return buf
end

---Show path in the preview pane with lines first..last highlighted (last defaults to first).
function M.preview(path, first, last)
  local s = M.current
  if not (is_open(s) and s.preview_win and vim.api.nvim_win_is_valid(s.preview_win)) then return end
  s.preview_path, s.preview_first = path, first
  local why, text = files.skip_reason(s.root, path, { exclude = s.config.exclude, max_bytes = s.config.max_bytes })
  local buf
  if why then
    buf = preview_message(s, path .. ': not shown (' .. why .. ')')
    s.preview_buf = buf
    vim.api.nvim_win_set_buf(s.preview_win, buf)
    vim.api.nvim_win_set_config(s.preview_win, { title = ' ' .. path .. ' ', title_pos = 'center' })
    return
  end
  buf = preview_buffer(s, path, text)
  s.preview_buf = buf
  vim.api.nvim_win_set_buf(s.preview_win, buf)
  vim.wo[s.preview_win].wrap = false
  vim.wo[s.preview_win].number = true
  if vim.b[buf].synopsis_markdown then
    vim.wo[s.preview_win].conceallevel = 2
    vim.wo[s.preview_win].concealcursor = 'nc'
    markdown_render(s, buf)
  end
  local n = vim.api.nvim_buf_line_count(buf)
  first = math.max(1, math.min(first or 1, n))
  last = math.max(first, math.min(last or first, n))
  vim.api.nvim_buf_clear_namespace(buf, ns_preview, 0, -1)
  for row = first - 1, last - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns_preview, row, 0, { line_hl_group = 'SynopsisCited', priority = 150 })
  end
  vim.api.nvim_win_set_cursor(s.preview_win, { first, 0 })
  vim.api.nvim_win_call(s.preview_win, function() vim.cmd 'normal! zz' end)
  local range = last > first and string.format('%d–%d', first, last) or tostring(first)
  vim.api.nvim_win_set_config(s.preview_win, { title = string.format(' %s:%s ', path, range), title_pos = 'center' })
end

---Every citation in the conversation buffer, in order: { row (1-based), s, e, path, line, last }.
local function buffer_citations(s)
  local out = {}
  for row, l in ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
    for _, c in ipairs(find_all(l, s.root)) do
      c.row = row
      table.insert(out, c)
    end
  end
  return out
end

---Move the conversation's cursor to the next (dir = 1) or previous (dir = -1) citation, wrapping
---around, and preview it.
local function step_citation(s, dir)
  local cites = buffer_citations(s)
  if #cites == 0 then return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(s.win))
  local pick
  if dir > 0 then
    for _, c in ipairs(cites) do
      if c.row > row or (c.row == row and c.s - 1 > col) then pick = c break end
    end
    pick = pick or cites[1]
  else
    for i = #cites, 1, -1 do
      local c = cites[i]
      if c.row < row or (c.row == row and c.s - 1 < col) then pick = c break end
    end
    pick = pick or cites[#cites]
  end
  vim.api.nvim_win_set_cursor(s.win, { pick.row, pick.s - 1 })
  M.preview(pick.path, pick.line, pick.last)
end

---Preview the citation under the conversation's cursor, if there is one.
local function preview_at_cursor(s)
  if not is_open(s) then return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(s.win))
  local line = vim.api.nvim_buf_get_lines(s.buf, row - 1, row, false)[1] or ''
  for _, c in ipairs(find_all(line, s.root)) do
    if col + 1 >= c.s and col + 1 <= c.e then
      if s.preview_path ~= c.path or s.preview_first ~= c.line then M.preview(c.path, c.line, c.last) end
      return
    end
  end
end

-- Questions and answers.

local function on_done(s)
  return function(r)
    s.pending = false
    s.tail = {}
    if r.cancelled then
      table.insert(s.items, { kind = 'meta', text = 'Cancelled.' })
    elseif r.error then
      table.insert(s.items, { kind = 'answer', text = '**Error:** ' .. r.error })
    else
      table.insert(s.items, { kind = 'answer', text = M.dollars(r.answer or '') })
    end
    if not r.cancelled then
      local n = #r.calls
      local tokens = (r.usage.prompt_tokens or 0) + (r.usage.completion_tokens or 0)
      table.insert(s.items, { kind = 'blank' })
      table.insert(s.items, { kind = 'meta', text = string.format('%d tool call%s · %.1f s · %s tokens', n, n == 1 and '' or 's',
        (vim.uv.hrtime() - s.started) / 1e9, M.thousands(tokens)) })
    end
    render(s)
    set_title(s)
    if is_open(s) and r.answer then
      local first = M.citations(r.answer, s.root)[1]
      if first then M.preview(first.path, first.line, first.last) end
    end
  end
end

local function on_call(s)
  return function(c)
    table.insert(s.tail, { kind = 'progress', text = label(c.name, c.args) })
    render(s)
  end
end

local function ask_model(s, question)
  local sent = question
  if s.tell_about then
    local a = s.tell_about
    sent = string.format('(asked while viewing %s%s) %s', a.path, a.line and (', line ' .. a.line) or '', question)
    s.tell_about = nil
  end
  s.convo = s.convo or loop.conversation {
    cfg = s.config.llm, system = system(), context = s.context, root = s.root, tools = TOOLS,
    tool_opts = { exclude = s.config.exclude, max_bytes = s.config.max_bytes }, max_rounds = s.config.ask.max_rounds,
    key = store.root_key(s.root), retry_ms = s.config.ask.retry_ms,
  }
  s.convo:ask(sent, { on_call = on_call(s), on_done = on_done(s) })
end

---Ask `question` in the open chat. Does nothing while an answer is still coming.
function M.send(question)
  local s = M.current
  if not is_open(s) or s.pending or not question or vim.trim(question) == '' then return false end
  question = vim.trim(question)
  s.pending, s.asked = true, true
  s.started = vim.uv.hrtime()
  s.items = vim.tbl_filter(function(it) return it.kind ~= 'hint' end, s.items)
  if #s.items > 0 then table.insert(s.items, { kind = 'blank' }) end
  table.insert(s.items, { kind = 'question', text = question })
  table.insert(s.items, { kind = 'blank' })
  set_title(s)
  if s.context then
    s.tail = {}
    render(s)
    ask_model(s, question)
  else
    s.tail = { { kind = 'progress', text = "Reading the repo's files…" } }
    render(s)
    s.queued = question
  end
  return true
end

---Close the chat's windows. A question still being answered is cancelled; the conversation is
---kept for the next time the chat opens for this repo. on_close runs unless a file was opened.
function M.close()
  local s = M.current
  if not s or s.closed then return end
  s.closed = true
  if s.queued then
    s.queued = nil
    s.pending = false
    s.tail = {}
    table.insert(s.items, { kind = 'meta', text = 'Cancelled.' })
  end
  if s.convo and s.convo:busy() then s.convo:cancel() end
  forget_markview(s.buf)
  for _, b in pairs(s.preview_bufs or {}) do
    forget_markview(b)
    if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  s.preview_bufs = {}
  for _, w in ipairs { s.preview_win, s.input_win, s.win } do
    if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  if s.preview_msg_buf and vim.api.nvim_buf_is_valid(s.preview_msg_buf) then pcall(vim.api.nvim_buf_delete, s.preview_msg_buf, { force = true }) end
  s.preview_win, s.preview_buf, s.preview_path, s.preview_msg_buf = nil, nil, nil, nil
  if s.origin and vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
  local on_close = s.on_close
  s.on_close = nil
  if on_close and not s.jumped then vim.schedule(on_close) end
  s.jumped = false
end

jump = function(s, path, line)
  s.jumped = true
  M.close()
  vim.cmd.edit(vim.fn.fnameescape(s.root .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd 'normal! zz'
end

---Open the citation under the cursor in the conversation (or the first one on its line).
function M.open_citation()
  local s = M.current
  if not is_open(s) then return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(s.win))
  local line = vim.api.nvim_buf_get_lines(s.buf, row - 1, row, false)[1] or ''
  local found = find_all(line, s.root)
  if #found == 0 then return vim.notify('synopsis: no path:line citation on this line', vim.log.levels.INFO) end
  local pick = found[1]
  for _, c in ipairs(found) do
    if col + 1 >= c.s and col + 1 <= c.e then pick = c end
  end
  jump(s, pick.path, pick.line)
end

---A Telescope picker of every citation in the conversation.
function M.locations()
  local s = M.current
  if not is_open(s) then return end
  local answers = {}
  for _, it in ipairs(s.items) do if it.kind == 'answer' then table.insert(answers, it.text) end end
  local cites = M.citations(table.concat(answers, '\n'), s.root)
  if #cites == 0 then return vim.notify('synopsis: no path:line citations in the answers', vim.log.levels.INFO) end
  local results = {}
  for _, c in ipairs(cites) do
    local ok, ls = pcall(vim.fn.readfile, s.root .. '/' .. c.path, '', c.line)
    local text = ok and ls[c.line] and vim.trim(ls[c.line]) or ''
    table.insert(results, string.format('%s:%d:1:%s', c.path, c.line, text))
  end
  local root = s.root
  s.jumped = true
  M.close()
  local pickers, finders = require 'telescope.pickers', require 'telescope.finders'
  local conf = require('telescope.config').values
  pickers.new({ cwd = root }, {
    prompt_title = 'Cited locations',
    finder = finders.new_table { results = results, entry_maker = require('telescope.make_entry').gen_from_vimgrep { cwd = root } },
    previewer = conf.grep_previewer { cwd = root },
    sorter = conf.generic_sorter {},
  }):find()
end

-- Windows.

local function send_input(s)
  if not vim.api.nvim_buf_is_valid(s.input_buf) then return end
  local text = table.concat(vim.api.nvim_buf_get_lines(s.input_buf, 0, -1, false), '\n')
  if vim.trim(text) == '' then return end
  if M.send(text) then vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { '' }) end
end

local function scroll(s, dir)
  if not vim.api.nvim_win_is_valid(s.win) then return end
  local n = math.max(1, math.floor(vim.api.nvim_win_get_height(s.win) / 2))
  vim.api.nvim_win_call(s.win, function() vim.cmd('normal! ' .. n .. vim.keycode(dir > 0 and '<C-e>' or '<C-y>')) end)
end

local function to_input(s)
  if not vim.api.nvim_win_is_valid(s.input_win) then return end
  vim.api.nvim_set_current_win(s.input_win)
  vim.cmd 'startinsert!'
end

local start

---Start a new conversation for this repo and file, dropping the current one.
function M.new_chat()
  local s = M.current
  if not s then return end
  local o = { root = s.root, config = s.config, about = s.about, on_close = s.on_close }
  s.on_close = nil
  M.close()
  M.sessions[s.root] = nil
  start(o)
end

---Window positions: the conversation and input on the left, the preview on the right when the
---screen is wide enough.
local function geometry(config)
  local input_h = 3
  local height = math.max(6, math.floor(vim.o.lines * 0.6))
  local row = math.max(0, math.floor((vim.o.lines - (height + input_h + 4)) / 2) - 1)
  local wide = config.ask.preview ~= false and vim.o.columns >= (config.ask.preview_min_columns or 120)
  local g = { height = height, input_h = input_h, row = row }
  if wide then
    local total = math.min(vim.o.columns - 4, 200)
    g.width = math.max(56, math.floor(0.42 * total))
    g.col = math.floor((vim.o.columns - total) / 2)
    g.preview = { col = g.col + g.width + 2, width = total - g.width - 2, height = height + input_h + 2 }
  else
    g.width = math.min(84, vim.o.columns - 4)
    g.col = math.floor((vim.o.columns - g.width) / 2)
  end
  return g
end

local function open_windows(s)
  local km = s.config.ask.keymaps or {}
  s.origin = vim.api.nvim_get_current_win()
  local g = geometry(s.config)
  local title = s.about and (' ' .. s.about.path .. ' ') or (' ' .. vim.fs.basename(s.root) .. ' ')

  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = 'wipe'
  vim.bo[s.buf].filetype = 'markdown'
  s.win = vim.api.nvim_open_win(s.buf, false, {
    relative = 'editor', width = g.width, height = g.height, row = g.row, col = g.col, style = 'minimal', border = 'rounded',
    title = title, title_pos = 'center',
  })
  for opt, v in pairs { wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = 'nc' } do
    vim.wo[s.win][opt] = v
  end

  if g.preview then
    s.preview_win = vim.api.nvim_open_win(preview_message(s, 'Cited lines appear here; Tab moves between citations.'), false, {
      relative = 'editor', width = g.preview.width, height = g.preview.height, row = g.row, col = g.preview.col,
      style = 'minimal', border = 'rounded', title = ' Preview ', title_pos = 'center',
    })
  end

  s.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.input_buf].bufhidden = 'wipe'
  s.input_win = vim.api.nvim_open_win(s.input_buf, true, {
    relative = 'editor', width = g.width, height = g.input_h, row = g.row + g.height + 2, col = g.col, style = 'minimal',
    border = 'rounded', title = ' Ask ', title_pos = 'left',
  })
  vim.wo[s.input_win].wrap = true
  set_title(s)

  local function map_keys(buf, modes, keys, fn, desc)
    if not keys then return end
    for _, k in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set(modes, k, fn, { buffer = buf, nowait = true, desc = 'synopsis: ' .. desc })
    end
  end
  -- The conversation.
  map_keys(s.buf, 'n', km.close, M.close, 'close the chat')
  map_keys(s.buf, 'n', km.open, M.open_citation, 'open the cited location')
  map_keys(s.buf, 'n', km.locations, M.locations, 'list the cited locations')
  map_keys(s.buf, 'n', km.input, function() to_input(s) end, 'type a question')
  map_keys(s.buf, 'n', km.next_citation, function() step_citation(s, 1) end, 'preview the next citation')
  map_keys(s.buf, 'n', km.prev_citation, function() step_citation(s, -1) end, 'preview the previous citation')
  map_keys(s.buf, 'n', km.new_chat, M.new_chat, 'start a new chat')
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = s.buf, callback = function() preview_at_cursor(s) end })
  -- The input panel.
  map_keys(s.input_buf, { 'i', 'n' }, '<CR>', function() send_input(s) end, 'send the question')
  map_keys(s.input_buf, { 'i', 'n' }, km.chat, function()
    vim.cmd 'stopinsert'
    if vim.api.nvim_win_is_valid(s.win) then vim.api.nvim_set_current_win(s.win) end
  end, 'go to the chat')
  map_keys(s.input_buf, { 'i', 'n' }, km.scroll_down, function() scroll(s, 1) end, 'scroll the chat down')
  map_keys(s.input_buf, { 'i', 'n' }, km.scroll_up, function() scroll(s, -1) end, 'scroll the chat up')
  map_keys(s.input_buf, { 'i', 'n' }, km.new_chat, M.new_chat, 'start a new chat')
  map_keys(s.input_buf, { 'i', 'n' }, '<C-c>', M.close, 'close the chat')
  map_keys(s.input_buf, 'n', 'q', M.close, 'close the chat')

  -- A session is reused when the chat reopens, so tie these to this opening of its windows.
  s.opening = (s.opening or 0) + 1
  local opening = s.opening
  for _, w in ipairs { s.win, s.input_win, s.preview_win } do
    if w then
      vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(w), once = true,
        callback = function()
          vim.schedule(function() if M.current == s and s.opening == opening then M.close() end end)
        end,
      })
    end
  end
end

start = function(o)
  if M.current and not M.current.closed then M.close() end
  local s = M.sessions[o.root]
  if not s then
    s = { root = o.root, items = {}, tail = {}, pending = false }
    M.sessions[o.root] = s
    local hint = o.about and string.format('Asking about `%s`', o.about.path) or ('Ask about ' .. vim.fs.basename(o.root))
    table.insert(s.items, { kind = 'hint', text = hint })
    s.about, s.tell_about = o.about, o.about
  elseif o.about and (not s.about or s.about.path ~= o.about.path) then
    if #s.items > 0 then table.insert(s.items, { kind = 'blank' }) end
    table.insert(s.items, { kind = 'note', text = string.format('Now viewing `%s`', o.about.path) })
    s.about, s.tell_about = o.about, o.about
  end
  s.config, s.on_close, s.closed, s.jumped = o.config, o.on_close, false, false
  M.current = s
  open_windows(s)
  render(s)
  vim.cmd 'startinsert'
  if not s.context and not s.building then
    s.building = true
    local opts = { exclude = s.config.exclude, max_bytes = s.config.max_bytes, max_map_chars = s.config.ask.max_map_chars }
    map.build(s.root, opts, function(text)
      s.building = false
      s.context = string.format('REPOSITORY: %s\n\nFILE MAP:\n%s\n', vim.fs.basename(s.root), text)
      if s.queued then
        local q = s.queued
        s.queued = nil
        s.tail = {}
        render(s)
        ask_model(s, q)
      end
    end)
  end
  if o.question and vim.trim(o.question) ~= '' then M.send(o.question) end
end

---Open the chat for the repo at o.root, with o.config (the plugin's settings). The repo's
---earlier conversation is shown and continued. o.question is asked straight away if given;
---o.about = { path, line } names the file the user is looking at; o.on_close runs when the chat
---is closed (not when a file is opened from it).
function M.open(o)
  local root, config = o.root, o.config
  if config.consent == 'always' or consent.get(root) == 'allow' then return start(o) end
  if consent.get(root) == 'deny' then
    return vim.notify('synopsis: sending files is off for ' .. root .. ' (:SynopsisAllow turns it on)', vim.log.levels.WARN)
  end
  local host = (config.llm.url or ''):match '^%a+://([^/:]+)' or config.llm.url
  vim.ui.select({ 'Allow', "Don't allow" }, {
    prompt = string.format('Send files from %s to %s to answer questions?', root, host),
  }, function(choice)
    if choice == 'Allow' then
      consent.set(root, 'allow')
      start(o)
    elseif choice then
      consent.set(root, 'deny')
    end
  end)
end

return M
