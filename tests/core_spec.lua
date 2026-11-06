local H = dofile 'tests/harness.lua'
local core = require 'whatsthis.core'
local store = require 'whatsthis.store'
local prompt = require 'whatsthis.prompt'
local mock = dofile 'tests/mock_llm.lua'

vim.env.WHATSTHIS_TEST_KEY = 'sk-test'
local background = WHATSTHIS_ROOT .. '/tests/fixtures/background.md'

local function setup(files, server, over)
  local root = H.make_repo(files or {
    ['a.lua'] = 'return "a"', ['b.lua'] = 'return "b"', ['c.lua'] = 'return "c"',
    ['.env'] = 'KEY=1', ['bin.dat'] = 'ab\0cd', ['big.txt'] = string.rep('z', 2000),
  })
  local views = {}
  local c = core.new(vim.tbl_extend('force', {
    llm = { url = server and server.url or 'http://127.0.0.1:9', model = 'mock-model', api_key_env = 'WHATSTHIS_TEST_KEY' },
    background = background, delay_ms = 50, max_bytes = 1000, max_concurrent = 3,
    exclude = { '.env*', '*.pem' },
    render = function(path, view) table.insert(views, { path = path, kind = view.kind, text = view.text }) end,
  }, over or {}))
  return c, root, views
end

local function last(views) return views[#views] or {} end
local function kinds(views, path)
  local out = {}
  for _, v in ipairs(views) do
    if v.path == path then table.insert(out, v.kind) end
  end
  return table.concat(out, ',')
end

H.check('a fresh cached summary is shown immediately and nothing is requested', function()
  local server = mock.start 'unused'
  local c, root, views = setup(nil, server)
  local text = 'return "a"'
  store.write(root, 'a.lua', { path = 'a.lua', content_hash = vim.fn.sha256(text), prompt_hash = prompt.hash(background, 'mock-model'), model = 'mock-model', summary = 'Cached A.', created = 0 })
  c:preview(root .. '/a.lua')
  H.eq(last(views).kind, 'summary', 'kind')
  H.eq(last(views).text, 'Cached A.', 'text')
  vim.wait(200)
  H.eq(#server.requests, 0, 'requests')
end)

H.check('a missing summary is requested once after the delay, then shown and cached', function()
  local server = mock.start 'Summary of A.'
  local c, root, views = setup(nil, server)
  c:preview(root .. '/a.lua')
  H.eq(last(views).kind, 'waiting', 'first view')
  H.eq(#server.requests, 0, 'nothing sent before the delay')
  vim.wait(2000, function() return last(views).kind == 'summary' end, 10)
  H.eq(kinds(views, root .. '/a.lua'), 'waiting,pending,summary', 'views')
  H.eq(last(views).text, 'Summary of A.', 'text')
  H.eq(#server.requests, 1, 'requests')
  H.eq(store.read(root, 'a.lua').summary, 'Summary of A.', 'cached')
end)

H.check('leaving a file before the delay sends nothing', function()
  local server = mock.start 'unused'
  local c, root = setup(nil, server)
  c:preview(root .. '/a.lua')
  c:leave()
  vim.wait(200)
  H.eq(#server.requests, 0, 'requests')
end)

H.check('moving A, B, A quickly requests only A', function()
  local server = mock.start 'Summary.'
  local c, root, views = setup(nil, server)
  c:preview(root .. '/a.lua')
  c:preview(root .. '/b.lua')
  c:preview(root .. '/a.lua')
  vim.wait(2000, function() return last(views).kind == 'summary' end, 10)
  vim.wait(200)
  H.eq(#server.requests, 1, 'requests')
  H.eq(server.requests[1].body.messages[2].content:find('FILE: a.lua', 1, true) ~= nil, true, 'request is for a.lua')
end)

H.check('a reply that arrives after moving on is cached but not shown', function()
  local server = mock.start('Late A.', { delay_ms = 300 })
  local c, root, views = setup(nil, server)
  c:preview(root .. '/a.lua')
  vim.wait(1000, function() return last(views).kind == 'pending' end, 10)
  c:preview(root .. '/.env')
  vim.wait(2000, function() return store.read(root, 'a.lua') ~= nil end, 10)
  vim.wait(100)
  H.eq(store.read(root, 'a.lua').summary, 'Late A.', 'cached')
  H.eq(last(views).path, root .. '/.env', 'last view is for the current file')
end)

H.check('a request already sent is not repeated when the file is previewed again', function()
  local server = mock.start('A.', { delay_ms = 300 })
  local c, root, views = setup(nil, server)
  c:preview(root .. '/a.lua')
  vim.wait(1000, function() return last(views).kind == 'pending' end, 10)
  c:preview(root .. '/b.lua')
  c:preview(root .. '/a.lua')
  H.eq(last(views).kind, 'pending', 'shown as pending again')
  vim.wait(2000, function() return last(views).kind == 'summary' end, 10)
  H.eq(#server.requests, 1, 'requests')
end)

H.check('an outdated summary is shown marked, then replaced', function()
  local server = mock.start 'New A.'
  local c, root, views = setup(nil, server)
  store.write(root, 'a.lua', { path = 'a.lua', content_hash = 'old', prompt_hash = prompt.hash(background, 'mock-model'), model = 'mock-model', summary = 'Old A.', created = 0 })
  c:preview(root .. '/a.lua')
  H.eq(last(views).kind, 'outdated', 'first view kind')
  H.eq(last(views).text, 'Old A.', 'first view text')
  vim.wait(2000, function() return last(views).kind == 'summary' end, 10)
  H.eq(last(views).text, 'New A.', 'replaced')
end)

H.check('binary, excluded and oversized files are skipped with a reason', function()
  local server = mock.start 'unused'
  local c, root, views = setup(nil, server)
  for _, name in ipairs { 'bin.dat', '.env', 'big.txt' } do
    c:preview(root .. '/' .. name)
    H.eq(last(views).kind, 'skipped', name .. ' kind')
    H.eq(type(last(views).text), 'string', name .. ' reason')
  end
  vim.wait(200)
  H.eq(#server.requests, 0, 'requests')
end)

H.check('an error is shown and nothing is cached', function()
  local server = mock.start { { status = 402, body = '{"error":{"message":"no credit"}}' } }
  local c, root, views = setup(nil, server)
  c:preview(root .. '/a.lua')
  vim.wait(2000, function() return last(views).kind == 'error' end, 10)
  H.eq(last(views).text:find('no credit', 1, true) ~= nil, true, 'message')
  H.eq(store.read(root, 'a.lua'), nil, 'cached')
end)

H.check('no more than max_concurrent requests run, and queued ones still finish', function()
  local server = mock.start('S.', { delay_ms = 300 })
  local c, root = setup(nil, server, { max_concurrent = 2 })
  for _, name in ipairs { 'a.lua', 'b.lua', 'c.lua' } do
    c:preview(root .. '/' .. name)
    vim.wait(80)
  end
  vim.wait(3000, function() return store.read(root, 'c.lua') ~= nil end, 10)
  H.eq(server.max_open <= 2, true, 'max open: ' .. server.max_open)
  H.eq(#server.requests, 3, 'requests')
end)

H.finish()
