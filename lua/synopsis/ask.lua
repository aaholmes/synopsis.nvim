-- The question loop behind :SynopsisAsk. start(o) asks o.question with o.context (the file map)
-- and lets the model call o.tools (names from tools.lua) in o.root, for up to o.max_rounds turns
-- of tool calls; then it must answer without tools. Nothing blocks: o.on_call(call) reports each
-- tool call as it starts, and o.on_done(result) gets
--   { answer, rounds, calls = { {name, args, chars} }, usage = summed token counts, error, cancelled }.
-- Returns a handle: cancel() stops the run; follow_up(question, on_done) asks again in the same
-- conversation. o.tool_opts ({ exclude, max_bytes }) is passed to the tools; o.retry_ms is the
-- first wait after a rate-limit error (HTTP 429), doubled on each of up to 8 retries.
-- o.toolset replaces tools.lua (any table with schemas and call_async), e.g. for the eval.
local llm = require 'synopsis.llm'
local T = require 'synopsis.tools'
local M = {}

function M.start(o)
  local user = o.context .. '\nQUESTION: ' .. o.question
  local messages, extra = llm.prepare(o.cfg, { { role = 'system', content = o.system }, { role = 'user', content = user } },
    o.context, o.key)
  local tools = o.toolset or T
  extra.tools = tools.schemas(o.tools)
  local retry_ms = o.retry_ms or 2000
  local handle, stop = {}, nil -- stop() cancels whatever is running now
  local cancelled, finish = false, nil

  local function run(on_done)
    local r = { rounds = 0, calls = {}, usage = { prompt_tokens = 0, completion_tokens = 0, cached_tokens = 0 } }
    local finished = false
    finish = function(extra_fields)
      if finished then return end
      finished = true
      stop = nil
      on_done(vim.tbl_extend('force', r, extra_fields or {}))
    end

    local function run_calls(calls, i, next_round)
      if cancelled then return end
      local c = calls[i]
      if not c then return next_round() end
      local fn = c['function'] or {}
      local args = fn.arguments or '{}'
      if o.on_call then o.on_call { name = fn.name, args = args } end
      stop = tools.call_async(o.root, fn.name, args, o.tool_opts or {}, function(out)
        if cancelled then return end
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
          if cancelled then return end
          for k in pairs(r.usage) do r.usage[k] = r.usage[k] + ((usage or {})[k] or 0) end
          if err and err:match '^HTTP 429' and attempt <= 8 then
            local timer = vim.defer_fn(function() send(attempt + 1) end, retry_ms * 2 ^ (attempt - 1))
            stop = function() timer:stop() end
            return
          end
          if err then return finish { error = err } end
          local calls = type(message) == 'table' and message.tool_calls
          if type(calls) ~= 'table' or #calls == 0 then
            table.insert(messages, { role = 'assistant', content = text })
            return finish { answer = text }
          end
          if forced then return finish { error = 'tool calls after tool_choice none' } end
          r.rounds = r.rounds + 1
          table.insert(messages, { role = 'assistant', content = message.content, tool_calls = calls })
          run_calls(calls, 1, round)
        end, extra)
        stop = req.cancel
      end
      send(1)
    end
    round()
  end

  function handle.cancel()
    if cancelled then return end
    cancelled = true
    if stop then stop() end
    if finish then finish { cancelled = true } end
  end

  function handle.follow_up(question, on_done)
    if cancelled then return end
    table.insert(messages, { role = 'user', content = question })
    run(on_done)
  end

  run(o.on_done)
  return handle
end

return M
