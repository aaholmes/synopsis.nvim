-- Answer each question with the file synopses plus tools that read the code, $WIKI_SAMPLES
-- times, appending to $WIKI_DIR/answers-<arm>.jsonl ($WIKI_OUT names another file, so several
-- processes can run in parallel). Arms (WIKI_ARM):
--   tools: rg, read, outline
--   lsp:   as tools, plus the language server's definition and references
--   bare:  as tools, without the file synopses
--   map:   as tools, with synopsis.map's entries (comments, definitions) in place of the synopses
--   plugin: what :SynopsisAsk sends: its prompt, its map (map.build with the default settings)
--          and its tool settings (exclude, max_bytes)
-- $WIKI_ROOTS ("repo=dir ...") makes the tools read dir instead of repo, e.g. a snapshot taken
-- before the questions were added to the repo. Questions: $WIKI_QUESTIONS. Resumes.
local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local C = dofile(here .. '/common.lua')
local A = dofile(here .. '/agent.lua')
local dir, arm, samples = vim.env.WIKI_DIR, vim.env.WIKI_ARM, tonumber(vim.env.WIKI_SAMPLES or '3')
local ARMS = { tools = { 'rg', 'read', 'outline' }, bare = { 'rg', 'read', 'outline' }, map = { 'rg', 'read', 'outline' }, plugin = { 'rg', 'read', 'outline' }, lsp = { 'rg', 'read', 'outline', 'definition', 'references' } }
assert(ARMS[arm], 'WIKI_ARM must be tools, lsp, bare, map or plugin')
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
-- The bare arm's prompt: the same, without the summaries.
local SYSTEM_BARE = [[You answer questions about a code repository. You are given its name, the
question, and tools that search and read the code. Name the files involved, with their paths. If
the code does not settle a point, say so and mark any inference as a guess. Your final answer: at
most 150 words.]]
-- The map arm's prompt: the tools arm's, with the map in place of the summaries.
local SYSTEM_MAP = [[You answer questions about a code repository. You are given a map of its
files (each file's leading comment and top-level definitions), plus the question, and tools that
search and read the code. Use the map to decide where to look, then check the details in the
code. Name the files involved, with their paths. If the code does not settle a point, say so and
mark any inference as a guess. Your final answer: at most 150 words.]]
local f = assert(io.open(C.here .. '/prompts/ask.md', 'rb'))
local SYSTEM_PLUGIN = vim.trim(f:read '*a')
f:close()
local SYSTEMS = { tools = SYSTEM, lsp = SYSTEM, bare = SYSTEM_BARE, map = SYSTEM_MAP, plugin = SYSTEM_PLUGIN }
local defaults = require('synopsis').config
local plugin_opts = { exclude = defaults.exclude, max_bytes = defaults.max_bytes }

local function one_line(s) return (s or ''):gsub('%s*\n%s*', ' ') end
local files, paths = {}, {}
for _, r in ipairs(C.read_jsonl(dir .. '/synopses.jsonl')) do
  files[r.root] = files[r.root] or {}
  paths[r.root] = paths[r.root] or {}
  table.insert(paths[r.root], r.path)
  table.insert(files[r.root], string.format('%s: %s', r.path, r.summary and one_line(r.summary) or '(no synopsis)'))
end
-- The same context as ask.lua's files arm.
local function context(root)
  if arm == 'bare' then return string.format('REPOSITORY: %s\n', vim.fs.basename(root)) end
  if arm == 'map' then
    local Map = require 'synopsis.map'
    local lines = {}
    for _, p in ipairs(paths[root]) do table.insert(lines, Map.entry(roots[root] or root, p)) end
    table.sort(lines)
    return string.format('REPOSITORY: %s\n\n', vim.fs.basename(root)) .. 'FILE MAP:\n' .. table.concat(lines, '\n') .. '\n'
  end
  if arm == 'plugin' then
    local text
    require('synopsis.map').build(roots[root] or root, vim.tbl_extend('force', plugin_opts, { max_map_chars = defaults.ask.max_map_chars }),
      function(t) text = t end)
    vim.wait(120000, function() return text ~= nil end, 10)
    return string.format('REPOSITORY: %s\n\nFILE MAP:\n%s\n', vim.fs.basename(root), assert(text, 'map not built'))
  end
  table.sort(files[root])
  return string.format('REPOSITORY: %s\n\n', vim.fs.basename(root)) .. 'FILE SYNOPSES:\n' .. table.concat(files[root], '\n') .. '\n'
end

local qs = {}
for path in vim.env.WIKI_QUESTIONS:gmatch '%S+' do vim.list_extend(qs, C.read_jsonl(path)) end
local contexts = {}
if vim.env.WIKI_SHOW_CONTEXT then -- print each repo's context size and stop
  for _, q in ipairs(qs) do contexts[q.repo] = contexts[q.repo] or context(q.repo) end
  for r, c in pairs(contexts) do io.write(r, ' ', #c, ' chars\n') end
  vim.cmd 'qa!'
end
for _, q in ipairs(qs) do
  contexts[q.repo] = contexts[q.repo] or context(q.repo)
  local ctx = contexts[q.repo]
  for s = 1, samples do
    if not done[q.id .. '#' .. s] then
      local t0 = vim.uv.hrtime()
      local r = A.run { cfg = C.cfg.llm, system = SYSTEMS[arm], context = ctx, question = q.question, root = roots[q.repo] or q.repo,
        tools = ARMS[arm], tool_opts = arm == 'plugin' and plugin_opts or {}, max_rounds = 10, key = C.store.root_key(q.repo .. '#' .. arm) }
      C.append(out, { id = q.id, sample = s, arm = arm, answer = r.answer, error = r.error, rounds = r.rounds, calls = r.calls,
        usage = r.usage, context_chars = #ctx, latency_ms = (vim.uv.hrtime() - t0) / 1e6 })
      io.write(arm, ' ', q.id, '#', s, ' ', r.error or ('ok, ' .. #r.calls .. ' calls'), '\n')
      io.flush()
    end
  end
end
A.tools.stop()
vim.cmd 'qa!'
