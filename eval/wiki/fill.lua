-- Write a synopsis of every tracked text file in each repo to $WIKI_DIR/synopses.jsonl, skipping
-- the files the plugin skips (exclude globs, too large, binary). Resumes: done files are skipped.
-- Run: WIKI_DIR=dir WIKI_REPOS="/a /b" nvim --headless -u NONE -c 'luafile eval/wiki/fill.lua'
local C = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/common.lua')
local out = vim.env.WIKI_DIR .. '/synopses.jsonl'
local done = {}
for _, r in ipairs(C.read_jsonl(out)) do done[r.root .. ':' .. r.path] = true end
local exclude = vim.tbl_map(function(g) return vim.glob.to_lpeg(g) end, C.cfg.exclude)
local background = vim.fs.normalize(C.cfg.background)

local function skip(root, rel)
  for _, pat in ipairs(exclude) do
    if pat:match(vim.fs.basename(rel)) or pat:match(rel) then return 'excluded' end
  end
  local stat = vim.uv.fs_stat(root .. '/' .. rel)
  if not stat or stat.type ~= 'file' then return 'not a file' end
  if stat.size > C.cfg.max_bytes then return 'too large' end
  local f = assert(io.open(root .. '/' .. rel, 'rb'))
  local text = f:read '*a'
  f:close()
  if text:sub(1, 8192):find('\0', 1, true) then return 'binary' end
  return nil, text
end

for root in vim.env.WIKI_REPOS:gmatch '%S+' do
  for _, rel in ipairs(vim.fn.systemlist { 'git', '-C', root, 'ls-files' }) do
    if not done[root .. ':' .. rel] then
      local why, text = skip(root, rel)
      if why then
        C.append(out, { root = root, path = rel, skipped = why })
      else
        local messages, shared = C.prompt.build { root = root, relpath = rel, text = text, background = background }
        local summary, usage, err = C.ask(messages, shared, C.store.root_key(root))
        C.append(out, { root = root, path = rel, summary = summary, usage = usage, error = err })
        io.write(rel, ' ', err or 'ok', '\n')
      end
    end
  end
end
vim.cmd 'qa!'
