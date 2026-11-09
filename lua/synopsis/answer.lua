-- The :SynopsisAsk chat. open{ root, config, question?, about?, on_close? } checks consent and
-- opens up to three floating windows: the conversation, an input panel below it where questions
-- are typed, and on wide screens a preview pane on the right that shows a cited file with the
-- cited lines highlighted. Each repo keeps its conversation for the editor session, so closing
-- and reopening the chat continues it. Each question runs the question loop (ask.lua) with the
-- repo's file map; tool calls show as muted progress lines until the answer replaces them.
-- The typing cursor stays in the input panel, where every key works; a separate link cursor
-- (s.link), moved with Tab, selects a citation in the conversation and previews it.
-- Closing any window closes all of them and cancels a question still being answered.
-- Opened with o.dock = { prompt, picker } (from Telescope, on a wide screen), the chat instead
-- sits in a column beside the picker, which stays open: the cited lines are shown in Telescope's
-- preview, the picker key moves between the two, and moving to an ordinary window closes both.
local consent = require 'synopsis.consent'
local files = require 'synopsis.files'
local map = require 'synopsis.map'
local store = require 'synopsis.store'
local loop = require 'synopsis.ask'
local M = { sessions = {} }

local TOOLS = { 'rg', 'read', 'outline' }
local ns = vim.api.nvim_create_namespace 'synopsis.answer'
local ns_preview = vim.api.nvim_create_namespace 'synopsis.preview'
local ns_link = vim.api.nvim_create_namespace 'synopsis.link'
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
---and hints muted (Comment); cited lines in the preview like a selection (Visual); the selected
---link like the match under the cursor while searching (IncSearch). Defined with default = true, so a colour
---scheme or user wins.
function M.highlights()
  local fn = vim.api.nvim_get_hl(0, { name = 'Function', link = false })
  vim.api.nvim_set_hl(0, 'SynopsisQuestion', { fg = fn.fg, ctermfg = fn.ctermfg, bold = true, default = true })
  for _, g in ipairs { 'SynopsisProgress', 'SynopsisMeta', 'SynopsisHint' } do
    vim.api.nvim_set_hl(0, g, { link = 'Comment', default = true })
  end
  vim.api.nvim_set_hl(0, 'SynopsisCited', { link = 'Visual', default = true })
  vim.api.nvim_set_hl(0, 'SynopsisLink', { link = 'IncSearch', default = true })
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

