-- The question loop behind :SynopsisAsk. conversation(o) holds one conversation about a repo:
-- c:ask(question, { on_call, on_done }) sends a question with o.context (the file map) before the
-- first one, and lets the model call o.tools (names from tools.lua) in o.root, for up to
-- o.max_rounds turns of tool calls; then it must answer without tools. Nothing blocks:
-- on_call(call) reports each tool call as it starts, and on_done(result) gets
--   { answer, rounds, calls = { {name, args, chars} }, usage = summed token counts, error, cancelled }.
-- c:cancel() stops the question being answered and forgets it, so the conversation can go on;
-- c:busy() says whether one is running. o.tool_opts ({ exclude, max_bytes }) is passed to the
-- tools; o.retry_ms is the first wait after a rate-limit error (HTTP 429), doubled on each of up
-- to 8 retries; o.toolset replaces tools.lua (any table with schemas and call_async).
-- start(o) is the older interface: one conversation, asked o.question, with a handle whose
-- cancel() ends it and follow_up(question, on_done) continues it.
local llm = require 'synopsis.llm'
local T = require 'synopsis.tools'
local M = {}

local Convo = {}
Convo.__index = Convo

function M.conversation(o)
  return setmetatable({ o = o, tools = o.toolset or T }, Convo)
end

function Convo:busy() return self.run ~= nil end

function Convo:ask(question, cb)
  assert(not self.run, 'a question is already being answered')
  cb = cb or {}
  local o = self.o
  local snapshot = self.messages and #self.messages or 0
  if not self.messages then
    local user = o.context .. '\nQUESTION: ' .. question
    self.messages, self.extra = llm.prepare(o.cfg, { { role = 'system', content = o.system }, { role = 'user', content = user } },
      o.context, o.key)
    self.extra.tools = self.tools.schemas(o.tools)
  else
    table.insert(self.messages, { role = 'user', content = question })
  end
  local messages, extra, tools = self.messages, self.extra, self.tools
  local retry_ms = o.retry_ms or 2000
  local run = { snapshot = snapshot, r = { rounds = 0, calls = {}, usage = { prompt_tokens = 0, completion_tokens = 0, cached_tokens = 0 } } }
  self.run = run
  local r = run.r

  run.finish = function(fields)
    if run.done then return end
    run.done = true
    run.stop = nil
    if self.run == run then self.run = nil end
    if cb.on_done then cb.on_done(vim.tbl_extend('force', r, fields or {})) end
  end

  local function run_calls(calls, i, next_round)
    if run.cancelled then return end
    local c = calls[i]
    if not c then return next_round() end
    local fn = c['function'] or {}
    local args = fn.arguments or '{}'
    if cb.on_call then cb.on_call { name = fn.name, args = args } end
    run.stop = tools.call_async(o.root, fn.name, args, o.tool_opts or {}, function(out)
      if run.cancelled then return end
      table.insert(r.calls, { name = fn.name, args = args, chars = #out })
      table.insert(messages, { role = 'tool', tool_call_id = c.id, content = out })
      run_calls(calls, i + 1, next_round)
    end)
  end

  local function round()
    local forced = r.rounds >= o.max_rounds
    extra.tool_choice = forced and 'none' or nil
    local function send(attempt)
      local req = llm.request(o.cfg, messages, function(err, text, usage, message)
        if run.cancelled then return end
        for k in pairs(r.usage) do r.usage[k] = r.usage[k] + ((usage or {})[k] or 0) end
        if err and err:match '^HTTP 429' and attempt <= 8 then
          local timer = vim.defer_fn(function() send(attempt + 1) end, retry_ms * 2 ^ (attempt - 1))
          run.stop = function() timer:stop() end
          return
        end
        if err then return run.finish { error = err } end
        local calls = type(message) == 'table' and message.tool_calls
        if type(calls) ~= 'table' or #calls == 0 then
          table.insert(messages, { role = 'assistant', content = text })
          return run.finish { answer = text }
        end
        if forced then return run.finish { error = 'tool calls after tool_choice none' } end
        r.rounds = r.rounds + 1
        table.insert(messages, { role = 'assistant', content = message.content, tool_calls = calls })
        run_calls(calls, 1, round)
      end, extra)
      run.stop = req.cancel
    end
    send(1)
  end
  round()
end

---Stop the question being answered, and forget it: the messages go back to how they were before
---it, so the next question starts clean.
function Convo:cancel()
  local run = self.run
  if not run then return end
  run.cancelled = true
  if run.stop then run.stop() end
  if run.snapshot == 0 then
    self.messages, self.extra = nil, nil
  else
    for i = #self.messages, run.snapshot + 1, -1 do self.messages[i] = nil end
  end
  run.finish { cancelled = true }
end

function M.start(o)
  local c = M.conversation(o)
  local ended = false
  local handle = {}
  function handle.cancel()
    if ended then return end
    ended = true
    c:cancel()
  end
  function handle.follow_up(question, on_done)
    if ended then return end
    c:ask(question, { on_call = o.on_call, on_done = on_done })
  end
  c:ask(o.question, { on_call = o.on_call, on_done = o.on_done })
  return handle
end

return M
