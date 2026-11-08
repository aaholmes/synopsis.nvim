-- The code-reading tools the wiki eval gives the model: search, read, outline, and language
-- server lookups. Checks that need rg, a parser or a language server are skipped without it.
local H = dofile 'tests/harness.lua'
local T = dofile(SYNOPSIS_ROOT .. '/eval/wiki/tools.lua')

local repo = H.make_repo {
  ['a.lua'] = 'local M = {}\n\nfunction M.greet(name)\n  return "hi " .. name\nend\n\nlocal function helper() end\n\nM.wave = function() end\n\nreturn M\n',
  ['b.lua'] = "local a = require 'a'\nprint(a.greet('x'))\n",
  ['pkg/c.py'] = 'class Box:\n    def open(self):\n        pass\n\n\ndef make():\n    return Box()\n',
  ['big.txt'] = string.rep('line\n', 500),
}
local function has(s, part) return s:find(part, 1, true) ~= nil end
local function skip(name, why) io.write('skip  ', name, ' (', why, ')\n') end

if vim.fn.executable 'rg' == 1 then
  H.check('rg lists matches as path:line: text, relative to the repo', function()
    local out = T.call(repo, 'rg', '{"pattern":"greet"}')
    H.eq(has(out, 'a.lua:3: function M.greet(name)'), true, out)
    H.eq(has(out, 'b.lua:2: '), true, out)
  end)
  H.check('rg can be limited to a glob', function()
    local out = T.call(repo, 'rg', '{"pattern":"greet","glob":"b.lua"}')
    H.eq(has(out, 'a.lua'), false, out)
  end)
  H.check('rg with no matches says so', function()
    H.eq(T.call(repo, 'rg', '{"pattern":"nothing_here_zz"}'), 'no matches', 'out')
  end)
  H.check('rg output is capped', function()
    local out = T.call(repo, 'rg', '{"pattern":"line"}')
    H.eq(#vim.split(out, '\n') <= T.MAX_MATCHES + 1, true, 'line count')
    H.eq(has(out, 'more matches not shown'), true, 'cut marker')
  end)
else
  skip('rg', 'rg not installed')
end

H.check('read returns numbered lines in the range asked for', function()
  local out = T.call(repo, 'read', '{"path":"a.lua","start":3,"end":4}')
  H.eq(out, '3: function M.greet(name)\n4:   return "hi " .. name', 'out')
end)
H.check('read without a range starts at line 1 and is capped', function()
  local out = T.call(repo, 'read', '{"path":"big.txt"}')
  H.eq(vim.startswith(out, '1: line'), true, 'start')
  H.eq(has(out, ('%d: line'):format(T.MAX_LINES + 1)), false, 'cap')
  H.eq(has(out, 'lines 201-500 not shown'), true, 'cut marker')
end)
H.check('read refuses paths outside the repo', function()
  H.eq(vim.startswith(T.call(repo, 'read', '{"path":"../x"}'), 'error:'), true, 'parent')
  H.eq(vim.startswith(T.call(repo, 'read', '{"path":"/etc/hosts"}'), 'error:'), true, 'absolute')
end)
H.check('a missing file, bad JSON or unknown tool gives an error message, not a crash', function()
  H.eq(vim.startswith(T.call(repo, 'read', '{"path":"nope.lua"}'), 'error:'), true, 'missing')
  H.eq(vim.startswith(T.call(repo, 'read', '{bad'), 'error:'), true, 'json')
  H.eq(vim.startswith(T.call(repo, 'fly', '{}'), 'error:'), true, 'unknown')
end)

H.check('outline lists a Lua file\'s functions with line numbers', function()
  local out = T.call(repo, 'outline', '{"path":"a.lua"}')
  H.eq(out, '3: function M.greet(name)\n7: local function helper()\n9: M.wave = function()', 'out')
end)
if pcall(vim.treesitter.language.add, 'python') then
  H.check('outline nests Python methods under their class', function()
    local out = T.call(repo, 'outline', '{"path":"pkg/c.py"}')
    H.eq(out, '1: class Box:\n2:   def open(self):\n6: def make():', 'out')
  end)
else
  skip('outline python', 'no python parser')
end

H.check('schemas lists only the tools asked for, in OpenAI function format', function()
  local s = T.schemas { 'rg', 'read' }
  H.eq(#s, 2, 'count')
  H.eq(s[1].type, 'function', 'type')
  H.eq(s[1]['function'].name, 'rg', 'name')
  H.eq(s[2]['function'].parameters.required[1], 'path', 'required')
end)

if T.server_cmd 'lua' then
  H.check('definition finds where a symbol used in one file is defined', function()
    local out = T.call(repo, 'definition', '{"path":"b.lua","symbol":"greet"}')
    H.eq(has(out, 'a.lua:3: '), true, out)
  end)
  H.check('references lists the uses of a symbol in other files', function()
    local out = T.call(repo, 'references', '{"path":"a.lua","symbol":"greet","line":3}')
    H.eq(has(out, 'b.lua:2: '), true, out)
  end)
  H.check('a symbol that is not in the file gives an error message', function()
    H.eq(vim.startswith(T.call(repo, 'definition', '{"path":"b.lua","symbol":"zzz"}'), 'error:'), true, 'out')
  end)
  T.stop()
else
  skip('definition and references', 'lua-language-server not found')
end

H.finish()