local draw_link -- defined below: highlight the selected link

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
  pcall(vim.api.nvim_win_set_cursor, s.win, { #lines, 0 })
  draw_link(s)
  vim.api.nvim_exec_autocmds('User', { pattern = 'SynopsisAnswerRendered', data = { buf = s.buf, win = s.win } })
end

local function set_title(s)
  if not (s.input_win and vim.api.nvim_win_is_valid(s.input_win)) then return end
  local title = s.pending and ' waiting for the answer… ' or ' Ask · Enter sends · Tab picks a link '
  vim.api.nvim_win_set_config(s.input_win, { title = title, title_pos = 'left' })
end

-- The preview pane.

local jump -- defined below: close the chat and open a file at a line, with edit, split, vsplit or tabedit

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

---The window citations are shown in: Telescope's preview when docked, else the chat's own pane.
local function preview_win(s)
  local w = s.dock and s.dock.picker.preview_win or s.preview_win
  return w and vim.api.nvim_win_is_valid(w) and w or nil
end

---Scroll the preview half a window down (dir 1) or up (-1) as Telescope's <C-d> and <C-u> do:
---with <C-e> and <C-y>, which also scroll a file shorter than the window, unlike Vim's <C-d>.
local function scroll_preview(s, dir)
  local w = preview_win(s)
  if not w then return end
  local count = math.max(1, math.floor(vim.api.nvim_win_get_height(w) / 2))
  vim.api.nvim_win_call(w, function() vim.cmd('normal! ' .. count .. vim.keycode(dir > 0 and '<C-e>' or '<C-y>')) end)
end

local PREVIEW_OPTS = { 'wrap', 'linebreak', 'number', 'conceallevel', 'concealcursor', 'scrolloff' }

local function set_preview_title(s, win, title)
  if s.dock then
    local p = s.dock.picker
    local border = p.layout and p.layout.preview and p.layout.preview.border
    if border then pcall(border.change_title, border, title) end
    p.preview_title = title -- so Telescope sets its own title again when it previews a file
  else
    vim.api.nvim_win_set_config(win, { title = title, title_pos = 'center' })
  end
end

---Hand Telescope's preview back to the picker's selected file, with its window options.
local function give_back_preview(s)
  local d = s.dock
  if not (d and d.saved_wo) then return end
  local w = d.picker.preview_win
  if w and vim.api.nvim_win_is_valid(w) then
    for k, v in pairs(d.saved_wo) do vim.wo[w][k] = v end
    pcall(d.picker.refresh_previewer, d.picker)
  end
  d.saved_wo = nil
  s.preview_path, s.preview_first, s.preview_buf = nil, nil, nil
end

local BLOCK_MAX = 50

---The last line of what a single-line citation of `line` stands for: the largest syntax node
---that starts on that line (a function, a loop, a statement), if at most BLOCK_MAX lines long;
---else the line itself. A node holding statements on later lines (a function's body, which
---starts with its first statement) is not one: a line inside a function stands for itself, not
---for the rest of the function. Found with Tree-sitter, so it needs a parser for the language.
local function block_end(buf, line)
  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype or '')
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not (ok and parser) then return line end
  local tree = parser:parse()[1]
  if not tree then return line end
  local root = tree:root()
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
  local col = (text:find '%S' or 1) - 1
  local node = root:named_descendant_for_range(line - 1, col, line - 1, col)
  local last = line
  local prev
  while node and node:id() ~= root:id() do
    local sr, _, er, ec = node:range()
    if sr ~= line - 1 then break end -- starts on an earlier line: it encloses the line instead
    if prev then
      local _, _, prev_er = prev:range()
      for child in node:iter_children() do
        if child:named() and child:start() > prev_er then return last end -- a list of statements
      end
    end
    local e = (ec == 0 and er > sr) and er or er + 1 -- 1-based last line
    if e - line + 1 > BLOCK_MAX then break end
    last = math.max(last, e)
    prev, node = node, node:parent()
  end
  return last
end

---Show path in the preview with lines first..last highlighted. Without last, the code block that
---starts on line first is highlighted (see block_end).
function M.preview(path, first, last)
  local s = M.current
  if not is_open(s) then return end
  local win = preview_win(s)
  if not win then return end
  if s.dock and not s.dock.saved_wo then
    s.dock.saved_wo = {}
    for _, k in ipairs(PREVIEW_OPTS) do s.dock.saved_wo[k] = vim.wo[win][k] end
  end
  s.preview_path, s.preview_first = path, first
  local why, text = files.skip_reason(s.root, path, { exclude = s.config.exclude, max_bytes = s.config.max_bytes })
  local buf
  if why then
    buf = preview_message(s, path .. ': not shown (' .. why .. ')')
    s.preview_buf = buf
    vim.api.nvim_win_set_buf(win, buf)
    set_preview_title(s, win, ' ' .. path .. ' ')
    return
  end
  buf = preview_buffer(s, path, text)
  s.preview_buf = buf
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  vim.wo[win].number = true
  vim.wo[win].scrolloff = 0 -- else a large scrolloff pulls the cited lines back towards the middle
  if vim.b[buf].synopsis_markdown then
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = 'nc'
    markdown_render(s, buf)
  end
  local n = vim.api.nvim_buf_line_count(buf)
  first = math.max(1, math.min(first or 1, n))
  last = math.max(first, math.min(last or block_end(buf, first), n))
  vim.api.nvim_buf_clear_namespace(buf, ns_preview, 0, -1)
  for row = first - 1, last - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns_preview, row, 0, { line_hl_group = 'SynopsisCited', priority = 150 })
  end
  -- Near the top, with three lines of context above, so the cited lines have room below.
  vim.api.nvim_win_call(win, function() vim.fn.winrestview { topline = math.max(1, first - 3), lnum = first, col = 0 } end)
  local range = last > first and string.format('%d–%d', first, last) or tostring(first)
  set_preview_title(s, win, string.format(' %s:%s ', path, range))
  if s.dock then
    -- Telescope fires this whenever its preview changes, with the preview buffer current;
    -- listeners such as filetype border colours then treat the citation like a previewed file.
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_exec_autocmds('User', { pattern = 'TelescopePreviewerLoaded', data = {
        title = path, bufname = s.root .. '/' .. path, filetype = vim.bo[buf].filetype, synopsis_citation = true } })
    end)
  end
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

