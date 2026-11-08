-- Code-reading tools for the wiki eval's model: rg, read, outline, and the language server's
-- definition and references. call(root, name, json_args) returns plain text, starting with
-- "error:" when something is wrong, so the model can see and correct its mistake.
local T = { MAX_MATCHES = 50, MAX_LINES = 200, MAX_CHARS = 12000 }

local SCHEMAS = {
  rg = { 'Search the repository with ripgrep (a regular expression, case-insensitive unless it has capitals). Returns path:line: text.',
    { pattern = { type = 'string', description = 'Rust regex syntax' },
      glob = { type = 'string', description = 'optional: limit to files matching this glob, e.g. "*.py" or "src/**"' } },
    { 'pattern' } },
  read = { 'Read lines of a file, numbered. At most 200 lines per call.',
    { path = { type = 'string', description = 'relative to the repository root' },
      start = { type = 'integer', description = 'first line, default 1' },
      ['end'] = { type = 'integer', description = 'last line, default start + 199' } },
    { 'path' } },
  outline = { "List a file's functions, classes and other definitions with their line numbers.",
    { path = { type = 'string', description = 'relative to the repository root' } }, { 'path' } },
  definition = { 'Find where a symbol is defined, using the language server. Give a file where the symbol appears.',
    { path = { type = 'string', description = 'a file that uses or defines the symbol' },
      symbol = { type = 'string', description = 'the identifier, e.g. "run" (not "a.run")' },
      line = { type = 'integer', description = 'optional: the line where it appears in that file' } },
    { 'path', 'symbol' } },
  references = { 'List the places a symbol is used, using the language server. Give the file and line where it is defined or used.',
    { path = { type = 'string', description = 'a file that uses or defines the symbol' },
      symbol = { type = 'string', description = 'the identifier' },
      line = { type = 'integer', description = 'optional: the line where it appears in that file' } },
    { 'path', 'symbol' } },
}

---OpenAI function-tool definitions for the named tools, in the order given.
function T.schemas(names)
  local out = {}
  for _, n in ipairs(names) do
    local s = assert(SCHEMAS[n], 'unknown tool ' .. n)
    table.insert(out, { type = 'function', ['function'] = {
      name = n, description = s[1], parameters = { type = 'object', properties = s[2], required = s[3] } } })
  end
  return out
end

local function realpath(p) return vim.uv.fs_realpath(p) or vim.fs.normalize(p) end

