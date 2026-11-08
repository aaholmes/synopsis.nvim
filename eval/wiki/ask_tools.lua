-- Answer each question with the file synopses plus tools that read the code, $WIKI_SAMPLES
-- times, appending to $WIKI_DIR/answers-<arm>.jsonl ($WIKI_OUT names another file, so several
-- processes can run in parallel). Arms (WIKI_ARM):
--   tools: rg, read, outline
--   lsp:   as tools, plus the language server's definition and references
-- $WIKI_ROOTS ("repo=dir ...") makes the tools read dir instead of repo, e.g. a snapshot taken
-- before the questions were added to the repo. Questions: $WIKI_QUESTIONS. Resumes.
local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local C = dofile(here .. '/common.lua')
local A = dofile(here .. '/agent.lua')
local dir, arm, samples = vim.env.WIKI_DIR, vim.env.WIKI_ARM, tonumber(vim.env.WIKI_SAMPLES or '3')
local ARMS = { tools = { 'rg', 'read', 'outline' }, lsp = { 'rg', 'read', 'outline', 'definition', 'references' } }
assert(ARMS[arm], 'WIKI_ARM must be tools or lsp')
local out = vim.env.WIKI_OUT or string.format('%s/answers-%s.jsonl', dir, arm)
local done = {}
for _, r in ipairs(C.read_jsonl(out)) do if r.answer then done[r.id .. '#' .. r.sample] = true end end
local roots = {}
for pair in (vim.env.WIKI_ROOTS or ''):gmatch '%S+' do
  local repo, d = pair:match '^(.-)=(.+)$'
  roots[repo] = d
end

local SYSTEM = [[You answer questions about a code repository. You are given short summaries of
its files, plus the question, and tools that search and read the code. Use the summaries to
decide where to look, then check the details in the code. Name the files involved, with their
paths. If the code does not settle a point, say so and mark any inference as a guess. Your final
answer: at most 150 words.]]

local function one_line(s) return (s or ''):gsub('%s*\n%s*', ' ') end
local files = {}
for _, r in ipairs(C.read_jsonl(dir .. '/synopses.jsonl')) do
  files[r.root] = files[r.root] or {}
  table.insert(files[r.root], string.format('%s: %s', r.path, r.summary and one_line(r.summary) or '(no synopsis)'))
end
-- The same context as ask.lua's files arm.
local function context(root)
  table.sort(files[root])
  return string.format('REPOSITORY: %s\n\n', vim.fs.basename(root)) .. 'FILE SYNOPSES:\n' .. table.concat(files[root], '\n') .. '\n'
end

local qs = {}
for path in vim.env.WIKI_QUESTIONS:gmatch '%S+' do vim.list_extend(qs, C.read_jsonl(path)) end
for _, q in ipairs(qs) do
  local ctx = context(q.repo)
  for s = 1, samples do
    if not done[q.id .. '#' .. s] then
      local t0 = vim.uv.hrtime()
      local r = A.run { cfg = C.cfg.llm, system = SYSTEM, context = ctx, question = q.question, root = roots[q.repo] or q.repo,
        tools = ARMS[arm], max_rounds = 10, key = C.store.root_key(q.repo .. '#' .. arm) }
      C.append(out, { id = q.id, sample = s, arm = arm, answer = r.answer, error = r.error, rounds = r.rounds, calls = r.calls,
        usage = r.usage, context_chars = #ctx, latency_ms = (vim.uv.hrtime() - t0) / 1e6 })
      io.write(arm, ' ', q.id, '#', s, ' ', r.error or ('ok, ' .. #r.calls .. ' calls'), '\n')
      io.flush()
    end
  end
end
A.tools.stop()
vim.cmd 'qa!'