-- The selected link. The conversation never keeps the focus: s.link is the index of the selected
-- citation in it, highlighted, kept in view, and shown in the preview.

draw_link = function(s)
  vim.api.nvim_buf_clear_namespace(s.buf, ns_link, 0, -1)
  local c = s.link and buffer_citations(s)[s.link]
  if not c then return end
  -- Above markview's inline code (priority 4096), which would otherwise colour over it.
  vim.api.nvim_buf_set_extmark(s.buf, ns_link, c.row - 1, c.s - 1, { end_col = c.e, hl_group = 'SynopsisLink', priority = 10000 })
  return c
end

-- Beside a picker, the picker's selection follows the previewed citation, so the results, the
-- preview and the synopsis pane agree on one file whichever side has the focus.

---The index in picker p's results of the entry for the absolute path file, if listed.
local function entry_index(p, file)
  if not p.manager then return end
  local base = vim.fn.resolve(p.cwd or vim.fn.getcwd())
  local i = 0
  for entry in p.manager:iter() do
    i = i + 1
    local name = entry.path or entry.filename or (type(entry.value) == 'string' and entry.value) or nil
    if name then
      name = name:match '^/' and name or vim.fs.joinpath(base, name)
      if vim.fs.normalize(vim.fn.resolve(name)) == file then return i end
    end
  end
end

---Select result i in p without Telescope previewing it, which would replace the citation.
local function select_quietly(p, i)
  local own = rawget(p, 'refresh_previewer')
  p.refresh_previewer = function() end
  pcall(p.set_selection, p, p:get_row(i))
  p.refresh_previewer = own
end

---Select the citation's file in the picker. If it is not among the results, clear the prompt
---and select it when the results come back. The picker's selection is then the chat's doing,
---so it is not noted as a file the user moved to.
local function follow_in_picker(s, path)
  local p = s.dock.picker
  local file = vim.fs.normalize(s.root .. '/' .. path)
  local function select(i)
    select_quietly(p, i)
    s.about = { path = path }
  end
  local i = entry_index(p, file)
  if i then return select(i) end
  if p:_get_prompt() == '' then return end
  -- Telescope previews its first result when the new results come back, which would replace
  -- the citation; it previews nothing until then (or for at most 3 s).
  local own = rawget(p, 'refresh_previewer')
  p.refresh_previewer = function() end
  local restored = false
  local function restore()
    if restored then return end
    restored = true
    p.refresh_previewer = own
  end
  vim.defer_fn(restore, 3000)
  local function done()
    for k, f in ipairs(p._completion_callbacks) do
      if f == done then table.remove(p._completion_callbacks, k) break end
    end
    restore()
    local c = s.link and buffer_citations(s)[s.link]
    if s.closed or M.current ~= s or not s.dock or not c or c.path ~= path then return end
    local j = entry_index(p, file)
    if j then select(j) end
  end
  p:register_completion_callback(done)
  p:reset_prompt ''
end

---Select citation i (wrapping around), keep it in view, and preview it.
local function select_link(s, i)
  local cites = buffer_citations(s)
  if #cites == 0 then return end
  s.link = (i - 1) % #cites + 1
  local c = draw_link(s)
  pcall(vim.api.nvim_win_set_cursor, s.win, { c.row, c.s - 1 })
  M.preview(c.path, c.line, c.last)
  if s.dock then follow_in_picker(s, c.path) end