---The absolute path of `rel` inside root, or nil and a reason.
local function inside(root, rel)
  if type(rel) ~= 'string' or rel == '' then return nil, 'path is required' end
  if rel:sub(1, 1) == '/' or rel:find '^~' then return nil, 'give a path relative to the repository root' end
  for part in rel:gmatch '[^/]+' do if part == '..' then return nil, 'path must stay inside the repository' end end
  local abs = realpath(root .. '/' .. rel)
  local r = realpath(root)
  if abs ~= r and abs:sub(1, #r + 1) ~= r .. '/' then return nil, 'path must stay inside the repository' end
  if vim.fn.filereadable(abs) ~= 1 then return nil, 'no such file: ' .. rel end
  return abs
end

local function rel_of(root, abs)
  local r, a = realpath(root), realpath(abs)
  if a:sub(1, #r + 1) == r .. '/' then return a:sub(#r + 2) end
  return a
end

local function lines_of(abs)
  local f = assert(io.open(abs, 'rb'))
  local text = f:read '*a'
  f:close()
  if text:sub(1, 8192):find('\0', 1, true) then error 'binary file' end
  return vim.split(text, '\n', { plain = true }), text
end

local function cap(list, what)
  if #list <= T.MAX_MATCHES then return table.concat(list, '\n') end
  local shown = vim.list_slice(list, 1, T.MAX_MATCHES)
  return table.concat(shown, '\n') .. string.format('\n(%d more %s not shown)', #list - T.MAX_MATCHES, what)
end

function T.rg(root, a)
  if type(a.pattern) ~= 'string' or a.pattern == '' then error 'pattern is required' end
  local cmd = { 'rg', '--line-number', '--no-heading', '--color', 'never', '--smart-case', '--sort', 'path',
    '--max-columns', '200', '--max-columns-preview' }
  if a.glob and a.glob ~= '' then vim.list_extend(cmd, { '--glob', a.glob }) end
  vim.list_extend(cmd, { '-e', a.pattern, '.' })
  local res = vim.system(cmd, { cwd = root, text = true, stdin = false }):wait(30000)
  if res.code == 1 then return 'no matches' end
  if res.code ~= 0 then error(vim.trim(res.stderr or 'rg failed')) end
  local out = {}
  for line in res.stdout:gmatch '[^\n]+' do
    local path, n, text = line:match '^%./(.-):(%d+):(.*)$'
    if path then table.insert(out, string.format('%s:%s: %s', path, n, vim.trim(text))) end
  end
  return cap(out, 'matches')
end

function T.read(root, a)
  local abs, why = inside(root, a.path)
  if not abs then error(why) end
  local lines = lines_of(abs)
  if lines[#lines] == '' then table.remove(lines) end
  local first = math.max(1, math.floor(tonumber(a.start) or 1))
  local want = math.min(#lines, math.floor(tonumber(a['end']) or #lines))
  local last = math.min(want, first + T.MAX_LINES - 1)
  if first > #lines then error(string.format('the file has %d lines', #lines)) end
  local out = {}
  for i = first, last do table.insert(out, string.format('%d: %s', i, lines[i])) end
  local text = table.concat(out, '\n')
  if last < want then
    text = text .. string.format('\n(lines %d-%d not shown; read again with start=%d)', last + 1, want, last + 1)
  end
  return text
end

local function lang_of(abs)
  local ft = vim.filetype.match { filename = abs }
  return ft and vim.treesitter.language.get_lang(ft) or nil, ft
end

local DEFS = {
  lua = { function_declaration = true },
  python = { function_definition = true, class_definition = true },
  rust = { function_item = true, function_signature_item = true, struct_item = true, enum_item = true, trait_item = true,
    impl_item = true, mod_item = true, macro_definition = true, type_item = true },
}

function T.outline(root, a)
  local abs, why = inside(root, a.path)
  if not abs then error(why) end
  local lang = lang_of(abs)
  if not lang or not DEFS[lang] or not pcall(vim.treesitter.language.add, lang) then
    error('no outline for this file type; use read or rg')
  end
  local all, text = lines_of(abs)
  local tree = vim.treesitter.get_string_parser(text, lang):parse()[1]
  local out = {}
  local function header(start_node, def)
    local body = def:field('body')[1]
    local params = def:field('parameters')[1]
    local sr, sc = start_node:range()
    local er, ec
    if body then er, ec = body:range() elseif params then er, ec = select(3, params:range()) else er, ec = select(3, def:range()) end
    local lines = vim.list_slice(all, sr + 1, er + 1)
    lines[#lines] = lines[#lines]:sub(1, ec)
    lines[1] = lines[1]:sub(sc + 1)
    return vim.trim(table.concat(lines, ' '):gsub('%s+', ' ')):sub(1, 160), sr + 1
  end
  local function walk(node, depth)
    for child in node:iter_children() do
      local t = child:type()
      local start_node, def = nil, nil
      if DEFS[lang][t] then
        start_node, def = child, child
      elseif lang == 'lua' and t == 'function_definition' then
        -- `M.f = function() ... end` or `local f = function() ... end`: named by the assignment.
        local p = child:parent()
        if p and p:type() == 'expression_list' then
          local asg = p:parent()
          if asg and asg:type() == 'assignment_statement' then
            local decl = asg:parent()
            start_node = decl and decl:type() == 'variable_declaration' and decl or asg
            def = child
          end
        end
      end
      if def then
        local h, row = header(start_node, def)
        table.insert(out, string.format('%d: %s%s', row, string.rep('  ', depth), h))
        walk(child, depth + 1)
      else
        walk(child, depth)
      end
    end
  end
  walk(tree:root(), 0)
  if #out == 0 then return 'no definitions found' end
  if #out > 300 then out = vim.list_slice(out, 1, 300); table.insert(out, '(more definitions not shown)') end
  return table.concat(out, '\n')
end

-- Language servers: one client per (root, language), started on first use.
local SERVERS = {
  lua = { 'lua-language-server' },
  python = { 'pyright-langserver', '--stdio' },
  rust = { 'rust-analyzer' },
}
local MASON = vim.fn.stdpath 'data' .. '/mason/bin/'

---The command that starts `lang`'s language server, or nil if it is not installed.
function T.server_cmd(lang)
  local cmd = SERVERS[lang]
  if not cmd then return nil end
  local exe = vim.fn.exepath(cmd[1])
  if exe == '' and vim.fn.executable(MASON .. cmd[1]) == 1 then exe = MASON .. cmd[1] end
  if exe == '' then
    local home = vim.fn.expand '~/.local/share/nvim/mason/bin/' .. cmd[1]
    if vim.fn.executable(home) == 1 then exe = home end
  end
  if exe == '' then return nil end
  local out = vim.deepcopy(cmd)
  out[1] = exe
  return out
end

local clients, busy, ready = {}, {}, {}
vim.api.nvim_create_autocmd('LspProgress', {
  callback = function(ev)
    local id, v = ev.data.client_id, ev.data.params.value
    busy[id] = busy[id] or {}
    if type(v) == 'table' then busy[id][ev.data.params.token] = v.kind ~= 'end' or nil end
    busy[id].last = vim.uv.now()
  end,
})

---A loaded buffer for abs, attached to its language server; returns bufnr, client id.
local function attach(root, abs)
  local lang, ft = lang_of(abs)
  local cmd = T.server_cmd(lang or '')
  if not cmd then error('no language server for this file type') end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  if vim.bo[buf].filetype ~= ft then vim.bo[buf].filetype = ft end
  local id = vim.lsp.start({ name = 'wiki-' .. lang, cmd = cmd, root_dir = realpath(root) }, { bufnr = buf })
  if not id then error 'the language server did not start' end
  clients[id] = true
  vim.wait(60000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c ~= nil and c.initialized and vim.lsp.buf_is_attached(buf, id)
  end, 20)
  if not ready[id] then
    -- Let the server index the workspace: wait until it reports no work in progress for 2 s.
    local limit = lang == 'rust' and 600000 or 120000
    vim.wait(limit, function()
      local b = busy[id] or {}
      for k, v in pairs(b) do if k ~= 'last' and v then return false end end
      return vim.uv.now() - (b.last or 0) > 2000
    end, 100)
    ready[id] = true
  end
  return buf, id
end

local function position(lines, symbol, line)
  local pat = '%f[%w_]' .. vim.pesc(symbol) .. '%f[^%w_]'
  local function on(i)
    local col = lines[i] and lines[i]:find(pat)
    if col then
      local ok, ch = pcall(vim.str_utfindex, lines[i], 'utf-16', col - 1)
      return { line = i - 1, character = ok and ch or col - 1 }
    end
  end
  if line then
    for _, i in ipairs { line, line - 1, line + 1 } do
      local p = on(i)
      if p then return p end
    end
  end
  for i = 1, #lines do
    local p = on(i)
    if p then return p end
  end
end

local function lsp_lookup(method, root, a)
  if type(a.symbol) ~= 'string' or not a.symbol:match '^[%w_]+$' then error 'symbol must be one identifier' end
  local abs, why = inside(root, a.path)
  if not abs then error(why) end
  local lines = lines_of(abs)
  local pos = position(lines, a.symbol, tonumber(a.line))
  if not pos then error(string.format('%s does not appear in %s', a.symbol, a.path)) end
  local buf, id = attach(root, abs)
  local params = { textDocument = { uri = vim.uri_from_fname(abs) }, position = pos }
  if method == 'textDocument/references' then params.context = { includeDeclaration = true } end
  local client = assert(vim.lsp.get_client_by_id(id))
  local res, err = client:request_sync(method, params, 60000, buf)
  if not res then error('language server: ' .. tostring(err)) end
  if res.err then error('language server: ' .. (res.err.message or vim.inspect(res.err))) end
  local locs = res.result or {}
  if locs.uri or locs.targetUri then locs = { locs } end
  local seen, out = {}, {}
  for _, l in ipairs(locs) do
    local uri = l.uri or l.targetUri
    local range = l.range or l.targetSelectionRange or l.targetRange
    local path = vim.uri_to_fname(uri)
    local n = range.start.line + 1
    local key = path .. ':' .. n
    if not seen[key] then
      seen[key] = true
      local ok, flines = pcall(lines_of, path)
      local text = ok and flines[n] and vim.trim(flines[n]):sub(1, 200) or ''
      table.insert(out, { rel_of(root, path), n, text })
    end
  end
  table.sort(out, function(x, y) if x[1] ~= y[1] then return x[1] < y[1] end return x[2] < y[2] end)
  if #out == 0 then return 'nothing found' end
  local strs = {}
  for _, o in ipairs(out) do table.insert(strs, string.format('%s:%d: %s', o[1], o[2], o[3])) end
  return cap(strs, 'locations')
end

function T.definition(root, a) return lsp_lookup('textDocument/definition', root, a) end
function T.references(root, a) return lsp_lookup('textDocument/references', root, a) end

---Stop every language server this module started.
function T.stop()
  local ids = vim.tbl_keys(clients)
  for _, id in ipairs(ids) do
    local c = vim.lsp.get_client_by_id(id)
    if c then c:stop(true) end
  end
  vim.wait(5000, function()
    for _, id in ipairs(ids) do if vim.lsp.get_client_by_id(id) then return false end end
    return true
  end, 50)
  clients = {}
end

---Run tool `name` with JSON-encoded `args` in root; always returns text.
function T.call(root, name, args)
  local fn = SCHEMAS[name] and T[name]
  if not fn then return 'error: unknown tool ' .. tostring(name) end
  local ok, a = pcall(vim.json.decode, args ~= '' and args or '{}')
  if not ok or type(a) ~= 'table' then return 'error: arguments are not a JSON object' end
  local ok2, out = pcall(fn, root, a)
  if not ok2 then return 'error: ' .. tostring(out):gsub('^[^:]*:%d+: ', '') end
  if #out > T.MAX_CHARS then out = out:sub(1, T.MAX_CHARS) .. '\n(output cut here)' end
  return out
end

return T
