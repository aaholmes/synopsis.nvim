-- The wiki eval's tool loop. run(o) asks o.question with o.context (the synopses) and lets the
-- model call o.tools (names from tools.lua) in o.root, for up to o.max_rounds turns of tool
-- calls; then it must answer without tools. o.retry_ms: first wait after a rate-limit error. Blocks until done. Returns
-- { answer, rounds, calls = { {name, args, chars} }, usage = summed token counts, error }.
local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local T = dofile(here .. '/tools.lua')
local llm = require 'synopsis.llm'
local A = { tools = T }

local function ask_once(cfg, messages, extra)
  local got
  llm.request(cfg, messages, function(err, text, usage, message)
    got = { err = err, text = text, usage = usage, message = message }
  end, extra)
  vim.wait((cfg.timeout_ms or 30000) + 5000, function() return got ~= nil end, 10)
  return got or { err = 'no reply in time' }
end

-- Retries on HTTP 429 (rate limit), waiting retry_ms, then twice as long each time, 8 times.
local function ask(cfg, messages, extra, retry_ms)
  local got = ask_once(cfg, messages, extra)
  for i = 1, 8 do
    if not (got.err and got.err:match '^HTTP 429') then break end
    vim.wait(retry_ms * 2 ^ (i - 1))
    got = ask_once(cfg, messages, extra)
  end
  return got
end

function A.run(o)
  local user = o.context .. '\nQUESTION: ' .. o.question
  local messages, extra = llm.prepare(o.cfg, { { role = 'system', content = o.system }, { role = 'user', content = user } },
    o.context, o.key)
  extra.tools = T.schemas(o.tools)
  local r = { rounds = 0, calls = {}, usage = { prompt_tokens = 0, completion_tokens = 0, cached_tokens = 0 } }
  while true do
    local forced = r.rounds >= o.max_rounds
    extra.tool_choice = forced and 'none' or nil
    local got = ask(o.cfg, messages, extra, o.retry_ms or 2000)
    for k in pairs(r.usage) do r.usage[k] = r.usage[k] + ((got.usage or {})[k] or 0) end
    if got.err then r.error = got.err; return r end
    local calls = type(got.message) == 'table' and got.message.tool_calls
    if type(calls) ~= 'table' or #calls == 0 then r.answer = got.text; return r end
    if forced then r.error = 'tool calls after tool_choice none'; return r end
    r.rounds = r.rounds + 1
    table.insert(messages, { role = 'assistant', content = got.message.content, tool_calls = calls })
    for _, c in ipairs(calls) do
      local fn = c['function'] or {}
      local out = T.call(o.root, fn.name, fn.arguments or '{}')
      table.insert(r.calls, { name = fn.name, args = fn.arguments, chars = #out })
      table.insert(messages, { role = 'tool', tool_call_id = c.id, content = out })
    end
  end
end

return A
