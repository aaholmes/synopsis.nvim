-- The :SynopsisAsk chat. open{ root, config, question?, about?, on_close? } checks consent and
-- opens two floating windows: the conversation, and an input panel below it where questions are
-- typed. Each question runs the question loop (ask.lua) with the repo's file map; tool calls show
-- as muted progress lines until the answer replaces them. In the conversation: open a path:line
-- citation, or list every citation in Telescope. Closing either window closes both and cancels
-- any request in flight.
local consent = require 'synopsis.consent'
local map = require 'synopsis.map'
local store = require 'synopsis.store'
local loop = require 'synopsis.ask'
local M = {}

local TOOLS = { 'rg', 'read', 'outline' }
local ns = vim.api.nvim_create_namespace 'synopsis.answer'
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
---and hints muted (Comment). Defined with default = true, so a colour scheme or user wins.
function M.highlights()
  local fn = vim.api.nvim_get_hl(0, { name = 'Function', link = false })
  vim.api.nvim_set_hl(0, 'SynopsisQuestion', { fg = fn.fg, ctermfg = fn.ctermfg, bold = true, default = true })
  for _, g in ipairs { 'SynopsisProgress', 'SynopsisMeta', 'SynopsisHint' } do
    vim.api.nvim_set_hl(0, g, { link = 'Comment', default = true })
  end
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

---Each path:line in `line` that names a file in root: { s, e, path, line } (s, e are byte columns).
local function find_all(line, root)
  local out, init = {}, 1
  while true do
    local s, e, path, n = line:find('([%w_%-%./]+):(%d+)', init)
    if not s then break end
    init = e + 1
    path = path:gsub('^%./', '')
    local st = path:find '[%./]' and vim.uv.fs_stat(root .. '/' .. path)
    if st and st.type == 'file' then table.insert(out, { s = s, e = e, path = path, line = tonumber(n) }) end
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
        table.insert(out, { path = c.path, line = c.line })
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
-- progress, meta (the footer), hint, or blank. Everything but questions is indented 2 spaces.
local HL = { question = 'SynopsisQuestion', progress = 'SynopsisProgress', meta = 'SynopsisMeta', hint = 'SynopsisHint' }

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

local function markdown_render(s)
  if s.config.ask.render == false then return end
  local mv = package.loaded.markview
  if mv and mv.strict_render then
    pcall(mv.strict_render.clear, mv.strict_render, s.buf)
    pcall(mv.strict_render.render, mv.strict_render, s.buf)
  end
  local image = rawget(_G, 'Snacks') and Snacks.image
  if not s.snacks and image and image.supports_terminal and image.supports_terminal() then
    s.snacks = true
    pcall(image.doc.attach, s.buf)
  end
end

local function render(s)
  if not vim.api.nvim_buf_is_valid(s.buf) then return end
  local items = vim.list_extend(vim.deepcopy(s.items), s.tail)
  local lines, marks = layout(items)
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, m.row, 0, { end_col = m.len, hl_group = m.hl, priority = 150 })
  end
  markdown_render(s)
  if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_get_current_win() ~= s.win then
    pcall(vim.api.nvim_win_set_cursor, s.win, { #lines, 0 })
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'SynopsisAnswerRendered', data = { buf = s.buf, win = s.win } })
end

local function set_title(s)
  if not vim.api.nvim_win_is_valid(s.input_win) then return end
  local title = s.pending and ' waiting for the answer… ' or ' Ask · Enter sends · Ctrl-k to the chat '
  vim.api.nvim_win_set_config(s.input_win, { title = title, title_pos = 'left' })
end

local function on_done(s)
  return function(r)
    if s.closed then return end
    s.pending = false
    s.tail = {}
    if r.cancelled then
      table.insert(s.items, { kind = 'meta', text = 'Cancelled.' })
    elseif r.error then
      table.insert(s.items, { kind = 'answer', text = '**Error:** ' .. r.error })
    else
      table.insert(s.items, { kind = 'answer', text = M.dollars(r.answer or '') })
    end
    local n = #r.calls
    local tokens = (r.usage.prompt_tokens or 0) + (r.usage.completion_tokens or 0)
    table.insert(s.items, { kind = 'blank' })
    table.insert(s.items, { kind = 'meta', text = string.format('%d tool call%s · %.1f s · %s tokens', n, n == 1 and '' or 's',
      (vim.uv.hrtime() - s.started) / 1e9, M.thousands(tokens)) })
    render(s)
    set_title(s)
  end
end

local function on_call(s)
  return function(c)
    if s.closed then return end
    table.insert(s.tail, { kind = 'progress', text = label(c.name, c.args) })
    render(s)
  end
end

---Close both windows and stop any request in flight. on_close runs unless a citation was opened.
function M.close()
  local s = M.current
  if not s or s.closed then return end
  s.closed = true
  if s.handle then s.handle.cancel() end
  local mv = package.loaded.markview
  if mv and mv.strict_render then pcall(mv.strict_render.clear, mv.strict_render, s.buf) end
  for _, w in ipairs { s.input_win, s.win } do
    if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  if s.origin and vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
  if s.on_close and not s.jumped then vim.schedule(s.on_close) end
