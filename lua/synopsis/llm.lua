-- One non-streamed request to an OpenAI-compatible chat endpoint, made with curl. The key is
-- passed on curl's stdin and the body in a temporary file, so neither shows up in `ps`.
local M = {}

local function uses_openai_cache(cfg)
  if cfg.cache == 'openai' then return true end
  return cfg.cache == 'auto' and (cfg.url or ''):match '^https://api%.openai%.com' ~= nil
end

---The messages and extra body fields for a request, given `shared`, the start of the last user
---turn that other requests share, and `key`, a cache key for the repo.
---With OpenAI's cache, that start becomes its own text block with a cache point, and caching is
---limited to cache points: the rest of each prompt is used once, and writing it to the cache
---would cost more than reading it normally.
function M.prepare(cfg, messages, shared, key)
  local extra = {}
  if cfg.prompt_cache_key ~= false and key then extra.prompt_cache_key = key end
  local last = messages[#messages]
  if not (uses_openai_cache(cfg) and shared and shared ~= '' and type(last.content) == 'string'
      and last.content:sub(1, #shared) == shared) then
    return messages, extra
  end
  local out = vim.deepcopy(messages)
  out[#out].content = {
    { type = 'text', text = shared, prompt_cache_breakpoint = { mode = 'explicit' } },
    { type = 'text', text = last.content:sub(#shared + 1) },
  }
  extra.prompt_cache_options = { mode = 'explicit' }
  return out, extra
end

---Send `messages` using `cfg` ({ url, chat_path?, model, api_key_env, params?, timeout_ms? })
---and call `callback(err, text, usage, message)` on the main loop with the reply text or an error
---message. message is the whole assistant message; when it holds tool_calls, text may be ''. usage is { prompt_tokens, completion_tokens, cached_tokens, cache_write_tokens } when the server reports it.
---`extra` holds more body fields for this request only. Returns { cancel = fn }: after
---cancel(), the request is stopped and callback is never called.
function M.request(cfg, messages, callback, extra)
  local handle = { cancelled = false }
  local proc
  function handle.cancel()
    handle.cancelled = true
    if proc then pcall(proc.kill, proc, 15) end
  end
  local done = vim.schedule_wrap(function(...)
    if not handle.cancelled then callback(...) end
  end)
  local key
  if cfg.api_key_env then
    key = vim.env[cfg.api_key_env]
    if not key or key == '' then
      done(string.format('set $%s to generate synopses', cfg.api_key_env))
      return handle
    end
  end

  local body = vim.tbl_extend('force', cfg.params or {}, extra or {}, { model = cfg.model, messages = messages, stream = false })
  local body_file = vim.fn.tempname()
  local f = assert(io.open(body_file, 'wb'))
  f:write(vim.json.encode(body))
  f:close()

  local timeout_ms = cfg.timeout_ms or 30000
  local cmd = {
    'curl', '--silent', '--show-error',
    '--max-time', string.format('%.3f', timeout_ms / 1000),
    '-H', 'Content-Type: application/json',
    '-H', '@-',
    '--data-binary', '@' .. body_file,
    '-w', '\n%{http_code}',
    cfg.url .. (cfg.chat_path or '/v1/chat/completions'),
  }
  local stdin = key and ('Authorization: Bearer ' .. key .. '\n') or '\n'

  proc = vim.system(cmd, { stdin = stdin, text = true }, function(res)
    os.remove(body_file)
    if res.code == 28 then return done(string.format('request timed out after %d ms', timeout_ms)) end
    if res.code ~= 0 then return done('request failed: ' .. vim.trim(res.stderr or ('curl exit ' .. res.code))) end
    local text, status = res.stdout:match '^(.*)\n(%d+)$'
    status = tonumber(status)
    local ok, json = pcall(vim.json.decode, text or '')
    if status ~= 200 then
      local msg = ok and type(json) == 'table' and type(json.error) == 'table' and json.error.message or vim.trim(text or '')
      return done(string.format('HTTP %s: %s', tostring(status), msg))
    end
    local message = ok and type(json) == 'table' and json.choices and json.choices[1] and json.choices[1].message
    local content = type(message) == 'table' and message.content
    if type(content) ~= 'string' then
      if type(message) == 'table' and type(message.tool_calls) == 'table' then content = '' end
      if type(content) ~= 'string' then return done('unexpected reply: ' .. (text or ''):sub(1, 200)) end
    end
    local u = type(json.usage) == 'table' and json.usage or nil
    local usage = u and {
      prompt_tokens = u.prompt_tokens,
      completion_tokens = u.completion_tokens,
      cached_tokens = type(u.prompt_tokens_details) == 'table' and u.prompt_tokens_details.cached_tokens or nil,
      cache_write_tokens = type(u.prompt_tokens_details) == 'table' and u.prompt_tokens_details.cache_write_tokens or nil,
      -- llama-server's own report: tokens reused from its cache (cache_n), read (prompt_n), times.
      timings = type(json.timings) == 'table' and json.timings or nil,
    }
    done(nil, vim.trim(content), usage, message)
  end)
  return handle
end

return M
