-- Builds the chat messages for one file's summary: the reader background and rules as the
-- system turn; then repo context (README, file list) before the file itself, so a provider's
-- prompt cache can reuse the shared start across files.
local M = {}

local README_LINES, MAX_FILES = 150, 400
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local function read(path)
  local f = io.open(vim.fs.normalize(path), 'rb')
  if not f then return nil end
  local text = f:read '*a'
  f:close()
  return text
end

local templates = {}
local function template(name)
  templates[name] = templates[name] or assert(read(plugin_root .. '/prompts/' .. name .. '.md'), 'missing prompt ' .. name)
  return templates[name]
end

-- Fill ${name} placeholders; values are inserted literally, whatever characters they hold.
local function fill(text, values)
  return (text:gsub('%${(%w+)}', function(k) return values[k] or '' end))
end

-- README excerpt and file list, computed once per root per session.
local contexts = {}
local function repo_context(root)
  if contexts[root] then return contexts[root] end
  local readme = ''
  for _, name in ipairs { 'README.md', 'README', 'README.rst', 'README.txt' } do
    local text = read(root .. '/' .. name)
    if text then
      local lines = vim.split(text, '\n', { plain = true })
      readme = table.concat(lines, '\n', 1, math.min(#lines, README_LINES))
      break
    end
  end
  local files = '(not a git repository)'
  local res = vim.system({ 'git', 'ls-files' }, { cwd = root, text = true }):wait()
  if res.code == 0 then
    local paths = vim.split(vim.trim(res.stdout), '\n', { plain = true, trimempty = true })
    files = table.concat(paths, '\n', 1, math.min(#paths, MAX_FILES))
    if #paths > MAX_FILES then files = files .. string.format('\n(and %d more)', #paths - MAX_FILES) end
  end
  contexts[root] = { readme = readme ~= '' and readme or '(none)', files = files }
  return contexts[root]
end

---Messages for summarizing `opts.text`, the contents of `opts.relpath` in the repo at
---`opts.root`. `opts.background` is the reader background file; text beyond `opts.max_chars`
---(default 40000) is cut and marked as cut. Also returns the start of the user turn that every
---file of the repo shares (README and file list), so it can be marked for the provider's cache.
function M.build(opts)
  local max_chars = opts.max_chars or 40000
  local content = opts.text
  if #content > max_chars then
    content = content:sub(1, max_chars) .. string.format('\n[... truncated: %d more characters not shown]', #opts.text - max_chars)
  end
  local ctx = repo_context(opts.root)
  local values = { readme = ctx.readme, files = ctx.files, path = opts.relpath, content = content }
  -- The shared part is the template up to the line holding the first per-file placeholder.
  local t = template 'file'
  local first = math.min(t:find('${path}', 1, true) or #t + 1, t:find('${content}', 1, true) or #t + 1)
  local line_start = first
  while line_start > 1 and t:sub(line_start - 1, line_start - 1) ~= '\n' do line_start = line_start - 1 end
  local shared = fill(t:sub(1, line_start - 1), values)
  return {
    { role = 'system', content = fill(template 'system', { background = read(opts.background) or '(No background given: write for a general programmer.)' }) },
    { role = 'user', content = shared .. fill(t:sub(line_start), values) },
  }, shared
end

---Identifies everything besides the file itself that shapes a summary, so a change to the
---prompts, the background or the model marks old summaries as outdated.
function M.hash(background, model)
  return vim.fn.sha256(table.concat({ template 'system', template 'file', read(background) or '', model }, '\n\x1e\n'))
end

return M
