-- Tiny test harness shared by the specs: check(name, fn), eq(got, want, what), finish(),
-- make_repo(files) for a throwaway git repo.
local H = { failures = 0, passes = 0 }

function H.check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passes = H.passes + 1
    io.write('ok    ', name, '\n')
  else
    H.failures = H.failures + 1
    io.write('FAIL  ', name, '\n      ', tostring(err), '\n')
  end
end

function H.eq(got, want, what)
  if got ~= want then error(string.format('%s: got %s, want %s', what or 'value', vim.inspect(got), vim.inspect(want)), 2) end
end

---Whether Tree-sitter has a parser for lang. language.add returns nil for a missing one instead
---of raising an error, so pcall alone would say yes.
function H.has_parser(lang)
  local ok, found = pcall(vim.treesitter.language.add, lang)
  return ok and found == true
end

function H.finish()
  io.write(string.format('\n%d passed, %d failed\n', H.passes, H.failures))
  vim.cmd(H.failures == 0 and 'qa!' or 'cq!')
end

---Create a git repo in a temporary directory holding `files` ({ [relpath] = text }), with every
---file added to the index so `git ls-files` lists it. Returns the repo's absolute path.
function H.make_repo(files)
  local dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
  vim.fn.mkdir(dir, 'p')
  for rel, text in pairs(files) do
    local path = dir .. '/' .. rel
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f = assert(io.open(path, 'wb'))
    f:write(text)
    f:close()
  end
  vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
  vim.system({ 'git', 'add', '-A' }, { cwd = dir }):wait()
  return dir
end

return H
