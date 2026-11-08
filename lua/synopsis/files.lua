-- Which files may be sent to the model, and the list of a repo's files. Shared by the synopsis
-- pane and :SynopsisAsk.
local M = {}

---True if s is valid UTF-8.
function M.valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3
      or (c >= 0xF0 and c <= 0xF4) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local b = s:byte(j)
      if b < 0x80 or b > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

local compiled = setmetatable({}, { __mode = 'k' })
local function patterns(exclude)
  exclude = exclude or {}
  if not compiled[exclude] then
    compiled[exclude] = vim.tbl_map(function(g) return vim.glob.to_lpeg(g) end, exclude)
  end
  return compiled[exclude]
end

---True if rel matches one of the exclude globs, by its file name or its path in the repo.
function M.excluded(rel, exclude)
  local base = vim.fs.basename(rel)
  for _, pat in ipairs(patterns(exclude)) do
    if pat:match(base) or pat:match(rel) then return true end
  end
  return false
end

---Why root/rel must not be sent, or nil and its text if it may be.
---opts: { exclude = globs, max_bytes = number }.
function M.skip_reason(root, rel, opts)
  local path = root .. '/' .. rel
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return 'not a file' end
  if M.excluded(rel, opts.exclude) then return 'excluded by the exclude setting' end
  if opts.max_bytes and stat.size > opts.max_bytes then
    return string.format('too large (%d KB; the limit is %d KB)', math.ceil(stat.size / 1024), math.floor(opts.max_bytes / 1024))
  end
  local f = io.open(path, 'rb')
  if not f then return 'could not be read' end
  local text = f:read '*a'
  f:close()
  if text:sub(1, 8192):find('\0', 1, true) or not M.valid_utf8(text) then return 'binary file' end
  return nil, text
end

---The repo's files, relative to root and sorted: `git ls-files`, or outside git every file
---below root except in hidden folders (at most `limit`, default 5000).
function M.list(root, limit)
  limit = limit or 5000
  local res = vim.system({ 'git', 'ls-files' }, { cwd = root, text = true }):wait()
  local out = {}
  if res.code == 0 then
    out = vim.split(vim.trim(res.stdout), '\n', { plain = true, trimempty = true })
  else
    for name, kind in vim.fs.dir(root, {
      depth = 20,
      skip = function(dir) return not vim.fs.basename(dir):match '^%.' end,
    }) do
      if kind == 'file' then table.insert(out, name) end
      if #out >= limit then break end
    end
  end
  table.sort(out)
  return vim.list_slice(out, 1, limit)
end

return M
