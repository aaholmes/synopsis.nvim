-- Summarize a list of files with the real model, one request at a time, and append one JSON
-- line per file to $SYNOPSIS_OUT: path, latency, token counts and the summary. Uses setup()'s
-- defaults (model, background file). Costs money; the analysis reads the file and never calls
-- the model. Run:
--   SYNOPSIS_OUT=out.jsonl nvim --headless -u NONE -c 'luafile eval/collect.lua' root:relpath ...
local here = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.rtp:prepend(here)
local prompt, llm, store = require 'synopsis.prompt', require 'synopsis.llm', require 'synopsis.store'
local cfg = vim.deepcopy(require('synopsis').config)
-- A local server instead of the default model: SYNOPSIS_URL and SYNOPSIS_MODEL, no API key.
if vim.env.SYNOPSIS_URL then
  cfg.llm = vim.tbl_extend('force', cfg.llm, { url = vim.env.SYNOPSIS_URL, model = vim.env.SYNOPSIS_MODEL or 'local', api_key_env = false, timeout_ms = 300000,
    -- Extra request fields as JSON, e.g. '{"max_tokens":400,"chat_template_kwargs":{"enable_thinking":false}}'.
    params = vim.env.SYNOPSIS_PARAMS and vim.json.decode(vim.env.SYNOPSIS_PARAMS) or {} })
end
local background = vim.fs.normalize(cfg.background)
local out = assert(io.open(assert(vim.env.SYNOPSIS_OUT, 'set SYNOPSIS_OUT'), 'a'))

-- Files come as root:relpath arguments, or one per line in the file $SYNOPSIS_FILES (safer: zsh
-- treats `$root:l...` in an argument as a modifier).
local args = vim.v.argv
if vim.env.SYNOPSIS_FILES then args = vim.fn.readfile(vim.env.SYNOPSIS_FILES) end
for _, arg in ipairs(args) do
  local root, rel = arg:match '^(/[^:]+):(.+)$'
  if root then
    local text = table.concat(vim.fn.readfile(root .. '/' .. rel), '\n')
    local messages, shared = prompt.build { root = root, relpath = rel, text = text, background = background }
    local t0, got = vim.uv.hrtime(), nil
    -- The same cache fields the plugin sends; SYNOPSIS_NO_CACHE=1 sends none.
    local llm_cfg = vim.env.SYNOPSIS_NO_CACHE and vim.tbl_extend('force', cfg.llm, { cache = false, prompt_cache_key = false }) or cfg.llm
    local sent, extra = llm.prepare(llm_cfg, messages, shared, store.root_key(root))
    llm.request(cfg.llm, sent, function(err, summary, usage) got = { err = err, summary = summary, usage = usage } end, extra)
    vim.wait(cfg.llm.timeout_ms + 5000, function() return got ~= nil end, 10)
    got = got or { err = 'no reply in time' }
    out:write(vim.json.encode {
      root = root, path = rel, model = cfg.llm.model, latency_ms = (vim.uv.hrtime() - t0) / 1e6,
      input_chars = #messages[1].content + #messages[2].content, usage = got.usage or vim.empty_dict(),
      error = got.err, summary = got.summary,
    }, '\n')
    out:flush()
    io.write(rel, ' ', got.err or 'ok', '\n')
  end
end
out:close()
vim.cmd 'qa!'
