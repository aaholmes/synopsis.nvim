local H = dofile 'tests/harness.lua'
local render = require 'synopsis.render'

local function out(text, width, kind)
  return render.layout({ kind = kind or 'summary', text = text }, width or 40)
end
local function joined(r) return table.concat(r.lines, '|') end
local function marks_with(r, hl)
  local found = {}
  for _, m in ipairs(r.marks) do
    if m.hl == hl then table.insert(found, r.lines[m.row + 1]:sub(m.col + 1, m.end_col)) end
  end
  return found
end

H.check('text has a blank line above and below and two columns of margin on the left', function()
  H.eq(joined(out 'Does A.'), '|  Does A.|', 'padded')
end)

H.check('notes become dots, with a blank line before each', function()
  H.eq(joined(out 'Does A.\n- one\n* two'), '|  Does A.||  • one||  • two|', 'spaced dots')
  H.eq(#marks_with(out 'Does A.\n- one', 'SynopsisBullet'), 1, 'dot highlighted')
end)

H.check('runs of blank lines become one', function()
  H.eq(joined(out '\n\nDoes A.\n\n\n\n- one\n\n'), '|  Does A.||  • one|', 'collapsed')
end)

H.check('a sentence the model wrapped is joined, then wrapped to fit', function()
  H.eq(joined(out 'Does A\nand B.'), '|  Does A and B.|', 'joined')
end)

H.check('long text wraps inside a two-column right margin, and wrapped notes stay indented', function()
  local width = 30
  local r = out('Keeps the summaries for every file under the cache directory of Neovim.\n- **Watch out:** two instances never overwrite each other because each file is separate.', width)
  for i, line in ipairs(r.lines) do
    H.eq(vim.fn.strdisplaywidth(line) <= width - 2, true, 'line ' .. i .. ' fits: ' .. line)
    if line ~= '' then H.eq(line:sub(1, 2), '  ', 'line ' .. i .. ' has the left margin') end
  end
  local bullet_at
  for i, line in ipairs(r.lines) do
    if line:find('•', 1, true) then bullet_at = i end
  end
  H.eq(r.lines[bullet_at + 1]:match '^    %S' ~= nil, true, 'continuation lines up with the note text: ' .. r.lines[bullet_at + 1])
end)

H.check('bold labels lose their asterisks and are highlighted', function()
  local r = out '- **Watch out:** x'
  H.eq(r.lines[2], '  • Watch out: x', 'text')
  H.eq(table.concat(marks_with(r, 'SynopsisLabel'), ' '), 'Watch out:', 'highlighted words')
end)

H.check('code in backticks loses the backticks and is highlighted', function()
  local r = out 'Records `docs/demo.gif` with `vhs`.'
  H.eq(r.lines[2], '  Records docs/demo.gif with vhs.', 'text')
  H.eq(table.concat(marks_with(r, 'SynopsisCode'), ' '), 'docs/demo.gif vhs', 'highlighted')
end)

H.check('code spans inside a bold label and punctuation after them are kept', function()
  local r = out '- **Works with:** `init.lua`, `lua/x.lua`.'
  H.eq(r.lines[2], '  • Works with: init.lua, lua/x.lua.', 'text')
  H.eq(table.concat(marks_with(r, 'SynopsisCode'), ' '), 'init.lua lua/x.lua', 'code highlighted, punctuation not')
end)

H.check('an opening "This file provides" is cut to the verb', function()
  H.eq(out('This file provides a cache.').lines[2], '  Provides a cache.', 'file')
  H.eq(out('This module stores X.').lines[2], '  Stores X.', 'module')
  H.eq(out('This file is the entry point.').lines[2], '  This file is the entry point.', '"is" kept')
end)

H.check('status messages are dimmed, and follow an outdated summary after a blank line', function()
  local r = render.layout({ kind = 'waiting' }, 40)
  H.eq(#marks_with(r, 'SynopsisMessage') > 0, true, 'waiting dimmed')
  r = render.layout({ kind = 'outdated', text = 'Does A.' }, 60)
  H.eq(r.lines[2], '  Does A.', 'summary first')
  H.eq(r.lines[3], '', 'blank line')
  H.eq(#marks_with(r, 'SynopsisMessage') > 0, true, 'marker dimmed')
end)

H.check('skipped and failed views give their reason', function()
  H.eq(joined(render.layout({ kind = 'skipped', text = 'binary file' }, 60)):find('binary file', 1, true) ~= nil, true, 'skipped')
  H.eq(joined(render.layout({ kind = 'error', text = 'HTTP 500' }, 60)):find('HTTP 500', 1, true) ~= nil, true, 'error')
end)

H.check('the question names the repo, the host and the keys', function()
  local t = joined(render.layout({ kind = 'ask', text = '/home/me/proj', host = 'api.openai.com' }, 80, { keymaps = { allow = '<M-y>', deny = '<M-n>' } }))
  for _, want in ipairs { '/home/me/proj', 'api.openai.com', 'Alt-y', 'Alt-n' } do
    H.eq(t:find(want, 1, true) ~= nil, true, 'mentions ' .. want .. ': ' .. t)
  end
end)

H.check('the off message says how to turn summaries on', function()
  H.eq(joined(render.layout({ kind = 'off' }, 80)):find(':SynopsisAllow', 1, true) ~= nil, true, 'command named')
end)

H.check('the pane calls what it shows a synopsis, never a summary', function()
  local views = {
    { kind = 'waiting' }, { kind = 'pending' }, { kind = 'outdated', text = 'Does A.' },
    { kind = 'skipped', text = 'binary file' }, { kind = 'error', text = 'HTTP 500' },
    { kind = 'ask', text = '/repo', host = 'api.openai.com' }, { kind = 'off' },
  }
  for _, v in ipairs(views) do
    local t = joined(render.layout(v, 80))
    H.eq(t:lower():find('summar', 1, true), nil, v.kind .. ' says summary: ' .. t)
  end
  for _, kind in ipairs { 'waiting', 'pending' } do
    H.eq(joined(render.layout({ kind = kind }, 80)):find('synopsis', 1, true) ~= nil, true, kind .. ' says synopsis')
  end
end)

H.finish()
