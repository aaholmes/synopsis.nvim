-- The wiki eval's extra tools: the language server's definition and references, added to the
-- plugin's tools. Skipped without lua-language-server.
local H = dofile 'tests/harness.lua'
local T = dofile(SYNOPSIS_ROOT .. '/eval/wiki/tools.lua')

local repo = H.make_repo {
  ['a.lua'] = 'local M = {}\n\nfunction M.greet(name)\n  return "hi " .. name\nend\n\nlocal function helper() end\n\nM.wave = function() end\n\nreturn M\n',
  ['b.lua'] = "local a = require 'a'\nprint(a.greet('x'))\n",
}
local function has(s, part) return s:find(part, 1, true) ~= nil end
local function skip(name, why) io.write('skip  ', name, ' (', why, ')\n') end

H.check('the plugin tools are still there, and the LSP tools are added to the schemas', function()
  H.eq(T.call(repo, 'read', '{"path":"b.lua","start":1,"end":1}'), "1: local a = require 'a'", 'read')
  local s = T.schemas { 'read', 'definition' }
  H.eq(s[1]['function'].name, 'read', 'plugin tool')
  H.eq(s[2]['function'].name, 'definition', 'lsp tool')
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