end

local function step_link(s, dir)
  if not s.link then return select_link(s, dir > 0 and 1 or 0) end
  select_link(s, s.link + dir)
end

---Select the citation at (row, col) of the conversation (1-based row, 0-based col), if any.
local function link_at(s, row, col)
  for i, c in ipairs(buffer_citations(s)) do
    if c.row == row and col + 1 >= c.s and col + 1 <= c.e then return select_link(s, i) end
  end
end

-- Questions and answers.

local layout_rows -- defined below: how many lines the conversation's items take

local function on_done(s)
  return function(r)
    s.pending = false
    s.tail = {}
    local start_row = layout_rows(s.items) + 1
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
      -- Show the answer from its start, and select its first link.
      pcall(vim.api.nvim_win_set_cursor, s.win, { start_row, 0 })
      vim.api.nvim_win_call(s.win, function() vim.cmd 'normal! zt' end)
      for i, c in ipairs(buffer_citations(s)) do
        if c.row >= start_row then
          select_link(s, i)
          break
        end
      end
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
---Docked beside a picker, the picker gets its full width and the focus back, unless
---opts.picker (close the picker too, then focus opts.focus if given), opts.keep_dock (another
---chat is about to take the column) or opts.picker_gone (the picker is closing already).
function M.close(opts)
  opts = opts or {}
  local s = M.current
  if not s or s.closed then return end
  s.closed = true
  local dock = s.dock
  if dock then
    pcall(vim.api.nvim_del_augroup_by_name, 'synopsis.dock')
    if not opts.picker_gone then give_back_preview(s) end
    -- Our preview buffers are deleted below, which would close a window still showing one.
    local w = dock.picker.preview_win
    if w and vim.api.nvim_win_is_valid(w) then
      local b = vim.api.nvim_win_get_buf(w)
      for _, pb in pairs(s.preview_bufs or {}) do
        if pb == b then
          local empty = vim.api.nvim_create_buf(false, true)
          vim.bo[empty].bufhidden = 'wipe'
          vim.api.nvim_win_set_buf(w, empty)
        end
      end
    end
  end
  local alive = dock and not opts.picker_gone and vim.api.nvim_buf_is_valid(dock.prompt) and dock.picker.prompt_win
    and vim.api.nvim_win_is_valid(dock.picker.prompt_win)
  if alive and not opts.picker and not opts.keep_dock then vim.api.nvim_set_current_win(dock.picker.prompt_win) end
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
  for _, w in pairs { s.preview_win, s.input_win, s.win } do -- pairs: preview_win is nil when docked
    if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  if s.preview_msg_buf and vim.api.nvim_buf_is_valid(s.preview_msg_buf) then pcall(vim.api.nvim_buf_delete, s.preview_msg_buf, { force = true }) end
  s.preview_win, s.preview_buf, s.preview_path, s.preview_msg_buf = nil, nil, nil, nil
  if dock then
    s.dock, s.on_close, s.jumped = nil, nil, false
    if alive and opts.picker then
      require('telescope.actions').close(dock.prompt)
      if opts.focus and vim.api.nvim_win_is_valid(opts.focus) then vim.api.nvim_set_current_win(opts.focus) end
    elseif alive and not opts.keep_dock then
      require('synopsis.telescope').undock(dock.picker, dock.prompt)
      vim.api.nvim_set_current_win(dock.picker.prompt_win)
    end
    return
  end
  if s.origin and vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
  local on_close = s.on_close
  s.on_close = nil
  if on_close and not s.jumped then vim.schedule(on_close) end
  s.jumped = false
end

