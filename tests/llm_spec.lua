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

H.check('extra body fields are sent alongside the params', function()
  local server = mock.start 'A.'
  local got
  llm.request(cfg(server), messages, function(err) got = err or true end, { prompt_cache_key = 'k1' })
  vim.wait(6000, function() return got ~= nil end, 10)
  vim.wait(500, function() return #server.requests == 1 end)
  H.eq(server.requests[1].body.prompt_cache_key, 'k1', 'extra field')
  H.eq(server.requests[1].body.reasoning_effort, 'none', 'params kept')
end)

local built = { { role = 'system', content = 'sys' }, { role = 'user', content = 'SHAREDfile' } }

H.check("cache = 'openai' marks the shared part with a cache point and caches only there", function()
  local m, extra = llm.prepare({ url = 'http://x', cache = 'openai' }, built, 'SHARED', 'k1')
  local blocks = m[2].content
  H.eq(type(blocks), 'table', 'user turn split into blocks')
  H.eq(blocks[1].type .. blocks[1].text, 'textSHARED', 'shared block')
  H.eq(blocks[1].prompt_cache_breakpoint and blocks[1].prompt_cache_breakpoint.mode, 'explicit', 'cache point')
  H.eq(blocks[2].text, 'file', 'rest')
  H.eq(blocks[2].prompt_cache_breakpoint, nil, 'no cache point on the rest')
  H.eq(m[1].content, 'sys', 'system turn unchanged')
  H.eq(extra.prompt_cache_options and extra.prompt_cache_options.mode, 'explicit', 'explicit-only caching')
  H.eq(extra.prompt_cache_key, 'k1', 'key')
  H.eq(built[2].content, 'SHAREDfile', 'input not modified')
end)

H.check("cache = 'auto' uses OpenAI's cache points only for api.openai.com", function()
  local m = llm.prepare({ url = 'https://api.openai.com', cache = 'auto' }, built, 'SHARED', 'k1')
  H.eq(type(m[2].content), 'table', 'openai')
  local m2, extra = llm.prepare({ url = 'http://127.0.0.1:8080', cache = 'auto' }, built, 'SHARED', 'k1')
  H.eq(m2[2].content, 'SHAREDfile', 'local server: plain text')
  H.eq(extra.prompt_cache_options, nil, 'local server: no options')
  H.eq(extra.prompt_cache_key, 'k1', 'key still sent')
end)

H.check('cache = false and prompt_cache_key = false send plain messages and no extra fields', function()
  local m, extra = llm.prepare({ url = 'https://api.openai.com', cache = false, prompt_cache_key = false }, built, 'SHARED', 'k1')
  H.eq(m[2].content, 'SHAREDfile', 'plain')
  H.eq(next(extra), nil, 'no extra fields')
end)

H.check('the token counts the server reports are passed on', function()
  local got = run(cfg(mock.start 'A.'))
  H.eq(got.usage and got.usage.prompt_tokens, 120, 'prompt tokens')
  H.eq(got.usage and got.usage.completion_tokens, 30, 'completion tokens')
  H.eq(got.usage and got.usage.cached_tokens, 64, 'cached prompt tokens')
  H.eq(got.usage and got.usage.cache_write_tokens, 900, 'tokens written to the cache')
end)

H.check("llama-server's timings, when present, are passed on with the token counts", function()
  local got = run(cfg(mock.start('A.', { timings = { cache_n = 2000, prompt_n = 500, prompt_ms = 812.5 } })))
  H.eq(got.usage and got.usage.timings and got.usage.timings.cache_n, 2000, 'cache_n')
  H.eq(got.usage.timings.prompt_ms, 812.5, 'prompt_ms')
end)

H.check('a reply with tool calls and no text passes on the whole message', function()
  local calls = { { id = 'c1', type = 'function', ['function'] = { name = 'rg', arguments = '{"pattern":"x"}' } } }
  local server = mock.start { { message = { role = 'assistant', content = vim.NIL, tool_calls = calls } } }
  local got
  llm.request(cfg(server), messages, function(err, text, usage, message) got = { err = err, text = text, message = message } end)
  vim.wait(6000, function() return got ~= nil end, 10)
  H.eq(got.err, nil, 'error')
  H.eq(got.text, '', 'text')
  H.eq(got.message.tool_calls[1]['function'].name, 'rg', 'tool call')
end)

H.check('a cancelled request never calls back', function()
  local server = mock.start('Late.', { delay_ms = 300 })
  local called = false
  local handle = llm.request(cfg(server), messages, function() called = true end)
  vim.wait(100)
  handle.cancel()
  vim.wait(800)
  H.eq(called, false, 'callback')
end)

H.check('every request returns a handle, even one that fails before sending', function()
  local handle = llm.request(cfg(nil, { api_key_env = 'SYNOPSIS_NO_SUCH_KEY' }), messages, function() end)
  H.eq(type(handle.cancel), 'function', 'cancel')
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
