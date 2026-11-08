-- The wiki eval's deterministic file map: per file, its leading comment and top-level
-- definitions, with no model involved.
local H = dofile 'tests/harness.lua'
local M = dofile(SYNOPSIS_ROOT .. '/eval/wiki/map.lua')

local many = {}
for i = 1, 11 do table.insert(many, string.format('local function f%d() end', i)) end
local repo = H.make_repo {
  ['a.lua'] = '-- Greets people.\n-- Second line.\nlocal M = {}\n\nfunction M.greet(name) end\n\nlocal function helper() end\n\nM.wave = function() end\n\nreturn M\n',
  ['b.lua'] = "local a = require 'a'\nprint(a.greet('x'))\n",
  ['many.lua'] = table.concat(many, '\n') .. '\n',
  ['pkg/c.py'] = '#!/usr/bin/env python3\n"""Boxes for things.\n\nMore detail here.\n"""\n\nclass Box:\n    def open(self):\n        pass\n\n\ndef make():\n    return Box()\n',
  ['lib.rs'] = '//! Core types.\nuse std::fmt;\n\npub struct Det { x: u64 }\n\nimpl Det {\n    pub fn new() -> Self { Det { x: 0 } }\n}\n\npub fn run(n: usize) -> usize { n }\n',
  ['README.md'] = '\n# My project\n\nIt does things.\n',
  ['empty.txt'] = '',
}

H.check('a Lua file: its leading comment, then its top-level definitions', function()
  H.eq(M.entry(repo, 'a.lua'), 'a.lua: Greets people. Second line. Defines: M.greet, helper, M.wave', 'entry')
end)
H.check('a Python file: the module docstring, then classes and functions, not methods', function()
  H.eq(M.entry(repo, 'pkg/c.py'), 'pkg/c.py: Boxes for things. More detail here. Defines: Box, make', 'entry')
end)
if pcall(vim.treesitter.language.add, 'rust') then
  H.check('a Rust file: //! comments, then items, with impl blocks named by their header', function()
    H.eq(M.entry(repo, 'lib.rs'), 'lib.rs: Core types. Defines: Det, impl Det, run', 'entry')
  end)
end
H.check('a file with no comment or definitions shows its first non-empty line', function()
  H.eq(M.entry(repo, 'b.lua'), "b.lua: local a = require 'a'", 'code')
  H.eq(M.entry(repo, 'README.md'), 'README.md: # My project', 'markdown')
  H.eq(M.entry(repo, 'empty.txt'), 'empty.txt: (empty)', 'empty')
end)
H.check('at most 8 definitions are named, then a count of the rest', function()
  H.eq(M.entry(repo, 'many.lua'), 'many.lua: Defines: f1, f2, f3, f4, f5, f6, f7, f8 (+3 more)', 'entry')
end)
H.check('long comments are cut', function()
  local r = H.make_repo { ['x.lua'] = '-- ' .. string.rep('word ', 100) .. '\n' }
  local e = M.entry(r, 'x.lua')
  H.eq(#e <= #'x.lua: ' + M.MAX_DOC + 1, true, e)
  H.eq(vim.endswith(e, '…'), true, e)
end)
H.check('a missing or binary file gives a marker, not an error', function()
  H.eq(M.entry(repo, 'nope.lua'), 'nope.lua: (unreadable)', 'missing')
  local r = H.make_repo { ['bin.dat'] = 'ab\0cd' }
  H.eq(M.entry(r, 'bin.dat'), 'bin.dat: (binary)', 'binary')
end)

H.check('a file that is not valid UTF-8 is binary, even with no NUL byte', function()
  local r = H.make_repo { ['w.bin'] = 'A\187\8\189B' }
  H.eq(M.entry(r, 'w.bin'), 'w.bin: (binary)', 'entry')
end)
H.check('cutting a long comment never splits a multi-byte character', function()
  local r = H.make_repo { ['u.lua'] = '-- ' .. string.rep('é', 200) .. '\n' }
  local e = M.entry(r, 'u.lua')
  H.eq(M.valid_utf8(e), true, 'valid')
end)

H.finish()
