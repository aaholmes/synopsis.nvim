-- Code-reading tools for :SynopsisAsk: rg, read and outline. call(root, name, json_args, opts)
-- returns plain text, starting with "error:" when something is wrong, so the model can see and
-- correct its mistake. opts = { exclude, max_bytes }: excluded and oversized files are never
-- searched or read.
local files = require 'synopsis.files'
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
}
T.SCHEMAS = SCHEMAS

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

---The text of root/rel, checked: inside the repo, not excluded, not too large, not binary.
---Returns abs, text, or raises an error with the reason.
function T.open(root, rel, opts)
  if type(rel) ~= 'string' or rel == '' then error 'path is required' end
  if rel:sub(1, 1) == '/' or rel:find '^~' then error 'give a path relative to the repository root' end
  for part in rel:gmatch '[^/]+' do if part == '..' then error 'path must stay inside the repository' end end
  local r = realpath(root)
  local abs = realpath(root .. '/' .. rel)
  if abs ~= r and abs:sub(1, #r + 1) ~= r .. '/' then error 'path must stay inside the repository' end
  if vim.uv.fs_stat(abs) == nil then error('no such file: ' .. rel) end
  local why, text = files.skip_reason(r, abs:sub(#r + 2), opts or {})
  if why then error(why) end
  return abs, text
end

local function cap(list, what)
  if #list <= T.MAX_MATCHES then return table.concat(list, '\n') end
  local shown = vim.list_slice(list, 1, T.MAX_MATCHES)
  return table.concat(shown, '\n') .. string.format('\n(%d more %s not shown)', #list - T.MAX_MATCHES, what)
end

local function rg_cmd(a, opts)
  if vim.fn.executable 'rg' ~= 1 then error('rg (ripgrep) is not installed', 0) end
  if type(a.pattern) ~= 'string' or a.pattern == '' then error 'pattern is required' end
  local cmd = { 'rg', '--line-number', '--no-heading', '--color', 'never', '--smart-case', '--sort', 'path',
    '--max-columns', '200', '--max-columns-preview' }
  if opts.max_bytes then vim.list_extend(cmd, { '--max-filesize', tostring(opts.max_bytes) }) end
  if a.glob and a.glob ~= '' then vim.list_extend(cmd, { '--glob', a.glob }) end
  for _, g in ipairs(opts.exclude or {}) do vim.list_extend(cmd, { '--glob', '!' .. g }) end
  vim.list_extend(cmd, { '-e', a.pattern, '.' })
  return cmd
end

local function rg_parse(res, opts)
  if res.code == 1 then return 'no matches' end
  if res.code ~= 0 then error(vim.trim(res.stderr or 'rg failed')) end
  local out = {}
  for line in res.stdout:gmatch '[^\n]+' do
    local path, n, text = line:match '^%./(.-):(%d+):(.*)$'
    -- rg's globs already skip excluded files; this check also covers glob arguments that
    -- re-include them.
    if path and not files.excluded(path, opts.exclude) then
      table.insert(out, string.format('%s:%s: %s', path, n, vim.trim(text)))
    end
  end
  if #out == 0 then return 'no matches' end
  return cap(out, 'matches')
end

function T.rg(root, a, opts)
  return rg_parse(vim.system(rg_cmd(a, opts), { cwd = root, text = true, stdin = false }):wait(30000), opts)
end

function T.read(root, a, opts)
  local _, text = T.open(root, a.path, opts)
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  local first = math.max(1, math.floor(tonumber(a.start) or 1))
  local want = math.min(#lines, math.floor(tonumber(a['end']) or #lines))
  local last = math.min(want, first + T.MAX_LINES - 1)
  if first > #lines then error(string.format('the file has %d lines', #lines)) end
  local out = {}
  for i = first, last do table.insert(out, string.format('%d: %s', i, lines[i])) end
  local s = table.concat(out, '\n')
  if last < want then
    s = s .. string.format('\n(lines %d-%d not shown; read again with start=%d)', last + 1, want, last + 1)
  end
  return s
end

local DEFS = {
  lua = { function_declaration = true },
  python = { function_definition = true, class_definition = true },
  rust = { function_item = true, function_signature_item = true, struct_item = true, enum_item = true, trait_item = true,
    impl_item = true, mod_item = true, macro_definition = true, type_item = true },
}
T.DEFS = DEFS

---The Tree-sitter language for a path, if it has a parser and outline rules.
function T.lang(path, lines)
  local ft = vim.filetype.match { filename = path, contents = lines and vim.list_slice(lines, 1, 5) or nil }
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if lang and DEFS[lang] and pcall(vim.treesitter.language.add, lang) then return lang end
end

function T.outline(root, a, opts)
  local abs, text = T.open(root, a.path, opts)
  local all = vim.split(text, '\n', { plain = true })
  local lang = T.lang(abs, all)
  if not lang then error 'no outline for this file type; use read or rg' end
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
    return vim.trim((table.concat(lines, ' '):gsub('%s+', ' '))):sub(1, 160), sr + 1
  end
  local function walk(node, depth)
    for child in node:iter_children() do
      local t = child:type()
      local start_node, def
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

local function decode(args)
  local ok, a = pcall(vim.json.decode, args ~= '' and args or '{}')
  if not ok or type(a) ~= 'table' then return nil end
  return a
end
local function finish(ok, out)
  if not ok then return 'error: ' .. tostring(out):gsub('^[^:]*:%d+: ', '') end
  if #out > T.MAX_CHARS then out = out:sub(1, T.MAX_CHARS) .. '\n(output cut here)' end
  return out
end

---Run tool `name` with JSON-encoded `args` in root; always returns text.
function T.call(root, name, args, opts)
  opts = opts or {}
  local fn = SCHEMAS[name] and T[name]
  if not fn then return 'error: unknown tool ' .. tostring(name) end
  local a = decode(args)
  if not a then return 'error: arguments are not a JSON object' end
  return finish(pcall(fn, root, a, opts))
end

---As call, but calls cb(text) later on the main loop; rg runs without blocking the editor.
---Returns a function that stops a running search.
function T.call_async(root, name, args, opts, cb)
  opts = opts or {}
  local a = decode(args)
  if name ~= 'rg' or not a then
    local out = T.call(root, name, args, opts)
    vim.schedule(function() cb(out) end)
    return function() end
  end
  local ok, cmd = pcall(rg_cmd, a, opts)
  if not ok then
    vim.schedule(function() cb(finish(false, cmd)) end)
    return function() end
  end
  local proc = vim.system(cmd, { cwd = root, text = true, stdin = false, timeout = 30000 }, vim.schedule_wrap(function(res)
    cb(finish(pcall(rg_parse, res, opts)))
  end))
  return function() pcall(proc.kill, proc, 15) end
end

return T
