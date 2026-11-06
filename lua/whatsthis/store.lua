-- The summary cache: one JSON file per summarized file, under stdpath('cache')/whatsthis, so
-- nothing is written into the user's repo and two Neovim instances never overwrite each
-- other's entries.
local M = {}

local function short_hash(s) return vim.fn.sha256(s):sub(1, 16) end

---Where the entry for `relpath` inside the repo at `root` is kept.
function M.entry_path(root, relpath)
  return string.format('%s/whatsthis/%s/%s.json', vim.fn.stdpath 'cache', short_hash(root), short_hash(relpath))
end

---The stored entry, or nil if there is none or it cannot be decoded.
function M.read(root, relpath)
  local f = io.open(M.entry_path(root, relpath), 'rb')
  if not f then return nil end
  local text = f:read '*a'
  f:close()
  local ok, entry = pcall(vim.json.decode, text)
  if ok and type(entry) == 'table' and type(entry.summary) == 'string' then return entry end
  return nil
end

---Store `entry`, writing a temporary file first and renaming it into place, so a reader never
---sees a half-written entry.
function M.write(root, relpath, entry)
  local path = M.entry_path(root, relpath)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = string.format('%s.%d.tmp', path, vim.uv.os_getpid())
  local f = assert(io.open(tmp, 'wb'))
  f:write(vim.json.encode(entry))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

---'missing' with no entry, 'fresh' if it was made from this file text and prompt, else 'stale'.
function M.status(entry, content_hash, prompt_hash)
  if not entry then return 'missing' end
  if entry.content_hash == content_hash and entry.prompt_hash == prompt_hash then return 'fresh' end
  return 'stale'
end

return M