jump = function(s, path, line, cmd)
  s.jumped = true
  M.close { picker = true }
  vim.cmd[cmd or 'edit'](vim.fn.fnameescape(s.root .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd 'normal! zz'
end

---Open the selected link, with cmd: edit (the default), split, vsplit or tabedit.
function M.open_link(cmd)
  local s = M.current
  if not is_open(s) then return end
  local c = s.link and buffer_citations(s)[s.link]
  if not c then return vim.notify('synopsis: no link selected (Tab selects one)', vim.log.levels.INFO) end
  jump(s, c.path, c.line, cmd)
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
  M.close { picker = true }
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

---<CR> in the input: send the question, or with nothing typed, open the selected link.
local function send_input(s)
  if not vim.api.nvim_buf_is_valid(s.input_buf) then return end
  local text = table.concat(vim.api.nvim_buf_get_lines(s.input_buf, 0, -1, false), '\n')
  if vim.trim(text) == '' then return M.open_link() end
  if M.send(text) then vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { '' }) end
end

local function to_input(s)
  if not vim.api.nvim_win_is_valid(s.input_win) then return end
  vim.api.nvim_set_current_win(s.input_win)
  vim.cmd 'startinsert!'
  -- Leaving Telescope's prompt (a prompt buffer) ends Insert mode after this runs; start it again.
  vim.schedule(function()
    if vim.api.nvim_get_current_win() == s.input_win and vim.api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then vim.cmd 'startinsert!' end
  end)
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

layout_rows = function(items) return #(layout(items)) end

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

---Docked: the conversation and input fill the box the picker freed on its right.
local function dock_geometry(box)
  local input_h = 3
  return { row = box.row, col = box.col, width = box.width - 2, input_h = input_h,
    height = math.max(3, box.height - (input_h + 2) - 2) }
end

local function to_prompt(s)
  if not (s.dock and s.dock.picker.prompt_win and vim.api.nvim_win_is_valid(s.dock.picker.prompt_win)) then return end
  local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == 'i'
  vim.api.nvim_set_current_win(s.dock.picker.prompt_win)
  if not insert then vim.cmd 'startinsert!' end
end

local function open_windows(s)
  local km = s.config.ask.keymaps or {}
  s.origin = vim.api.nvim_get_current_win()
  local g = s.dock and dock_geometry(s.dock.picker._synopsis_dock) or geometry(s.config)
  local title = ' Chat · ' .. vim.fs.basename(s.root) .. ' ' -- the chat is about the project

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
  -- A float copies the options of the window it is opened from, so always set this. Beside a
  -- picker, the chat uses Telescope's groups, so it is coloured like the picker.
  vim.wo[s.win].winhighlight = s.dock
    and 'Normal:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder,FloatTitle:TelescopeResultsTitle' or ''

  if g.preview and not s.dock then
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
  vim.wo[s.input_win].wrap, vim.wo[s.input_win].linebreak = true, true
  vim.wo[s.input_win].winhighlight = s.dock
    and 'Normal:TelescopePromptNormal,FloatBorder:TelescopePromptBorder,FloatTitle:TelescopePromptTitle' or ''
  if s.preview_win then vim.wo[s.preview_win].winhighlight = '' end
  set_title(s)

  local function map_keys(buf, modes, keys, fn, desc)
    if not keys then return end
    for _, k in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set(modes, k, fn, { buffer = buf, nowait = true, desc = 'synopsis: ' .. desc })
    end
  end
  -- Every key is in the input panel, where the typing cursor stays. The conversation never keeps
  -- the focus: entering it (with the mouse) selects the link there and goes back to the input.
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = s.buf,
    callback = function()
      vim.schedule(function()
        if not (is_open(s) and vim.api.nvim_get_current_win() == s.win) then return end
        local row, col = unpack(vim.api.nvim_win_get_cursor(s.win))
        link_at(s, row, col)
        to_input(s)
      end)
    end,
  })
  -- No completion menu in the input (blink.cmp and others honour this).
  vim.b[s.input_buf].completion = false
  local function input_keys()
    map_keys(s.input_buf, { 'i', 'n' }, km.open or '<CR>', function() send_input(s) end, 'send the question, or open the selected link')
    map_keys(s.input_buf, { 'i', 'n' }, km.next_citation, function() step_link(s, 1) end, 'select the next link')
    map_keys(s.input_buf, { 'i', 'n' }, km.prev_citation, function() step_link(s, -1) end, 'select the previous link')
    map_keys(s.input_buf, { 'i', 'n' }, km.open_split, function() M.open_link 'split' end, 'open the selected link in a split')
    map_keys(s.input_buf, { 'i', 'n' }, km.open_vsplit, function() M.open_link 'vsplit' end, 'open the selected link in a vertical split')
    map_keys(s.input_buf, { 'i', 'n' }, km.open_tab, function() M.open_link 'tabedit' end, 'open the selected link in a tab')
    map_keys(s.input_buf, { 'i', 'n' }, km.new_chat, M.new_chat, 'start a new chat')
    map_keys(s.input_buf, { 'i', 'n' }, '<C-c>', M.close, 'close the chat')
    map_keys(s.input_buf, { 'i', 'n' }, km.scroll_preview_down, function() scroll_preview(s, 1) end, 'scroll the preview down')
    map_keys(s.input_buf, { 'i', 'n' }, km.scroll_preview_up, function() scroll_preview(s, -1) end, 'scroll the preview up')
    if s.dock then map_keys(s.input_buf, { 'i', 'n' }, km.picker, function() to_prompt(s) end, 'go to the picker') end
  end
  input_keys()
  map_keys(s.input_buf, 'n', km.close, M.close, 'close the chat')
  -- Alt-arrows (Option-arrows on a Mac) move by words, as in other text fields. Unmapped, Neovim
  -- reads Alt+key as Esc then the key, and Esc closes the chat.
  map_keys(s.input_buf, 'i', '<M-Left>', '<C-Left>', 'move back a word')
  map_keys(s.input_buf, 'i', '<M-Right>', '<C-Right>', 'move forward a word')
  map_keys(s.input_buf, 'n', '<M-Left>', 'b', 'move back a word')
  map_keys(s.input_buf, 'n', '<M-Right>', 'w', 'move forward a word')
  map_keys(s.input_buf, 'n', km.locations, M.locations, 'list the cited locations')
  -- Other plugins map keys in each buffer on InsertEnter (llama.vim its trigger, blink.cmp <C-n>
  -- and <Tab>), and llama.vim unmaps <Tab> and <S-Tab> on every cursor move in Insert mode; map
  -- ours again after them.
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'CursorMovedI', 'InsertLeave' }, {
    buffer = s.input_buf,
    callback = function() vim.schedule(function() if vim.api.nvim_buf_is_valid(s.input_buf) then input_keys() end end) end,
  })

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
  if s.dock then
    -- The picker no longer closes itself when its prompt loses the focus; moving to an ordinary
    -- window closes both.
    local group = vim.api.nvim_create_augroup('synopsis.dock', { clear = true })
    -- The citation stays in Telescope's preview until Telescope previews a file of its own (the
    -- selection moved); its window options then go back to Telescope's.
    vim.api.nvim_create_autocmd('User', {
      group = group, pattern = 'TelescopePreviewerLoaded',
      callback = function(ev)
        if (ev.data or {}).synopsis_citation or M.current ~= s or s.closed or not s.dock then return end
        local w = s.dock.picker.preview_win
        if not (w and vim.api.nvim_win_is_valid(w) and s.dock.saved_wo) then return end
        local shown = vim.api.nvim_win_get_buf(w)
        if shown == s.preview_msg_buf then return end
        for _, b in pairs(s.preview_bufs or {}) do if b == shown then return end end
        for k, v in pairs(s.dock.saved_wo) do vim.wo[w][k] = v end
        s.dock.saved_wo = nil
        s.preview_path, s.preview_first, s.preview_buf = nil, nil, nil
      end,
    })
    vim.api.nvim_create_autocmd('WinEnter', {
      group = group,
      callback = function()
        vim.schedule(function()
          if M.current ~= s or s.closed or s.opening ~= opening then return end
          local w = vim.api.nvim_get_current_win()
          if vim.api.nvim_win_get_config(w).relative == '' then return M.close { picker = true, focus = w } end
          local p = s.dock.picker
          if w == p.results_win then
            -- A click on the results from the chat: select that row, and type in the prompt.
            local row = vim.api.nvim_win_get_cursor(w)[1]
            vim.api.nvim_set_current_win(p.prompt_win)
            p:set_selection(row - 1)
            if vim.api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then vim.cmd 'startinsert!' end
          elseif w == p.preview_win then
            -- A click on the preview from the chat opens what it shows, as Telescope does from
            -- its prompt: the selected link, or else the picker's selected file.
            local shown = vim.api.nvim_win_get_buf(w)
            for _, b in pairs(s.preview_bufs or {}) do
              if b == shown and s.link then return M.open_link() end
            end
            local prompt = s.dock.prompt
            vim.api.nvim_set_current_win(p.prompt_win)
            require('telescope.actions').select_default(prompt)
          elseif w == p.prompt_win then
            if vim.api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then vim.cmd 'startinsert!' end
          end
        end)
      end,
    })
  end
