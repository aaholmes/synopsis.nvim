-- The code-reading tools :SynopsisAsk gives the model: search, read and outline. Checks that
-- need rg or a parser are skipped without it.
local H = dofile 'tests/harness.lua'
local T = require 'synopsis.tools'

local repo = H.make_repo {
  ['a.lua'] = 'local M = {}\n\nfunction M.greet(name)\n  return "hi " .. name\nend\n\nlocal function helper() end\n\nM.wave = function() end\n\nreturn M\n',
  ['b.lua'] = "local a = require 'a'\nprint(a.greet('x'))\n",
  ['pkg/c.py'] = 'class Box:\n    def open(self):\n        pass\n\n\ndef make():\n    return Box()\n',
  ['big.txt'] = string.rep('line\n', 500),
  ['.env'] = 'KEY=secret_value\n',
  ['conf/.env'] = 'KEY=secret_value\n',
  ['huge.lua'] = string.rep('-- secret_value\n', 100),
}
local opts = { exclude = { '.env' }, max_bytes = 1000 }
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

if vim.fn.executable 'rg' == 1 then
  H.check('rg never returns lines from excluded or oversized files', function()
    local out = T.call(repo, 'rg', '{"pattern":"secret_value"}', opts)
    H.eq(out, 'no matches', 'out')
    out = T.call(repo, 'rg', '{"pattern":"secret_value","glob":".env"}', opts)
    H.eq(out, 'no matches', 'glob asking for it')
  end)
end
H.check('read and outline refuse excluded and oversized files', function()
  H.eq(T.call(repo, 'read', '{"path":".env"}', opts), 'error: excluded by the exclude setting', 'read excluded')
  H.eq(T.call(repo, 'read', '{"path":"conf/.env"}', opts), 'error: excluded by the exclude setting', 'nested')
  H.eq(vim.startswith(T.call(repo, 'read', '{"path":"huge.lua"}', opts), 'error: too large'), true, 'size')
  H.eq(T.call(repo, 'outline', '{"path":".env"}', opts), 'error: excluded by the exclude setting', 'outline')
end)
H.check('call_async gives the same text as call', function()
  for _, c in ipairs { { 'read', '{"path":"a.lua","start":3,"end":4}' }, { 'outline', '{"path":"a.lua"}' },
    { 'rg', '{"pattern":"greet"}' }, { 'fly', '{}' } } do
    local got
    T.call_async(repo, c[1], c[2], opts, function(out) got = out end)
    vim.wait(5000, function() return got ~= nil end, 10)
    H.eq(got, T.call(repo, c[1], c[2], opts), c[1])
  end
end)

H.check('without rg installed, the rg tool says so instead of failing', function()
  local path = vim.env.PATH
  vim.env.PATH = vim.fn.tempname() -- a directory with no rg in it
  local got
  local ok, err = pcall(T.call_async, repo, 'rg', '{"pattern":"greet"}', opts, function(out) got = out end)
  local sync = T.call(repo, 'rg', '{"pattern":"greet"}', opts)
  vim.env.PATH = path
  H.eq(ok, true, 'call_async does not throw: ' .. tostring(err))
  vim.wait(1000, function() return got ~= nil end, 10)
  H.eq(got, 'error: rg (ripgrep) is not installed', 'call_async')
  H.eq(sync, 'error: rg (ripgrep) is not installed', 'call')
end)

H.finish()
