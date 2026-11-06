local H = dofile 'tests/harness.lua'
local llm = require 'synopsis.llm'
local mock = dofile 'tests/mock_llm.lua'

vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
local messages = { { role = 'system', content = 'sys' }, { role = 'user', content = 'hello' } }

local function cfg(server, over)
  return vim.tbl_extend('force', {
    url = server and server.url or 'http://127.0.0.1:9', model = 'gpt-6-luna', api_key_env = 'SYNOPSIS_TEST_KEY',
    params = { reasoning_effort = 'none' }, timeout_ms = 5000,
  }, over or {})
end

---Run one request and wait for its callback.
local function run(c)
  local got
  llm.request(c, messages, function(err, text, usage) got = { err = err, text = text, usage = usage } end)
  vim.wait(6000, function() return got ~= nil end, 10)
  return got or {}
end

H.check('sends the model, params and messages with the key, and returns the reply', function()
  local server = mock.start 'A summary.'
  local got = run(cfg(server))
  H.eq(got.err, nil, 'error')
  H.eq(got.text, 'A summary.', 'text')
  vim.wait(500, function() return #server.requests == 1 end)
  local req = server.requests[1]
  H.eq(req.head:match '^POST (%S+)', '/v1/chat/completions', 'path')
  H.eq(req.head:find('Authorization: Bearer sk-test', 1, true) ~= nil, true, 'auth header')
  H.eq(req.body.model, 'gpt-6-luna', 'model')
  H.eq(req.body.reasoning_effort, 'none', 'param')
  H.eq(req.body.stream, false, 'not streamed')
  H.eq(vim.deep_equal(req.body.messages, messages), true, 'messages')
end)

H.check('the token counts the server reports are passed on', function()
  local got = run(cfg(mock.start 'A.'))
  H.eq(got.usage and got.usage.prompt_tokens, 120, 'prompt tokens')
  H.eq(got.usage and got.usage.completion_tokens, 30, 'completion tokens')
  H.eq(got.usage and got.usage.cached_tokens, 64, 'cached prompt tokens')
end)

H.check('an HTTP error becomes a readable error with the status and message', function()
  local server = mock.start { { status = 402, body = '{"error":{"message":"insufficient quota"}}' } }
  local got = run(cfg(server))
  H.eq(got.text, nil, 'no text')
  H.eq(got.err:find('402', 1, true) ~= nil and got.err:find('insufficient quota', 1, true) ~= nil, true, 'err: ' .. tostring(got.err))
end)

H.check('an error body that is not JSON still gives the status', function()
  local server = mock.start { { status = 500, body = 'oops' } }
  local got = run(cfg(server))
  H.eq(got.err:find('500', 1, true) ~= nil, true, 'err: ' .. tostring(got.err))
end)

H.check('a missing key errors without sending anything', function()
  local server = mock.start 'never'
  local got = run(cfg(server, { api_key_env = 'SYNOPSIS_UNSET_KEY' }))
  H.eq(got.err:find('SYNOPSIS_UNSET_KEY', 1, true) ~= nil, true, 'err names the variable: ' .. tostring(got.err))
  vim.wait(200)
  H.eq(#server.requests, 0, 'requests sent')
end)

H.check('no key is needed when api_key_env is false (a local server)', function()
  local server = mock.start 'Local.'
  local got = run(cfg(server, { api_key_env = false }))
  H.eq(got.text, 'Local.', 'text')
  vim.wait(500, function() return #server.requests == 1 end)
  H.eq(server.requests[1].head:find('Authorization', 1, true), nil, 'no auth header')
end)

H.check('a slow server times out with an error', function()
  local server = mock.start('late', { delay_ms = 3000 })
  local got = run(cfg(server, { timeout_ms = 300 }))
  H.eq(got.err ~= nil and got.err:lower():find('timed out', 1, true) ~= nil, true, 'err: ' .. tostring(got.err))
end)

H.check('an unreachable server gives an error, not a crash', function()
  local got = run(cfg(nil))
  H.eq(type(got.err), 'string', 'err')
end)

H.finish()
