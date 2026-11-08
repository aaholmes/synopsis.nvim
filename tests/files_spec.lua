-- Which files may be sent, and the repo's file list.
local H = dofile 'tests/harness.lua'
local files = require 'synopsis.files'

local opts = { exclude = { '.env', '*.pem', 'secrets/*' }, max_bytes = 100 }
local repo = H.make_repo {
  ['a.lua'] = 'return 1\n',
  ['.env'] = 'KEY=1\n',
  ['sub/.env'] = 'KEY=2\n',
  ['k.pem'] = 'x',
  ['secrets/x.txt'] = 'x',
  ['big.txt'] = string.rep('x', 101),
  ['bin.dat'] = 'ab\0cd',
  ['latin.txt'] = 'caf\233\n',
}

H.check('a small text file may be sent, and its text is returned', function()
  local why, text = files.skip_reason(repo, 'a.lua', opts)
  H.eq(why, nil, 'reason')
  H.eq(text, 'return 1\n', 'text')
end)
H.check('exclude patterns match the file name or the path in the repo', function()
  H.eq(files.skip_reason(repo, '.env', opts), 'excluded by the exclude setting', 'name')
  H.eq(files.skip_reason(repo, 'sub/.env', opts), 'excluded by the exclude setting', 'name in a folder')
  H.eq(files.skip_reason(repo, 'k.pem', opts), 'excluded by the exclude setting', 'glob')
  H.eq(files.skip_reason(repo, 'secrets/x.txt', opts), 'excluded by the exclude setting', 'path')
end)
H.check('files over max_bytes, binary files and invalid UTF-8 are not sent', function()
  H.eq(files.skip_reason(repo, 'big.txt', opts), 'too large (1 KB; the limit is 0 KB)', 'size')
  H.eq(files.skip_reason(repo, 'bin.dat', opts), 'binary file', 'NUL')
  H.eq(files.skip_reason(repo, 'latin.txt', opts), 'binary file', 'not UTF-8')
end)
H.check('a missing path or a folder is not a file', function()
  H.eq(files.skip_reason(repo, 'nope', opts), 'not a file', 'missing')
  H.eq(files.skip_reason(repo, 'sub', opts), 'not a file', 'folder')
end)
H.check('valid_utf8 accepts multi-byte text and rejects broken sequences', function()
  H.eq(files.valid_utf8('é…'), true, 'valid')
  H.eq(files.valid_utf8('A\187B'), false, 'stray byte')
  H.eq(files.valid_utf8('\195'), false, 'cut sequence')
end)
H.check('list gives the tracked files of a git repo, sorted', function()
  local l = files.list(repo)
  H.eq(l[1], '.env', 'first')
  H.eq(vim.tbl_contains(l, 'sub/.env'), true, 'nested')
  H.eq(#l, 8, 'count')
end)
H.check('list outside git walks the folder, skipping .git and hidden folders', function()
  local dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
  vim.fn.mkdir(dir .. '/src', 'p')
  vim.fn.mkdir(dir .. '/.cache', 'p')
  vim.fn.writefile({ 'x' }, dir .. '/src/b.py')
  vim.fn.writefile({ 'x' }, dir .. '/a.py')
  vim.fn.writefile({ 'x' }, dir .. '/.cache/c')
  H.eq(table.concat(files.list(dir), ','), 'a.py,src/b.py', 'list')
end)

H.finish()
