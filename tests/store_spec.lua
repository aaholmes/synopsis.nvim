local H = dofile 'tests/harness.lua'
local store = require 'synopsis.store'

local entry = { path = 'a.lua', content_hash = 'c1', prompt_hash = 'p1', model = 'm', summary = 'Does A.', created = 1 }

H.check('a written entry reads back', function()
  store.write('/repo/one', 'a.lua', entry)
  H.eq(vim.deep_equal(store.read('/repo/one', 'a.lua'), entry), true, 'round trip')
end)

H.check('a missing entry reads as nil', function() H.eq(store.read('/repo/one', 'nope.lua'), nil, 'missing') end)

H.check('the same relative path in two roots does not collide', function()
  store.write('/repo/two', 'a.lua', vim.tbl_extend('force', entry, { summary = 'Other A.' }))
  H.eq(store.read('/repo/one', 'a.lua').summary, 'Does A.', 'root one')
  H.eq(store.read('/repo/two', 'a.lua').summary, 'Other A.', 'root two')
end)

H.check('entries live under stdpath cache', function()
  local p = store.entry_path('/repo/one', 'a.lua')
  H.eq(vim.startswith(p, vim.fn.stdpath 'cache' .. '/synopsis/'), true, 'cache dir: ' .. p)
end)

H.check('status: fresh, stale on content or prompt change, missing', function()
  H.eq(store.status(entry, 'c1', 'p1'), 'fresh', 'same hashes')
  H.eq(store.status(entry, 'c2', 'p1'), 'stale', 'content changed')
  H.eq(store.status(entry, 'c1', 'p2'), 'stale', 'prompt changed')
  H.eq(store.status(nil, 'c1', 'p1'), 'missing', 'no entry')
end)

H.check('a leftover temporary file or a corrupt entry is never read', function()
  local p = store.entry_path('/repo/three', 'b.lua')
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  vim.fn.writefile({ '{"summary": "half' }, p .. '.tmp')
  H.eq(store.read('/repo/three', 'b.lua'), nil, 'temp file only')
  vim.fn.writefile({ '{"summary": "half' }, p)
  H.eq(store.read('/repo/three', 'b.lua'), nil, 'corrupt entry')
end)

H.check('rewriting an entry replaces it', function()
  store.write('/repo/one', 'a.lua', vim.tbl_extend('force', entry, { summary = 'New A.' }))
  H.eq(store.read('/repo/one', 'a.lua').summary, 'New A.', 'replaced')
end)

H.finish()
