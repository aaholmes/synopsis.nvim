-- Which repos the user has allowed to be sent to the model provider: { [root] = 'allow' | 'deny' },
-- kept in one JSON file in Neovim's data directory, so clearing the cache does not reset it.
local M = {}

function M.path() return vim.fn.stdpath 'data' .. '/synopsis/consent.json' end

local function load()
  local f = io.open(M.path(), 'rb')
  if not f then return {} end
  local ok, t = pcall(vim.json.decode, f:read '*a')
  f:close()
  return ok and type(t) == 'table' and t or {}
end

---'allow', 'deny', or nil if the user has not decided for this repo.
function M.get(root) return load()[root] end

function M.set(root, choice)
  local t = load()
  t[root] = choice
  vim.fn.mkdir(vim.fs.dirname(M.path()), 'p')
  local tmp = string.format('%s.%d.tmp', M.path(), vim.uv.os_getpid())
  local f = assert(io.open(tmp, 'wb'))
  f:write(vim.json.encode(t))
  f:close()
  assert(vim.uv.fs_rename(tmp, M.path()))
end

return M
