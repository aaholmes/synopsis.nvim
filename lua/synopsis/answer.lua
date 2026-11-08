-- The :SynopsisAsk window. ask{ root, question, config } checks consent, builds the file map,
-- runs the question loop (ask.lua) and shows its progress and answer in a floating window.
-- In the window: open a path:line citation, list every citation in Telescope, ask a follow-up,
-- or close (which cancels any request in flight).
local consent = require 'synopsis.consent'
local map = require 'synopsis.map'
local store = require 'synopsis.store'
local loop = require 'synopsis.ask'
local M = {}

local TOOLS = { 'rg', 'read', 'outline' }
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

local function render(s)
  if not vim.api.nvim_buf_is_valid(s.buf) then return end
  local lines = vim.list_extend(vim.deepcopy(s.lines), s.tail)
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_set_cursor, s.win, { math.max(1, #lines - #s.tail + 1), 0 })
  end
end

local function on_done(s)
  return function(r)
    if s.closed then return end
    s.result = r
    local out = {}
    if r.cancelled then
      out = { '_Cancelled._' }
    elseif r.error then
      out = { '**Error:** ' .. r.error }
    else
      out = vim.split(r.answer or '', '\n', { plain = true })
    end
    local n = #r.calls
    local tokens = r.usage.prompt_tokens + r.usage.completion_tokens
    table.insert(out, '')
    table.insert(out, string.format('_%d tool call%s · %.1f s · %d tokens_', n, n == 1 and '' or 's',
      (vim.uv.hrtime() - s.started) / 1e9, tokens))
    vim.list_extend(s.lines, out)
    s.tail = {}
    render(s)
  end
end

local function on_call(s)
  return function(c)
    if s.closed then return end
    table.insert(s.tail, '- ' .. label(c.name, c.args))
    render(s)
  end
end

---Close the window and stop any request in flight.
function M.close()
  local s = M.current
  if not s then return end
  s.closed = true
  if s.handle then s.handle.cancel() end
  if vim.api.nvim_win_is_valid(s.win) then vim.api.nvim_win_close(s.win, true) end
  if s.origin and vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
end

local function jump(s, path, line)
  M.close()
  vim.cmd.edit(vim.fn.fnameescape(s.root .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd 'normal! zz'
end

---Open the citation under the cursor (or the first one on its line).
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
  local cites = M.citations(table.concat(s.lines, '\n'), s.root)
  if #cites == 0 then return vim.notify('synopsis: no path:line citations in the answer', vim.log.levels.INFO) end
  local results = {}
  for _, c in ipairs(cites) do
    local ok, lines = pcall(vim.fn.readfile, s.root .. '/' .. c.path, '', c.line)
    local text = ok and lines[c.line] and vim.trim(lines[c.line]) or ''
    table.insert(results, string.format('%s:%d:1:%s', c.path, c.line, text))
  end
  local root = s.root
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

---Ask a follow-up question in the open conversation.
function M.follow_up(question)
  local s = M.current
  if not (s and s.handle and s.result) or s.closed or not question or vim.trim(question) == '' then return end
  s.result = nil
  s.started = vim.uv.hrtime()
  vim.list_extend(s.lines, { '', '---', '', '**Q:** ' .. question, '' })
  s.tail = { '_Thinking…_' }
  render(s)
  s.tail = {}
  s.handle.follow_up(question, on_done(s))
end

local function open_window(s, km)
  s.origin = vim.api.nvim_get_current_win()
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = 'wipe'
  vim.bo[s.buf].filetype = 'markdown'
  local width = math.min(84, vim.o.columns - 4)
  local height = math.max(8, math.floor(vim.o.lines * 0.6))
  s.win = vim.api.nvim_open_win(s.buf, true, {
    relative = 'editor', width = width, height = height, style = 'minimal', border = 'rounded',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1), col = math.floor((vim.o.columns - width) / 2),
    title = ' ' .. vim.fs.basename(s.root) .. ' ', title_pos = 'center',
  })
  vim.wo[s.win].wrap = true
  vim.wo[s.win].linebreak = true
  local function map_key(keys, fn, desc)
    if not keys then return end
    for _, k in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set('n', k, fn, { buffer = s.buf, nowait = true, desc = 'synopsis: ' .. desc })
    end
  end
  map_key(km.close, M.close, 'close the answer')
  map_key(km.open, M.open_citation, 'open the cited location')
  map_key(km.locations, M.locations, 'list the cited locations')
  map_key(km.follow_up, function()
    vim.ui.input({ prompt = 'Follow-up: ' }, function(q) M.follow_up(q) end)
  end, 'ask a follow-up question')
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(s.win), once = true,
    callback = function()
      s.closed = true
      if s.handle then s.handle.cancel() end
    end,
  })
end

local function start(root, question, config)
  if M.current and not M.current.closed then M.close() end
  local s = { root = root, config = config, lines = { '**Q:** ' .. question, '' }, tail = { "_Reading the repo's files…_" },
    started = vim.uv.hrtime() }
  M.current = s
  open_window(s, config.ask.keymaps or {})
  render(s)
  local tool_opts = { exclude = config.exclude, max_bytes = config.max_bytes }
  map.build(root, vim.tbl_extend('force', tool_opts, { max_map_chars = config.ask.max_map_chars }), function(text)
    if s.closed then return end
    s.tail = {}
    render(s)
    local context = string.format('REPOSITORY: %s\n\nFILE MAP:\n%s\n', vim.fs.basename(root), text)
    s.handle = loop.start {
      cfg = config.llm, system = system(), context = context, question = question, root = root, tools = TOOLS,
      tool_opts = tool_opts, max_rounds = config.ask.max_rounds, key = store.root_key(root), retry_ms = config.ask.retry_ms,
      on_call = on_call(s), on_done = on_done(s),
    }
  end)
end

---Answer `question` about the repo at `root`, using `config` (the plugin's settings).
function M.ask(o)
  local root, question, config = o.root, o.question, o.config
  if config.consent == 'always' or consent.get(root) == 'allow' then return start(root, question, config) end
  if consent.get(root) == 'deny' then
    return vim.notify('synopsis: sending files is off for ' .. root .. ' (:SynopsisAllow turns it on)', vim.log.levels.WARN)
  end
  local host = (config.llm.url or ''):match '^%a+://([^/:]+)' or config.llm.url
  vim.ui.select({ 'Allow', "Don't allow" }, {
    prompt = string.format('Send files from %s to %s to answer questions?', root, host),
  }, function(choice)
    if choice == 'Allow' then
      consent.set(root, 'allow')
      start(root, question, config)
    elseif choice then
      consent.set(root, 'deny')
    end
  end)
end

return M
