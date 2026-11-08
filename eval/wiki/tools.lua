-- The plugin's code-reading tools (synopsis.tools) plus the language server's definition and
-- references, for the wiki eval's lsp arm. The same interface as synopsis.tools: schemas,
-- call and call_async; stop() ends the language servers.
local P = require 'synopsis.tools'
local T = setmetatable({}, { __index = P })

local LSP = {
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

---OpenAI function-tool definitions for the named tools, plugin tools and LSP tools alike.
function T.schemas(names)
  local out = {}
  for _, n in ipairs(names) do
    local s = LSP[n]
    if s then
      table.insert(out, { type = 'function', ['function'] = {
        name = n, description = s[1], parameters = { type = 'object', properties = s[2], required = s[3] } } })
    else
      vim.list_extend(out, P.schemas { n })
    end
  end
  return out
end

local function realpath(p) return vim.uv.fs_realpath(p) or vim.fs.normalize(p) end

---The absolute path of `rel` inside root, or nil and a reason.
local function inside(root, rel)
  local ok, abs = pcall(P.open, root, rel, {})
  if ok then return abs end
  return nil, (tostring(abs):gsub('^[^:]*:%d+: ', ''))
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
  return vim.split(text, '\n', { plain = true })
end

local function lang_of(abs)
  local ft = vim.filetype.match { filename = abs }
  return ft and vim.treesitter.language.get_lang(ft) or nil, ft
end

local function cap(list, what)
  if #list <= P.MAX_MATCHES then return table.concat(list, '\n') end
  return table.concat(vim.list_slice(list, 1, P.MAX_MATCHES), '\n') .. string.format('\n(%d more %s not shown)', #list - P.MAX_MATCHES, what)
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
function T.call(root, name, args, opts)
  if not LSP[name] then return P.call(root, name, args, opts) end
  local ok, a = pcall(vim.json.decode, args ~= '' and args or '{}')
  if not ok or type(a) ~= 'table' then return 'error: arguments are not a JSON object' end
  local ok2, out = pcall(T[name], root, a)
  if not ok2 then return 'error: ' .. tostring(out):gsub('^[^:]*:%d+: ', '') end
  if #out > P.MAX_CHARS then out = out:sub(1, P.MAX_CHARS) .. '\n(output cut here)' end
  return out
end

function T.call_async(root, name, args, opts, cb)
  if not LSP[name] then return P.call_async(root, name, args, opts, cb) end
  local out = T.call(root, name, args, opts)
  vim.schedule(function() cb(out) end)
  return function() end
end

return T
