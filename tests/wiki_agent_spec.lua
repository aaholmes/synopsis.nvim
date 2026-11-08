-- The wiki eval's tool loop: the model asks for tools, gets their output, and answers.
local H = dofile 'tests/harness.lua'
local A = dofile(SYNOPSIS_ROOT .. '/eval/wiki/agent.lua')
local mock = dofile 'tests/mock_llm.lua'

vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
local repo = H.make_repo { ['a.lua'] = 'local x = 1\nreturn x\n' }

local function cfg(server, over)
  return vim.tbl_extend('force', { url = server.url, model = 'm', api_key_env = 'SYNOPSIS_TEST_KEY', params = {}, timeout_ms = 5000 },
    over or {})
end
local function call(id, name, args)
  return { id = id, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local function tool_reply(...) return { message = { role = 'assistant', content = vim.NIL, tool_calls = { ... } } } end
local function run(server, over)
  return A.run(vim.tbl_extend('force', {
    cfg = cfg(server), system = 'sys', context = 'CTX\n', question = 'Q?', root = repo, tools = { 'rg', 'read' }, max_rounds = 4,
  }, over or {}))
end

H.check('with no tool calls, one request is sent with the tools listed, and its text is the answer', function()
  local server = mock.start 'The answer.'
  local r = run(server)
  H.eq(r.answer, 'The answer.', 'answer')
  H.eq(r.rounds, 0, 'rounds')
  H.eq(#server.requests, 1, 'requests')
  local body = server.requests[1].body
  H.eq(#body.tools, 2, 'tools')
  H.eq(body.messages[2].content, 'CTX\n\nQUESTION: Q?', 'user message')
end)

H.check('a tool call is run and its output sent back with the call id', function()
  local server = mock.start { tool_reply(call('c1', 'read', { path = 'a.lua', start = 2, ['end'] = 2 })), 'Done.' }
  local r = run(server)
  H.eq(r.answer, 'Done.', 'answer')
  H.eq(r.rounds, 1, 'rounds')
  H.eq(#server.requests, 2, 'requests')
  local msgs = server.requests[2].body.messages
  H.eq(msgs[3].role, 'assistant', 'assistant turn kept')
  H.eq(msgs[3].tool_calls[1].id, 'c1', 'call kept')
  H.eq(msgs[4].role, 'tool', 'tool role')
  H.eq(msgs[4].tool_call_id, 'c1', 'call id')
  H.eq(msgs[4].content, '2: return x', 'tool output')
  H.eq(r.calls[1].name, 'read', 'trace name')
  H.eq(r.calls[1].chars, #'2: return x', 'trace size')
end)

H.check('several calls in one turn each get an answer', function()
  local server = mock.start { tool_reply(call('c1', 'read', { path = 'a.lua' }), call('c2', 'nope', {})), 'Done.' }
  local r = run(server)
  local msgs = server.requests[2].body.messages
  H.eq(msgs[5].tool_call_id, 'c2', 'second id')
  H.eq(vim.startswith(msgs[5].content, 'error:'), true, 'unknown tool is an error message')
  H.eq(#r.calls, 2, 'trace')
end)

H.check('after max_rounds of tool use the model is told to answer without tools', function()
  local tc = tool_reply(call('c', 'read', { path = 'a.lua' }))
  local server = mock.start { tc, tc, 'Final.' }
  local r = run(server, { max_rounds = 2 })
  H.eq(#server.requests, 3, 'requests')
  H.eq(server.requests[3].body.tool_choice, 'none', 'tool_choice')
  H.eq(server.requests[2].body.tool_choice, nil, 'not before')
  H.eq(r.answer, 'Final.', 'answer')
end)

H.check('tool calls despite tool_choice none give an error, not a loop', function()
  local tc = tool_reply(call('c', 'read', { path = 'a.lua' }))
  local server = mock.start { tc }
  local r = run(server, { max_rounds = 1 })
  H.eq(r.answer, nil, 'answer')
  H.eq(type(r.error), 'string', 'error')
  H.eq(#server.requests, 2, 'requests')
end)

H.check('token counts are summed over the requests', function()
  local server = mock.start { tool_reply(call('c1', 'read', { path = 'a.lua' })), 'Done.' }
  local r = run(server)
  H.eq(r.usage.prompt_tokens, 240, 'prompt')
  H.eq(r.usage.completion_tokens, 60, 'completion')
  H.eq(r.usage.cached_tokens, 128, 'cached')
end)

H.check("with OpenAI's cache, the context gets a cache point and the cache key is sent", function()
  local server = mock.start 'A.'
  run(server, { cfg = cfg(server, { cache = 'openai' }), key = 'k1' })
  local body = server.requests[1].body
  local content = body.messages[2].content
  H.eq(content[1].text, 'CTX\n', 'shared part')
  H.eq(content[1].prompt_cache_breakpoint.mode, 'explicit', 'cache point')
  H.eq(content[2].text, '\nQUESTION: Q?', 'rest')
  H.eq(body.prompt_cache_key, 'k1', 'key')
end)

H.check('a rate-limit error (HTTP 429) is retried', function()
  local server = mock.start { { status = 429, body = '{"error":{"message":"slow down"}}' }, 'A.' }
  local r = run(server, { retry_ms = 10 })
  H.eq(r.answer, 'A.', 'answer')
  H.eq(#server.requests, 2, 'requests')
end)

H.check('an HTTP error ends the run with that error', function()
  local server = mock.start { { status = 500, body = '{"error":{"message":"boom"}}' } }
  local r = run(server)
  H.eq(r.answer, nil, 'answer')
  H.eq(r.error:find('boom', 1, true) ~= nil, true, r.error)
end)

H.finish()
