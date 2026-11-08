-- Shared by the wiki eval scripts: setup()'s model settings and a blocking request.
local here = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))))
vim.opt.rtp:prepend(here)
local M = { llm = require 'synopsis.llm', store = require 'synopsis.store', prompt = require 'synopsis.prompt' }
M.cfg = vim.deepcopy(require('synopsis').config)
M.here = here

---Send messages and wait; returns text, usage or nil, err. `shared` marks a cached prefix of the
---last message, as the plugin does.
function M.ask(messages, shared, key, params)
  local cfg = params and vim.tbl_deep_extend('force', M.cfg.llm, { params = params }) or M.cfg.llm
  local sent, extra = M.llm.prepare(cfg, messages, shared, key)
  local got
  M.llm.request(cfg, sent, function(err, text, usage) got = { err = err, text = text, usage = usage } end, extra)
  vim.wait(cfg.timeout_ms + 5000, function() return got ~= nil end, 10)
  got = got or { err = 'no reply in time' }
  return got.text, got.usage, got.err
end

function M.read_jsonl(path)
  local out = {}
  if vim.uv.fs_stat(path) then
    for _, l in ipairs(vim.fn.readfile(path)) do if l ~= '' then table.insert(out, vim.json.decode(l)) end end
  end
  return out
end

function M.append(path, obj)
  local f = assert(io.open(path, 'a'))
  f:write(vim.json.encode(obj), '\n')
  f:close()
end

return M
