-- The wiki eval's blocking wrapper around the plugin's question loop.
local H = dofile 'tests/harness.lua'
local A = dofile(SYNOPSIS_ROOT .. '/eval/wiki/agent.lua')
local mock = dofile 'tests/mock_llm.lua'

vim.env.SYNOPSIS_TEST_KEY = 'sk-test'
local repo = H.make_repo { ['a.lua'] = 'local x = 1\nreturn x\n' }

H.check('run waits for the answer and returns the loop result, tool calls included', function()
  local call = { id = 'c1', type = 'function', ['function'] = { name = 'read', arguments = '{"path":"a.lua","start":2,"end":2}' } }
  local server = mock.start { { message = { role = 'assistant', content = vim.NIL, tool_calls = { call } } }, 'Done.' }
  local r = A.run { cfg = { url = server.url, model = 'm', api_key_env = 'SYNOPSIS_TEST_KEY', params = {}, timeout_ms = 5000 },
    system = 'sys', context = 'CTX\n', question = 'Q?', root = repo, tools = { 'read', 'definition' }, max_rounds = 4 }
  H.eq(r.answer, 'Done.', 'answer')
  H.eq(r.calls[1].name, 'read', 'call')
  H.eq(#server.requests[1].body.tools, 2, 'eval tools offered')
end)

H.finish()