end

---A click at pos (a getmousepos() table) on the chat: on the conversation, select the link there
---if there is one; either way, type in the input. False for any other window.
function M.click(pos)
  local s = M.current
  if not (is_open(s) and pos) then return false end
  if pos.winid == s.win then
    link_at(s, pos.line, math.max(0, (pos.column or 1) - 1))
    to_input(s)
    return true
  elseif pos.winid == s.input_win then
    to_input(s)
    return true
  end
  return false
end

---Whether winid is one of the open chat's windows.
function M.owns(winid)
  local s = M.current
  return is_open(s) and (winid == s.win or winid == s.input_win)
end

---Move the docked chat to the box its picker now leaves free (after a resize).
function M.relayout()
  local s = M.current
  if not (is_open(s) and s.dock and s.dock.picker._synopsis_dock) then return end
  local g = dock_geometry(s.dock.picker._synopsis_dock)
  vim.api.nvim_win_set_config(s.win, { relative = 'editor', row = g.row, col = g.col, width = g.width, height = g.height })
  vim.api.nvim_win_set_config(s.input_win, { relative = 'editor', row = g.row + g.height + 2, col = g.col, width = g.width, height = g.input_h })
end

---Note a change of file in the conversation, and tell the model with the next question.
---Note that the user now views `about`, if it is another file. Returns true if it noted one.
local function note_about(s, about)
  if not about or (s.about and s.about.path == about.path) then return false end
  if #s.items > 0 then table.insert(s.items, { kind = 'blank' }) end
  table.insert(s.items, { kind = 'note', text = string.format('Now viewing `%s`', about.path) })
  s.about, s.tell_about = about, about
  return true
end

---Move to the open chat's input panel, noting `about` if it is another file.
function M.focus(about)
  local s = M.current
  if not is_open(s) then return end
  -- Redrawing clears markview's and snacks' rendering, which would flash the raw LaTeX.
  if note_about(s, about) then render(s) end
  to_input(s)
end

start = function(o)
  local cur = M.current
  if cur and not cur.closed then M.close { keep_dock = o.dock ~= nil and cur.dock ~= nil and cur.dock.prompt == o.dock.prompt } end
  local s = M.sessions[o.root]
  if not s then
    s = { root = o.root, items = {}, tail = {}, pending = false }
    M.sessions[o.root] = s
    local hint = o.about and string.format('Asking about `%s`', o.about.path) or ('Ask about ' .. vim.fs.basename(o.root))
    table.insert(s.items, { kind = 'hint', text = hint })
    s.about, s.tell_about = o.about, o.about
  else
    note_about(s, o.about)
  end
  s.config, s.on_close, s.closed, s.jumped = o.config, o.on_close, false, false
  s.dock = o.dock
  if s.dock and not s.dock.picker._synopsis_side then require('synopsis.telescope').dock(s.dock.picker, s.dock.prompt) end
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
