-- Answer each question from text only, in one arm, $WIKI_SAMPLES times, appending to
-- $WIKI_DIR/answers-<arm>.jsonl. Arms (WIKI_ARM):
--   files:   the file synopses
--   folders: folder synopses and the repo overview, then the file synopses
--   padded:  synopses of an unrelated repo, cut to the length the folders arm adds, then the
--            file synopses (controls for the extra text)
-- Questions: $WIKI_QUESTIONS (JSONL files, space-separated). Resumes.
local C = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/common.lua')
local dir, arm, samples = vim.env.WIKI_DIR, vim.env.WIKI_ARM, tonumber(vim.env.WIKI_SAMPLES or '3')
assert(({ files = 1, folders = 1, padded = 1 })[arm], 'WIKI_ARM must be files, folders or padded')
local out = string.format('%s/answers-%s.jsonl', dir, arm)
local done = {}
for _, r in ipairs(C.read_jsonl(out)) do if not r.error then done[r.id .. '#' .. r.sample] = true end end

local SYSTEM = [[You answer questions about a code repository. You cannot read the code: you are
given only short summaries of its files (and sometimes of its folders), plus the question. Name
the files or folders involved, with their paths. If the summaries do not settle a point, say so
and mark any inference as a guess. At most 150 words.]]

local function one_line(s) return (s or ''):gsub('%s*\n%s*', ' ') end
local files, folders = {}, {}
for _, r in ipairs(C.read_jsonl(dir .. '/synopses.jsonl')) do
  files[r.root] = files[r.root] or {}
  table.insert(files[r.root], string.format('%s: %s', r.path, r.summary and one_line(r.summary) or '(no synopsis)'))
end
for _, r in ipairs(C.read_jsonl(dir .. '/folders.jsonl')) do
  folders[r.root] = folders[r.root] or {}
  folders[r.root][r.dir] = r.summary or ''
end

local function file_block(root)
  table.sort(files[root])
  return 'FILE SYNOPSES:\n' .. table.concat(files[root], '\n') .. '\n'
end
local function folder_block(root)
  local f = folders[root]
  local lines = {}
  for d, s in pairs(f) do if d ~= '.' then table.insert(lines, string.format('%s/: %s', d, one_line(s))) end end
  table.sort(lines)
  return 'REPO OVERVIEW:\n' .. (f['.'] or '') .. '\n\nFOLDER SYNOPSES:\n' .. table.concat(lines, '\n') .. '\n\n'
end
local small = { ['/Users/adam/synopsis'] = 1, ['/Users/adam/butwhy'] = 1, ['/Users/adam/.config/nvim'] = 1 }
-- Padding comes from another repo of the same size group, so its kind of text matches.
local function padding(root, n)
  local others = {}
  for r in pairs(files) do if r ~= root and (small[r] ~= nil) == (small[root] ~= nil) then table.insert(others, r) end end
  table.sort(others)
  local text = ''
  local i = 0
  while #text < n do
    i = i + 1
    text = text .. file_block(others[(i - 1) % #others + 1]):gsub('^FILE SYNOPSES:\n', '')
  end
  return 'SYNOPSES FROM AN UNRELATED REPOSITORY (not the one asked about):\n' .. text:sub(1, n) .. '\n\n'
end

local function context(root)
  local base = string.format('REPOSITORY: %s\n\n', vim.fs.basename(root))
  if arm == 'files' then return base .. file_block(root) end
  local extra = folder_block(root)
  if arm == 'folders' then return base .. extra .. file_block(root) end
  return base .. padding(root, #extra) .. file_block(root)
end

local qs = {}
for path in vim.env.WIKI_QUESTIONS:gmatch '%S+' do vim.list_extend(qs, C.read_jsonl(path)) end
for _, q in ipairs(qs) do
  local ctx = context(q.repo)
  for s = 1, samples do
    if not done[q.id .. '#' .. s] then
      local user = ctx .. '\nQUESTION: ' .. q.question
      local t0 = vim.uv.hrtime()
      local text, usage, err = C.ask({ { role = 'system', content = SYSTEM }, { role = 'user', content = user } }, ctx,
        C.store.root_key(q.repo .. '#' .. arm))
      C.append(out, { id = q.id, sample = s, arm = arm, answer = text, usage = usage, error = err,
        context_chars = #ctx, latency_ms = (vim.uv.hrtime() - t0) / 1e6 })
      io.write(arm, ' ', q.id, '#', s, ' ', err or 'ok', '\n')
    end
  end
end
vim.cmd 'qa!'