end

local function jump(s, path, line)
  s.jumped = true
  M.close()
  vim.cmd.edit(vim.fn.fnameescape(s.root .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd 'normal! zz'
end

---Open the citation under the cursor in the conversation (or the first one on its line).
function M.open_citation()
  local s = M.current
  if not s then return end
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
  if not s then return end
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

local function ask_model(s, question)
  local sent = question
  if s.about and not s.handle then
    sent = string.format('(asked while viewing %s%s) %s', s.about.path, s.about.line and (', line ' .. s.about.line) or '', question)
  end
  if s.handle then return s.handle.follow_up(sent, on_done(s)) end
  local tool_opts = { exclude = s.config.exclude, max_bytes = s.config.max_bytes }
  s.handle = loop.start {
    cfg = s.config.llm, system = system(), context = s.context, question = sent, root = s.root, tools = TOOLS,
    tool_opts = tool_opts, max_rounds = s.config.ask.max_rounds, key = store.root_key(s.root), retry_ms = s.config.ask.retry_ms,
    on_call = on_call(s), on_done = on_done(s),
  }
end

---Ask `question` in the open chat. Does nothing while an answer is still coming.
function M.send(question)
  local s = M.current
  if not s or s.closed or s.pending or not question or vim.trim(question) == '' then return false end
  question = vim.trim(question)
  s.pending, s.asked = true, true
  s.started = vim.uv.hrtime()
  -- The hint goes once the conversation starts.
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

local function open_windows(s)
  local km = s.config.ask.keymaps or {}
  s.origin = vim.api.nvim_get_current_win()
  local width = math.min(84, vim.o.columns - 4)
  local input_h = 3
  local height = math.max(6, math.floor(vim.o.lines * 0.6))
  local row = math.max(0, math.floor((vim.o.lines - (height + input_h + 4)) / 2) - 1)
  local col = math.floor((vim.o.columns - width) / 2)
  local title = s.about and (' ' .. s.about.path .. ' ') or (' ' .. vim.fs.basename(s.root) .. ' ')

  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = 'wipe'
  vim.bo[s.buf].filetype = 'markdown'
  s.win = vim.api.nvim_open_win(s.buf, false, {
    relative = 'editor', width = width, height = height, row = row, col = col, style = 'minimal', border = 'rounded',
    title = title, title_pos = 'center',
  })
  for opt, v in pairs { wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = 'nc' } do
    vim.wo[s.win][opt] = v
  end

  s.input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.input_buf].bufhidden = 'wipe'
  s.input_win = vim.api.nvim_open_win(s.input_buf, true, {
    relative = 'editor', width = width, height = input_h, row = row + height + 2, col = col, style = 'minimal',
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
  -- The input panel.
  map_keys(s.input_buf, { 'i', 'n' }, '<CR>', function() send_input(s) end, 'send the question')
  map_keys(s.input_buf, { 'i', 'n' }, km.chat, function()
    vim.cmd 'stopinsert'
    if vim.api.nvim_win_is_valid(s.win) then vim.api.nvim_set_current_win(s.win) end
  end, 'go to the chat')
  map_keys(s.input_buf, { 'i', 'n' }, km.scroll_down, function() scroll(s, 1) end, 'scroll the chat down')
  map_keys(s.input_buf, { 'i', 'n' }, km.scroll_up, function() scroll(s, -1) end, 'scroll the chat up')
  map_keys(s.input_buf, { 'i', 'n' }, '<C-c>', M.close, 'close the chat')
  map_keys(s.input_buf, 'n', 'q', M.close, 'close the chat')

  for _, w in ipairs { s.win, s.input_win } do
    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(w), once = true,
      callback = function() vim.schedule(function() if M.current == s then M.close() end end) end,
    })
  end
end

local function start(o)
  if M.current and not M.current.closed then M.close() end
  local s = { root = o.root, config = o.config, about = o.about, on_close = o.on_close, items = {}, tail = {}, pending = false }
  M.current = s
  local hint = s.about and string.format('Asking about `%s`', s.about.path) or ('Ask about ' .. vim.fs.basename(s.root))
  table.insert(s.items, { kind = 'hint', text = hint })
  open_windows(s)
  render(s)
  vim.cmd 'startinsert'
  local tool_opts = { exclude = s.config.exclude, max_bytes = s.config.max_bytes }
  map.build(s.root, vim.tbl_extend('force', tool_opts, { max_map_chars = s.config.ask.max_map_chars }), function(text)
    if s.closed then return end
    s.context = string.format('REPOSITORY: %s\n\nFILE MAP:\n%s\n', vim.fs.basename(s.root), text)
    if s.queued then
      local q = s.queued
      s.queued = nil
      s.tail = {}
      render(s)
      ask_model(s, q)
    end
  end)
  if o.question and vim.trim(o.question) ~= '' then M.send(o.question) end
end

---Open the chat for the repo at o.root, with o.config (the plugin's settings). o.question is
---asked straight away if given; o.about = { path, line } names the file the user is looking at;
---o.on_close runs when the chat is closed (not when a citation is opened).
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
