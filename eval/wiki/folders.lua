-- Write a synopsis of every folder, bottom-up from its files' and subfolders' synopses, and an
-- overview of each repo, to $WIKI_DIR/folders.jsonl. Reads $WIKI_DIR/synopses.jsonl (fill.lua).
local C = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/common.lua')
local dir = vim.env.WIKI_DIR
local out = dir .. '/folders.jsonl'
local done = {}
for _, r in ipairs(C.read_jsonl(out)) do done[r.root .. ':' .. r.dir] = r.summary end

local FOLDER = [[You write a short synopsis of one folder of a code repository, for a reader who
knows what the project is for but not its details. You are given the synopses of the folder's
files and subfolders. Use ASD-STE100 Simplified Technical English: short sentences, one fact each.

Write one sentence on what the folder is for. Then 1-3 bullets: the main entry points, how the
parts work together, or what other folders it depends on. Name files with backticks. At most 70
words. Only state what the synopses support.]]

local OVERVIEW = [[You write an overview of a code repository for a new contributor. You are given
the synopses of its top-level files and folders. Use ASD-STE100 Simplified Technical English:
short sentences, one fact each.

Write 2 sentences on what the repository is and does. Then 3-6 bullets: the main parts and the
folders that hold them, how the parts connect, and where to start reading. Name paths with
backticks. At most 150 words. Only state what the synopses support.]]

local function one_line(s) return (s or ''):gsub('%s*\n%s*', ' ') end

local by_root = {}
for _, r in ipairs(C.read_jsonl(dir .. '/synopses.jsonl')) do
  by_root[r.root] = by_root[r.root] or {}
  table.insert(by_root[r.root], r)
end

local only = {}
for r in (vim.env.WIKI_REPOS or ''):gmatch '%S+' do only[r] = true end
for root, rows in pairs(by_root) do
  if next(only) and not only[root] then goto continue end
  -- children[dir] = list of { name, text } for files and subfolders directly inside it
  local files, dirs = {}, { ['.'] = true }
  for _, r in ipairs(rows) do
    local d = vim.fs.dirname(r.path)
    files[d] = files[d] or {}
    table.insert(files[d], { name = vim.fs.basename(r.path), text = r.summary and one_line(r.summary) or '(no synopsis: ' .. (r.skipped or r.error or '?') .. ')' })
    while d ~= '.' do dirs[d] = true; d = vim.fs.dirname(d) end
  end
  local list = vim.tbl_keys(dirs)
  -- deepest first, so subfolders are written before their parents
  table.sort(list, function(a, b)
    local da, db = select(2, a:gsub('/', '')) + (a == '.' and -1 or 0), select(2, b:gsub('/', '')) + (b == '.' and -1 or 0)
    if da ~= db then return da > db end
    return a < b
  end)
  local summary = {}
  for _, d in ipairs(list) do
    local key = root .. ':' .. d
    if done[key] then
      summary[d] = done[key]
    else
      local lines = {}
      for _, f in ipairs(files[d] or {}) do table.insert(lines, string.format('%s: %s', f.name, f.text)) end
      for _, sub in ipairs(list) do
        if sub ~= '.' and sub ~= d and vim.fs.dirname(sub) == d and summary[sub] then
          table.insert(lines, string.format('%s/: %s', vim.fs.basename(sub), one_line(summary[sub])))
        end
      end
      table.sort(lines)
      local is_root = d == '.'
      local text, _, err = C.ask({
        { role = 'system', content = is_root and OVERVIEW or FOLDER },
        { role = 'user', content = string.format('REPOSITORY: %s\n%s: %s\n\n%s', vim.fs.basename(root),
          is_root and 'TOP LEVEL' or 'FOLDER', is_root and '' or d .. '/', table.concat(lines, '\n')) },
      })
      summary[d] = text or ''
      C.append(out, { root = root, dir = d, summary = text, error = err })
      io.write(vim.fs.basename(root), ' ', d, ' ', err or 'ok', '\n')
    end
  end
  ::continue::
end
vim.cmd 'qa!'
