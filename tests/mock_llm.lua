-- A fake OpenAI-compatible chat endpoint inside Neovim's event loop, so tests need no network.
-- start(replies, opts) returns { port, requests, url }. Each POST's decoded JSON body and headers
-- are appended to `requests` and answered with replies[n] for the nth request (or the last one).
-- A reply is a string (sent as the assistant's message) or { status = 402, body = '...' }.
-- opts.delay_ms holds every reply back that long, for timeout and concurrency tests;
-- opts.timings is added to each reply as llama-server's `timings` object.
local M = {}

local function respond(client, status, body)
  local reply = string.format('HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s', status, #body, body)
  client:write(reply, function() client:close() end)
end

function M.start(replies, opts)
  opts = opts or {}
  if type(replies) == 'string' then replies = { replies } end
  local state = { requests = {}, open = 0, max_open = 0 }
  local server = assert(vim.uv.new_tcp())
  server:bind('127.0.0.1', 0)
  server:listen(16, function()
    local client = assert(vim.uv.new_tcp())
    server:accept(client)
    local buf, continued = '', false
    client:read_start(function(err, data)
      if err or not data then return client:close() end
      buf = buf .. data
      local head_end = buf:find('\r\n\r\n', 1, true)
      if not head_end then return end
      local head = buf:sub(1, head_end)
      if not continued and head:lower():find('expect: 100%-continue') then
        continued = true
        client:write 'HTTP/1.1 100 Continue\r\n\r\n'
      end
      local len = tonumber(head:lower():match 'content%-length:%s*(%d+)') or 0
      local body = buf:sub(head_end + 4)
      if #body < len then return end
      client:read_stop()
      state.count = (state.count or 0) + 1
      local reply = replies[state.count] or replies[#replies]
      state.open = state.open + 1
      state.max_open = math.max(state.max_open, state.open)
      vim.schedule(function() table.insert(state.requests, { head = head, body = vim.json.decode(body) }) end)
      local function send()
        state.open = state.open - 1
        if type(reply) == 'table' then return respond(client, reply.status, reply.body) end
        respond(client, 200, vim.json.encode {
          id = 'mock', choices = { { index = 0, message = { role = 'assistant', content = reply } } },
          usage = { prompt_tokens = 120, completion_tokens = 30, prompt_tokens_details = { cached_tokens = 64 } },
          timings = opts.timings,
        })
      end
      if opts.delay_ms then
        local t = assert(vim.uv.new_timer())
        t:start(opts.delay_ms, 0, function() t:close(); send() end)
      else
        send()
      end
    end)
  end)
  state.port = server:getsockname().port
  state.url = 'http://127.0.0.1:' .. state.port
  state.close = function() server:close() end
  return state
end

return M
