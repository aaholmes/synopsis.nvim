-- One non-streamed request to an OpenAI-compatible chat endpoint, made with curl. The key is
-- passed on curl's stdin and the body in a temporary file, so neither shows up in `ps`.
local M = {}

---Send `messages` using `cfg` ({ url, chat_path?, model, api_key_env, params?, timeout_ms? })
---and call `callback(err, text, usage)` on the main loop with the reply text or an error
---message. usage is { prompt_tokens, completion_tokens, cached_tokens } when the server reports it.
function M.request(cfg, messages, callback)
  local done = vim.schedule_wrap(callback)
  local key
  if cfg.api_key_env then
    key = vim.env[cfg.api_key_env]
    if not key or key == '' then return done(string.format('set $%s to generate synopses', cfg.api_key_env)) end
  end

  local body = vim.tbl_extend('force', cfg.params or {}, { model = cfg.model, messages = messages, stream = false })
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

  vim.system(cmd, { stdin = stdin, text = true }, function(res)
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
    local content = ok and type(json) == 'table' and json.choices and json.choices[1] and json.choices[1].message
      and json.choices[1].message.content
    if type(content) ~= 'string' then return done('unexpected reply: ' .. (text or ''):sub(1, 200)) end
    local u = type(json.usage) == 'table' and json.usage or nil
    local usage = u and {
      prompt_tokens = u.prompt_tokens,
      completion_tokens = u.completion_tokens,
      cached_tokens = type(u.prompt_tokens_details) == 'table' and u.prompt_tokens_details.cached_tokens or nil,
    }
    done(nil, vim.trim(content), usage)
  end)
end

return M
