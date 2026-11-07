-- Grade the synopses in a results file (from eval/collect.lua) for factual errors with the
-- default model (GPT-6 Luna), and write one JSON line per synopsis to $SYNOPSIS_JUDGED:
-- path, model, and the judge's claims with verdicts. Costs money; eval/local/report.py reads the
-- output and never calls a model.
--   SYNOPSIS_RESULTS=in.jsonl SYNOPSIS_JUDGED=out.jsonl nvim --headless -u NONE -c 'luafile eval/judge.lua'
local here = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))
vim.opt.rtp:prepend(here)
local llm = require 'synopsis.llm'
local cfg = vim.deepcopy(require('synopsis').config.llm)
cfg.params = vim.tbl_extend('force', cfg.params or {}, { response_format = { type = 'json_object' } })
local template = table.concat(vim.fn.readfile(here .. '/eval/judge_prompt.md'), '\n')

---The synopsis without a model's thinking; nil if the thinking never ended.
local function answer(text)
  if not text then return nil end
  if text:find('<think>', 1, true) then
    local after = text:match '</think>%s*(.*)$'
    return after and vim.trim(after) or nil
  end
  return text
end

local out = assert(io.open(assert(vim.env.SYNOPSIS_JUDGED, 'set SYNOPSIS_JUDGED'), 'a'))
for line in io.lines((assert(vim.env.SYNOPSIS_RESULTS, 'set SYNOPSIS_RESULTS'))) do
  local r = vim.json.decode(line)
  local summary = answer(r.summary ~= vim.NIL and r.summary or nil)
  local row = { path = r.path, root = r.root, model = r.model }
  if not summary then
    row.no_answer = true
  else
    local text = table.concat(vim.fn.readfile(r.root .. '/' .. r.path), '\n'):sub(1, 40000)
    local prompt = template:gsub('%${(%w+)}', { path = r.path, content = text, summary = summary })
    local got
    llm.request(cfg, { { role = 'user', content = prompt } }, function(err, reply) got = { err = err, reply = reply } end)
    vim.wait(60000, function() return got ~= nil end, 10)
    local ok, parsed = pcall(vim.json.decode, got and got.reply or '')
    if ok and type(parsed) == 'table' and type(parsed.claims) == 'table' then
      row.claims = parsed.claims
    else
      row.error = got and (got.err or 'unparseable reply') or 'no reply'
    end
  end
  out:write(vim.json.encode(row), '\n')
  out:flush()
end
out:close()
vim.cmd 'qa!'
