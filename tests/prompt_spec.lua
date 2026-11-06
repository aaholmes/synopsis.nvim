local H = dofile 'tests/harness.lua'
local prompt = require 'synopsis.prompt'

local readme = {}
for i = 1, 200 do readme[i] = 'readme line ' .. i end
local files = { ['README.md'] = table.concat(readme, '\n'), ['src/a.lua'] = 'return 1' }
for i = 1, 450 do files[string.format('gen/f%03d.txt', i)] = 'x' end
local root = H.make_repo(files)
local background = SYNOPSIS_ROOT .. '/tests/fixtures/background.md'

local function build(over)
  return prompt.build(vim.tbl_extend('force', {
    root = root, relpath = 'src/a.lua', text = 'return 1', background = background, max_chars = 1000,
  }, over or {}))
end

H.check('messages are a system turn then a user turn', function()
  local m = build()
  H.eq(#m, 2, 'count')
  H.eq(m[1].role, 'system', 'first')
  H.eq(m[2].role, 'user', 'second')
end)

H.check('the system turn includes the reader background', function()
  H.eq(build()[1].content:find('Lua, Neovim plugins', 1, true) ~= nil, true, 'background text')
end)

H.check('the system turn asks for ASD-STE100 Simplified Technical English and blank lines between items', function()
  local sys = build()[1].content
  H.eq(sys:find('ASD-STE100', 1, true) ~= nil, true, 'names the standard')
  H.eq(sys:find('blank line', 1, true) ~= nil, true, 'asks for blank lines')
  H.eq(sys:find('Begin with a verb', 1, true) ~= nil, true, 'asks to begin with a verb')
  H.eq(sys:find('Do not begin with "This file"', 1, true) ~= nil, true, 'rules out the opener')
end)

H.check('a missing background file is not an error', function()
  H.eq(type(build { background = '/no/such/file.md' }[1].content), 'string', 'system content')
end)

H.check('the user turn has the README capped at 150 lines', function()
  local u = build()[2].content
  H.eq(u:find('readme line 150\n', 1, true) ~= nil, true, 'line 150 present')
  H.eq(u:find('readme line 151', 1, true), nil, 'line 151 absent')
end)

H.check('the file list is capped at 400 paths and says how many were left out', function()
  local u = build()[2].content
  local listed = select(2, u:gsub('gen/f%d+%.txt', ''))
  H.eq(listed, 399, 'gen files listed (README.md sorts first)')
  H.eq(u:find('52 more', 1, true) ~= nil, true, 'remainder noted')
end)

H.check('repo context comes before the file, which follows its path', function()
  local u = build()[2].content
  local ctx, path, body = u:find('readme line 1\n', 1, true), u:find('src/a.lua\n', u:find('FILE', 1, true), true), u:find('return 1', 1, true)
  H.eq(ctx < path and path < body, true, 'order')
end)

H.check('long file text is cut and marked as cut', function()
  local u = build({ text = string.rep('y', 5000) })[2].content
  H.eq(select(2, u:gsub('y', '')), 1000, 'characters kept')
  H.eq(u:find('truncated', 1, true) ~= nil, true, 'marker')
  H.eq(build()[2].content:find('truncated', 1, true), nil, 'no marker when short')
end)

H.check('text containing % and ${...} is inserted literally', function()
  H.eq(build({ text = 'x = "%d ${path} %1"' })[2].content:find('x = "%d ${path} %1"', 1, true) ~= nil, true, 'literal')
end)

H.check('prompt hash changes with the background or model, not with file text', function()
  local other = vim.fn.tempname()
  vim.fn.writefile({ 'different background' }, other)
  local h = prompt.hash(background, 'gpt-6-luna')
  H.eq(h, prompt.hash(background, 'gpt-6-luna'), 'stable')
  H.eq(h ~= prompt.hash(other, 'gpt-6-luna'), true, 'background changes it')
  H.eq(h ~= prompt.hash(background, 'other-model'), true, 'model changes it')
end)

H.check('a directory outside git still gets a prompt, with no file list', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local m = prompt.build { root = dir, relpath = 'x.lua', text = 'x', background = background }
  H.eq(m[2].content:find('x.lua', 1, true) ~= nil, true, 'path present')
end)

H.finish()
