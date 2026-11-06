local H = dofile 'tests/harness.lua'
local tele = require 'whatsthis.telescope'

local function lines(text, kind) return table.concat(tele.lines { kind = kind or 'summary', text = text }, '|') end

H.check('each note gets a blank line before it', function()
  H.eq(lines 'Does A.\n- one\n- two', 'Does A.||- one||- two', 'spaced')
end)

H.check('runs of blank lines become one, and blank lines at the ends go', function()
  H.eq(lines '\n\nDoes A.\n\n\n\n- one\n\n', 'Does A.||- one', 'collapsed')
end)

H.check('a wrapped note or sentence stays together', function()
  H.eq(lines 'Does A\nand B.\n- one\n  continued\n* two', 'Does A|and B.||- one|  continued||* two', 'kept together')
end)

H.check('outdated summaries are spaced too', function()
  H.eq(lines('Does A.\n- one', 'outdated'):match '^Does A%.||%- one||' ~= nil, true, 'spaced before the marker')
end)

H.finish()
